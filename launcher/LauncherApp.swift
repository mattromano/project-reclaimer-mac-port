// The Project Reclaimer launcher window: updates everything, makes sure Steam is signed in for Workshop mods (QR code
// right in the window), shows mod downloads, and starts the game. The work itself is done by the scripts in
// $RECLAIMER_HOME/game (updater.py, workshop_helper.py, launch.sh); this file only runs them and shows what they say.
//
// Built by scripts/make_launcher.sh. `ProjectReclaimer --render-states <dir>` writes a PNG of each screen state.
import AppKit
import SwiftUI
import UserNotifications

let home: URL = {
    if let h = ProcessInfo.processInfo.environment["RECLAIMER_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
    if let h = Bundle.main.object(forInfoDictionaryKey: "ReclaimerHome") as? String { return URL(fileURLWithPath: h) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games/ProjectReclaimer")
}()
let gameDir = home.appendingPathComponent("game")
let accent = Color(red: 0.40, green: 0.70, blue: 0.30)
let gameProcess = #"project-reclaimer-v[0-9.]+\.exe game-client"#

// MARK: - running the scripts

/// Runs a command and hands each line of its output to the main actor, then its exit status.
final class LineProcess {
    private let process = Process()
    private var buffer = Data()
    var isRunning: Bool { process.isRunning }

    init?(_ executable: String, _ arguments: [String],
          onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["RECLAIMER_HOME"] = home.path
        if Bundle.main.bundlePath.hasSuffix(".app") { env["RECLAIMER_APP_PATH"] = Bundle.main.bundlePath }
        env["RECLAIMER_LAUNCHER_NOTIFIES"] = "1"  // the helper leaves notifications to this window
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = LineProcess.logFile() ?? FileHandle.nullDevice
        let finished = DispatchGroup()
        finished.enter()
        finished.enter()
        out.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !buffer.isEmpty { deliver(String(decoding: buffer, as: UTF8.self), onLine) }
                finished.leave()
                return
            }
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                deliver(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self), onLine)
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        process.terminationHandler = { _ in finished.leave() }
        do { try process.run() } catch { return nil }
        // queued after every line delivered above, so onExit always comes last
        finished.notify(queue: .main) { [process] in MainActor.assumeIsolated { onExit(process.terminationStatus) } }
    }

    private func deliver(_ line: String, _ onLine: @escaping @MainActor (String) -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { onLine(line) } }
    }

    func stop() { if process.isRunning { process.terminate() } }

    /// Scripts' error output goes to logs/launcher.log for troubleshooting.
    static func logFile() -> FileHandle? {
        let url = home.appendingPathComponent("logs/launcher.log")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_APPEND: the launcher and the scripts write to it at the same time
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return fd < 0 ? nil : FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

func python(_ script: String, _ args: [String], onLine: @escaping @MainActor (String) -> Void,
            onExit: @escaping @MainActor (Int32) -> Void) -> LineProcess? {
    LineProcess("/usr/bin/python3", ["-I", gameDir.appendingPathComponent(script).path] + args,
                onLine: onLine, onExit: onExit)
}

/// Is any process matching this pattern running? Off the main thread: waiting on the main thread would run the
/// main run loop and re-enter the window's timer.
func processRunning(_ pattern: String, _ done: @escaping @MainActor (Bool) -> Void) {
    DispatchQueue.global().async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-a", "-f", pattern]  // -a: pgrep otherwise skips the caller's ancestors
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        var found = false
        if (try? p.run()) != nil { p.waitUntilExit(); found = p.terminationStatus == 0 }
        DispatchQueue.main.async { MainActor.assumeIsolated { done(found) } }
    }
}

// MARK: - state

enum Step: Equatable {
    case waiting, working(String), done(String), warning(String), failed(String)
    var finished: Bool { if case .waiting = self { return false }; if case .working = self { return false }; return true }
}

@MainActor
final class Launcher: ObservableObject {
    // state changes go to logs/launcher.log, so a friend's problem can be read from one file
    @Published var update: Step = .waiting { didSet { if update != oldValue { log("update: \(update)") } } }
    @Published var updateProgress: Double?
    @Published var steam: Step = .waiting { didSet { if steam != oldValue { log("steam: \(steam)") } } }
    @Published var signingIn = false { didSet { if signingIn != oldValue { log("signing in: \(signingIn)") } } }
    @Published var qr: QRGrid? { didSet { if (qr == nil) != (oldValue == nil) { log("qr code shown: \(qr != nil)") } } }
    @Published var mods: [ModStatus] = [] {
        didSet {
            let summary = mods.map { "\($0.name)=\($0.state)" }
            if summary != oldValue.map({ "\($0.name)=\($0.state)" }) { log("mods: \(summary)") }
            // while playing the window is behind the game: say it with a notification
            if playing { for n in modNotifications(before: oldValue, after: mods) { notify(n.title, n.body) } }
        }
    }
    @Published var playing = false { didSet { if playing != oldValue { log("playing: \(playing)") } } }
    @Published var gameError: String? { didSet { if let e = gameError { log("game error: \(e)") } } }
    @Published var steamSlow = false  // the Steam check is taking long: offer Skip
    @Published var link = ""
    @Published var linkError: String?
    @Published var helpOpen = false

    private let started = Date()
    private var running: [LineProcess] = []
    private var updater: LineProcess?
    private var qrProcess: LineProcess?
    private var game: LineProcess?
    private var playedAt = Date.distantPast
    private var relaunchRequested = false
    private var waitingForLogin: Set<String> = []  // mods the helper couldn't download for lack of a Steam login
    private var retried: Set<String> = []          // each is retried once per session, so nothing can loop
    private var checkingSteam = false
    private var steamSkipped = false                // the player chose Skip: don't ask again this session
    private var helperRunning = false
    private var gameGoneSince: Date?
    private var timer: Timer?
    private var ticks = 0
    private var didStart = false

    var steamReady: Bool { if case .done = steam { return true }; if case .warning = steam { return true }; return false }
    var ready: Bool { update.finished && steamReady && !playing }

    var logging = true

    private func log(_ text: String) {
        guard logging, let h = LineProcess.logFile() else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        h.write(Data("\(stamp) launcher \(text)\n".utf8))
        try? h.close()
    }

    private var notificationsAllowed = false

    private func notify(_ title: String, _ body: String) {
        guard logging else { return }
        log("notification: \(title)")
        guard notificationsAllowed else {
            // macOS only lets apps signed by a registered developer post their own notifications; AppleScript's
            // (shown as Script Editor) work for everyone
            func quoted(_ s: String) -> String {
                "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title)) sound name \"Glass\""]
            try? p.run()
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        log("started (home \(home.path))")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        processRunning(gameProcess) { [self] running in
            if running {  // opened again while playing: just show mod downloads
                playing = true
                playedAt = .distantPast
                update = .done("Checked when the game started")
                steam = .done("Steam connected")
            } else {
                runUpdate()
            }
        }
    }

    private func keep(_ p: LineProcess?) { if let p { running.append(p) } }

    // 1. updates
    private func runUpdate() {
        // right after restarting for a Mac port update, only the game is checked: never restart twice in a row
        let relaunched = CommandLine.arguments.contains("--relaunched")
        update = .working("Checking for updates…")
        updater = python("updater.py", [relaunched ? "game" : "run"], onLine: { [self] line in
            switch UpdaterEvent(line: line) {
            case .status(let s): update = .working(s); updateProgress = nil
            case .progress(let v): updateProgress = v
            case .relaunch: relaunchRequested = true
            case .done(let s):
                update = .done(s == "updated" ? "Updated to the latest version"
                               : s == "up to date" ? "Up to date" : s.prefix(1).uppercased() + s.dropFirst())
            case .offline: update = .warning("Couldn't check for updates right now. You can still play.")
            case .error(let e): update = .warning("An update didn't finish: \(e). You can still play.")
            case .other: break
            }
        }, onExit: { [self] _ in
            updater = nil
            updateProgress = nil
            if relaunchRequested { return relaunch() }
            if !update.finished { update = .warning("Couldn't check for updates. You can still play.") }
            checkSteam()
        })
        if updater == nil { update = .warning("Couldn't check for updates. You can still play."); checkSteam() }
    }

    private func relaunch() {
        update = .working("Restarting the launcher…")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // wait until this instance has really quit, or `open` would just bring the quitting one forward
        p.arguments = ["-c", "while kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n \"$0\" --args --relaunched",
                       Bundle.main.bundlePath, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }

    // 2. Steam sign-in (for Workshop mods)
    func checkSteam() {
        checkingSteam = true
        steamSlow = false
        steam = .working("Checking your Steam sign-in…")
        let check = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [self] in
            if checkingSteam, Date().timeIntervalSince(check) >= 10 { steamSlow = true }
        }
        keep(python("workshop_helper.py", ["login-check"], onLine: { [self] line in
            guard checkingSteam else { return }  // skipped meanwhile
            switch SteamEvent(line: line) {
            case .ok(let account): steam = .done("Signed in as \(account)"); retryWaitingMods()
            case .needLogin: signIn()
            case .offline: steam = .warning("Can't reach Steam right now. Mods may download slowly from game servers.")
            default: break
            }
        }, onExit: { [self] _ in
            checkingSteam = false
            steamSlow = false
            if case .working = steam, !signingIn { steam = .warning("Couldn't check Steam. Mods may download slowly.") }
        }))
    }

    func signIn() {
        qrProcess?.stop()
        signingIn = true
        qr = nil
        steam = .working("Sign in to Steam so mods download fast")
        var collector = QRCollector()
        qrProcess = python("workshop_helper.py", ["login-qr"], onLine: { [self] line in
            let event = SteamEvent(line: line)
            collector.handle(event)
            switch event {
            case .qrEnd: qr = collector.current
            case .ok(let account):
                signingIn = false
                qr = nil
                steam = .done("Signed in as \(account)")
                retryWaitingMods()
            case .error(let e):
                signingIn = false
                qr = nil
                steam = .failed("Sign-in didn't finish (\(e)).")
            default: break
            }
        }, onExit: { [self] _ in
            if signingIn {
                signingIn = false
                qr = nil
                steam = .failed("Sign-in didn't finish.")
            }
        })
        // (never pulls the window in front of the game: the helper posts a notification instead)
    }

    func skipSteam() {
        steamSkipped = true
        checkingSteam = false
        steamSlow = false
        signingIn = false
        qrProcess?.stop()
        qr = nil
        steam = .warning("Not signed in. Mods download slowly from game servers, and some won't download.")
    }

    private func retryWaitingMods() {
        let ids = Array(waitingForLogin.subtracting(retried))
        waitingForLogin = []
        guard !ids.isEmpty else { return }
        retried.formUnion(ids)
        keep(python("workshop_helper.py", ["get"] + (playing ? ["--in-game"] : []) + ids,
                    onLine: { _ in }, onExit: { _ in }))
    }

    // 3. mods
    func getMod() {
        linkError = nil
        guard let id = workshopID(from: link) else {
            linkError = "Paste a Steam Workshop link (it has “?id=” in it)."
            return
        }
        guard case .done = steam else {
            linkError = steamSkipped ? "Sign in to Steam first: reopen the app to get the QR code again."
                                     : "Sign in to Steam first."
            return
        }
        link = ""
        keep(python("workshop_helper.py", ["get"] + (playing ? ["--in-game"] : []) + [id],
                    onLine: { _ in }, onExit: { _ in }))
    }

    // 4. play
    func play() {
        // asked once, on the first Play: mod downloads are announced with notifications while the game is in front
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            let why = error.map { " (\($0.localizedDescription))" } ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.notificationsAllowed = granted
                    self.log("notifications allowed: \(granted)\(why)")
                }
            }
        }
        gameError = nil
        playing = true
        playedAt = Date()
        gameGoneSince = nil
        game = LineProcess("/bin/zsh", [gameDir.appendingPathComponent("launch.sh").path],
                           onLine: { _ in }, onExit: { _ in })
        if game == nil { gameStopped(early: true) }
    }

    /// The game ended within seconds of Play: say so and let the player try again, instead of quietly closing.
    private func gameStopped(early: Bool) {
        playing = false
        gameGoneSince = nil
        if early {
            let log = home.appendingPathComponent("logs/client-wine.log").path
                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            gameError = "The game closed right after starting. Press Play to try again. If it keeps happening, "
                + "send \(log) to whoever set this up for you."
        }
    }

    // for automated end-to-end tests only: press Play / download a mod as soon as the window allows it
    private let env = ProcessInfo.processInfo.environment
    private lazy var testAutoplay = env["RECLAIMER_TEST_AUTOPLAY"] == "1"
    private lazy var testGet = env["RECLAIMER_TEST_GET"]

    private func tick() {
        ticks += 1
        running.removeAll { !$0.isRunning }
        if let id = testGet, case .done = steam { testGet = nil; link = id; getMod() }
        if testAutoplay, ready { testAutoplay = false; play() }
        // a stuck update (it has its own network timeouts, so this is a last resort) never keeps Play off for good
        if let u = updater, Date().timeIntervalSince(started) > 600 {
            u.stop()
            updater = nil
            update = .warning("The update took too long and was stopped. You can still play.")
            checkSteam()
        }
        // a status still saying "downloading" with no helper process left was interrupted (e.g. the helper crashed)
        let now = Date().timeIntervalSince1970
        mods = ModStatus.load(directory: home.appendingPathComponent("logs/mods"), since: started.addingTimeInterval(-5))
            .map { m in
                var m = m
                if m.isDownloading, !helperRunning, now - m.time > 30 { m.state = "failed" }
                return m
            }
        // the helper found no working Steam login (e.g. it expired mid-game): check it again, which shows the QR
        // code if it really is gone, then retry those mods once; not after the player chose Skip
        let needLogin = Set(mods.filter { $0.state == "login_needed" }.map(\.id)).subtracting(retried)
        if !needLogin.isSubset(of: waitingForLogin) {
            waitingForLogin.formUnion(needLogin)
            if !signingIn, !checkingSteam, !steamSkipped { checkSteam() }
        }
        guard ticks % 2 == 0 else { return }
        processRunning(#"workshop_helper\.py (watch|get)"#) { [self] in helperRunning = $0 }
        guard playing else { return }
        processRunning(gameProcess) { [self] gameUp in
            guard playing else { return }
            if game?.isRunning == true || gameUp {
                gameGoneSince = nil
                return
            }
            if Date().timeIntervalSince(playedAt) < 20 { return gameStopped(early: true) }
            gameGoneSince = gameGoneSince ?? Date()
            // 15 s grace: Reclaimer restarts itself for some settings. Stay while a mod is still downloading (the
            // helper finishes it after the game; an interrupted one shows as failed above) or a sign-in is open
            if Date().timeIntervalSince(gameGoneSince!) > 15, !mods.contains(where: \.isDownloading), !signingIn {
                NSApp.terminate(nil)
            }
        }
    }

    func shutdown() {
        log("quitting")
        qrProcess?.stop()
    }
}

// MARK: - views

struct StepRow: View {
    let title: String
    let step: Step
    var progress: Double?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let progress { ProgressView(value: progress).tint(accent) }
            }
            Spacer(minLength: 0)
        }
    }

    private var detail: String {
        switch step {
        case .waiting: return "Waiting…"
        case .working(let s), .done(let s), .warning(let s), .failed(let s): return s
        }
    }

    @ViewBuilder private var glyph: some View {
        switch step {
        case .waiting: Image(systemName: "circle.dotted").foregroundStyle(.tertiary).font(.title3)
        case .working: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).font(.title3)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).font(.title3)
        }
    }
}

struct QRView: View {
    let grid: QRGrid
    var body: some View {
        Canvas { ctx, size in
            let cell = size.width / CGFloat(grid.size)
            for (y, row) in grid.modules.enumerated() {
                for (x, dark) in row.enumerated() where dark {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.5, height: cell + 0.5)),
                             with: .color(.black))
                }
            }
        }
        .background(Color.white)
        .accessibilityLabel("Steam sign-in QR code")
    }
}

struct SignInCard: View {
    @ObservedObject var m: Launcher
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let qr = m.qr {
                    QRView(grid: qr).padding(8)
                } else {
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Getting a code…").font(.caption).foregroundStyle(.black.opacity(0.6))
                    }
                }
            }
            .frame(width: 176, height: 176)
            VStack(alignment: .leading, spacing: 10) {
                Text("Scan with your phone").font(.headline)
                instruction(1, "Open the **Steam** app on your phone.")
                instruction(2, "Tap the **shield** (Steam Guard) at the bottom.")
                instruction(3, "Tap **Scan a QR code** and point your phone at this code.")
                Text("This page moves on by itself once you approve.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Skip for now") { m.skipSteam() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.5)))
    }

    private func instruction(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)").font(.caption.bold()).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(accent))
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ModRow: View {
    let mod: ModStatus
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon).foregroundStyle(color)
                Text(mod.name).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                if mod.isDownloading { Text("\(Int(mod.percent ?? 0))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if mod.isDownloading { ProgressView(value: mod.fraction).tint(accent) }
            Text(mod.detail).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var icon: String {
        switch mod.state {
        case "downloading": return "arrow.down.circle.fill"
        case "ready": return "checkmark.circle.fill"
        case "login_needed": return "person.crop.circle.badge.exclamationmark"
        default: return "exclamationmark.triangle.fill"
        }
    }
    private var color: Color {
        switch mod.state {
        case "downloading", "ready": return accent
        case "login_needed": return .orange
        default: return .red
        }
    }
}

/// Always clearly green when it can be pressed, also while the window isn't focused (where macOS greys out
/// prominent buttons); plainly grey with the reason as its label when it can't.
struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(enabled ? .title2.bold() : .title3.weight(.semibold))
            .foregroundStyle(enabled ? .white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(enabled ? accent.opacity(configuration.isPressed ? 0.75 : 1) : Color.secondary.opacity(0.18)))
            .contentShape(Rectangle())
    }
}

/// The game's own messages a player is most likely to hit, in plain words, with what to do about each.
struct HelpPanel: View {
    @Binding var open: Bool
    private let items: [(game: String, help: String)] = [
        ("Mod not downloaded… Start Steam and sign in",
         "Expected on a Mac: the game can't use Steam itself, so this window downloads the mod instead. Wait until it says Ready under Mods, then press Try Again (or leave and rejoin)."),
        ("The server runs an older version of Project Reclaimer",
         "The server hasn't updated yet; you have the newest version. Pick another server. In the server browser's filters, turn on Hide servers running another version."),
        ("Steam Workshop's version of a mod differs from the server's",
         "The server uses an older copy of a mod than Steam has. Only the server's owner can fix it by updating the mod. Pick another server."),
        ("Could not join that server (every server)",
         "Quit the game and open Project Reclaimer again: it installs any fix it needs (it may ask for your Mac password)."),
        ("Stuck on Synchronizing players",
         "Usually the server's fault. Leave and try another server."),
        ("Graphics card stopped responding",
         "Start the game again. If it keeps happening, lower Settings > Render resolution in the game."),
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            ScrollView {  // (keeps the window shorter than a laptop screen when mods are listed too)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(items, id: \.game) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“\(item.game)”").font(.callout.weight(.semibold))
                        Text(item.help).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 6) {
                    Text("Something else? Send the logs to whoever set this up for you:")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show logs") { NSWorkspace.shared.open(home.appendingPathComponent("logs")) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)
        } label: {
            Label("Problems joining a server?", systemImage: "questionmark.circle").font(.callout.weight(.medium))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { open.toggle() } }
        }
        .tint(accent)
    }
}

struct ContentView: View {
    @ObservedObject var m: Launcher

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            VStack(alignment: .leading, spacing: 14) {
                StepRow(title: "Updates", step: m.update, progress: m.updateProgress)
                Divider()
                StepRow(title: "Steam (for Workshop mods)", step: m.steam)
                if m.signingIn { SignInCard(m: m) }
                if m.steamSlow {
                    Button("Taking long? Skip for now") { m.skipSteam() }.buttonStyle(.link).font(.caption)
                }
                if case .failed = m.steam {
                    HStack {
                        Button("Try Again") { m.signIn() }.buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                        Button("Skip for now") { m.skipSteam() }.buttonStyle(.link)
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))

            if m.playing {
                Label {
                    // (one literal: SwiftUI only applies the **bold** markup to a string literal)
                    Text("If the game says a mod is **not downloaded** or asks you to **Start Steam**, that's expected: it's downloading here. When it says **Ready** below, press **Try Again** in the game.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "info.circle.fill").foregroundStyle(accent)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.12)))
            }

            if !m.mods.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mods").font(.headline)
                    ForEach(m.mods) { ModRow(mod: $0) }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Download a mod before joining (optional)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Paste a Steam Workshop link", text: $m.link)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { m.getMod() }
                    Button("Download") { m.getMod() }.disabled(m.link.isEmpty)
                }
                if let e = m.linkError { Text(e).font(.caption).foregroundStyle(.red) }
            }

            HelpPanel(open: $m.helpOpen)

            if let e = m.gameError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }

            Button(action: m.play) {
                Label(playLabel, systemImage: m.playing ? "gamecontroller.fill" : "play.fill")
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!m.ready)
        }
        .padding(24)
        .frame(width: 480)
    }

    private var playLabel: String {
        if m.playing { return "Playing" }
        if m.ready { return "Play" }
        if m.signingIn { return "Scan the code above to continue" }
        if case .failed = m.steam { return "Try again or skip Steam above" }
        return "Getting ready…"
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Reclaimer").font(.title.bold())
                Text(m.playing ? "Have fun! This window shows mod downloads while you play."
                               : "Halo 3 on your Mac").foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: Launcher?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { launcher?.shutdown() }
    }
}

struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var launcher = Launcher()

    var body: some Scene {
        Window("Project Reclaimer", id: "main") {
            ContentView(m: launcher)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.launcher = launcher
                    launcher.start()
                }
        }
        .windowResizability(.contentSize)
    }
}

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-states"), i + 1 < args.count {
            MainActor.assumeIsolated { renderStates(to: URL(fileURLWithPath: args[i + 1])) }
            return
        }
        LauncherApp.main()
    }
}

/// Screenshots of each state, for checking the layout without clicking through it.
@MainActor
func renderStates(to dir: URL) {
    _ = NSApplication.shared
    let icon = home.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Applications/Project Reclaimer.app/Contents/Resources/AppIcon.icns")
    if let img = NSImage(contentsOf: icon) { NSApp.applicationIconImage = img }  // outside the app bundle
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date().timeIntervalSince1970
    let qrRows = (try? String(contentsOfFile: CommandLine.arguments.last ?? "", encoding: .utf8))?
        .split(separator: "\n").compactMap { $0.hasPrefix("qr: ") ? String($0.dropFirst(4)) : nil } ?? []
    let states: [(String, (Launcher) -> Void)] = [
        ("1-checking", { $0.update = .working("Checking for updates…") }),
        ("2-updating-game", { $0.update = .working("Updating Project Reclaimer to 0.9.12…"); $0.updateProgress = 0.42 }),
        ("3-steam-qr", {
            $0.update = .done("Up to date"); $0.steam = .working("Sign in to Steam so mods download fast")
            $0.signingIn = true; $0.qr = QRGrid(rows: qrRows)
        }),
        ("4-steam-failed", { $0.update = .done("Up to date"); $0.steam = .failed("Sign-in didn't finish (Expired).") }),
        ("5-ready", { $0.update = .done("Updated to the latest version"); $0.steam = .done("Signed in as player123") }),
        ("6-offline", {
            $0.update = .warning("Couldn't check for updates right now. You can still play.")
            $0.steam = .warning("Can't reach Steam right now. Mods may download slowly from game servers.")
        }),
        ("7-playing-mods", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123"); $0.playing = true
            $0.mods = [
                ModStatus(id: "1", title: "Warlock", state: "downloading", percent: 68.7, bytes_total: 1_600_000_000, time: now),
                ModStatus(id: "2", title: "Lockout", state: "ready", percent: 100, hint: "Press Try Again in the game.", time: now - 1),
                ModStatus(id: "3", title: "Ultimate Forge 2.0", state: "login_needed", time: now - 2),
                ModStatus(id: "4", title: "Sanctuary", state: "failed", time: now - 3),
            ]
        }),
        ("9-game-closed", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.gameError = "The game closed right after starting. Press Play to try again. If it keeps happening, "
                + "send ~/Games/ProjectReclaimer/logs/client-wine.log to whoever set this up for you."
        }),
        ("10-steam-slow", {
            $0.update = .done("Up to date"); $0.steam = .working("Checking your Steam sign-in…"); $0.steamSlow = true
        }),
        ("11-help", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123"); $0.playing = true
            $0.helpOpen = true
        }),
        ("8-bad-link", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.link = "Warlock"; $0.linkError = "Paste a Steam Workshop link (it has “?id=” in it)."
        }),
    ]
    for (name, setup) in states {
        let m = Launcher()
        m.logging = false
        setup(m)
        // a real (offscreen) window, so AppKit-backed controls draw too; ImageRenderer leaves them blank
        let view = NSHostingView(rootView: ContentView(m: m).environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFrontRegardless()  // layer-backed SwiftUI content only draws in a window that is on screen
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
        defer { window.orderOut(nil) }
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
            print(dir.appendingPathComponent("\(name).png").path)
        }
    }
}
