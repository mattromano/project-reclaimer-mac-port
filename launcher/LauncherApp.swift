// The Project Reclaimer window. Opened from the disk image it installs everything (or upgrades a 1.0 install);
// installed, it updates everything, makes sure Steam is signed in for Workshop mods (QR code right in the window),
// fixes the network setup, shows mod downloads, starts the game and offers Tools. The work itself is done by
// install.sh and the scripts in $RECLAIMER_HOME/game (updater.py, workshop_helper.py, tools.py, launch.sh); the
// window only runs them and shows what they say.
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
/// The copy in Applications that install.sh built (its Info.plist names the install); the disk image's copy isn't.
let isInstalledApp = Bundle.main.object(forInfoDictionaryKey: "ReclaimerHome") != nil
let installedAppURL: URL = {
    let dir = ProcessInfo.processInfo.environment["RECLAIMER_APPS_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
    return isInstalledApp ? Bundle.main.bundleURL : dir.appendingPathComponent("Project Reclaimer.app")
}()

/// Open the installed app (after installing, or when the disk image's copy is opened) and close this one.
@MainActor
func openInstalledAppAndQuit() {
    let config = NSWorkspace.OpenConfiguration()
    config.createsNewApplicationInstance = false  // (an installed app already open just comes to the front)
    NSWorkspace.shared.openApplication(at: installedAppURL, configuration: config) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
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
        // updates rebuild the app the player opened, wherever it is; never the read-only disk image's copy
        if isInstalledApp { env["RECLAIMER_APP_PATH"] = Bundle.main.bundlePath }
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

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: Launcher?
    var setup: SetupModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    /// Closing the window mid-install stops it: say so first (Try Again picks up where it stopped).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            if case .working(let s) = launcher?.update, s.hasPrefix("Updating the Mac port") {
                let alert = NSAlert()
                alert.messageText = "Quit while updating?"
                alert.informativeText = "The update carries on in the background. Opening Project Reclaimer again waits for it to finish."
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit")
                return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
            }
            guard setup?.installing == true else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Stop installing?"
            alert.informativeText = "You can carry on later: open Project Reclaimer again and it picks up where it stopped."
            alert.addButton(withTitle: "Keep Installing")
            alert.addButton(withTitle: "Stop")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            launcher?.shutdown()
            setup?.shutdown()  // (the installer stops too; running it again picks up where it stopped)
        }
    }
}

struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var launcher = Launcher()
    @StateObject private var setup = SetupModel(upgrading: startMode == .upgrade)

    var body: some Scene {
        Window("Project Reclaimer", id: "main") {
            Group {
                switch startMode {
                case .setup, .upgrade:
                    SetupView(m: setup).onAppear {
                        delegate.setup = setup
                        setup.start()
                    }
                case .handOff:
                    Color.clear.frame(width: 1, height: 1).onAppear { openInstalledAppAndQuit() }
                case .launcher:
                    ContentView(m: launcher).onAppear {
                        delegate.launcher = launcher
                        launcher.start()
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

let startMode = launchMode(home: home, isInstalledApp: isInstalledApp,
                           installedAppExists: FileManager.default.fileExists(atPath: installedAppURL.path))

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-guide"), i + 1 < args.count {  // (scripts/make_dmg.sh)
            MainActor.assumeIsolated {
                _ = NSApplication.shared
                snapshot(OpenAnywayGuide(), name: "guide", to: URL(fileURLWithPath: args[i + 1]))
            }
            return
        }
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
        ("12-network-fix", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.network = .working("Fixing the network setup. macOS will ask for your Mac password.")
        }),
        ("13-crash", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.gameError = "The graphics card stopped responding, so the game closed. This happens now and then on heavy modded maps. Press Play to start again; if it keeps happening, lower Settings > Render resolution in the game."
        }),
        ("14-controller-stuck", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.controllers = .warning("Your Mac's game controller service is stuck, so the game won't see a controller. "
                                      + "Restart your Mac to fix it (Apple menu > Restart). Keyboard and mouse still work.")
        }),
        ("15-sound-muted", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.sound = .warning("Your Mac's sound goes to MacBook Pro Speakers, which is muted, so the game will be silent. "
                                + "Un-mute it (or pick your headphones) in the Sound menu before you press Play: the game "
                                + "keeps the sound output it starts with.")
        }),
        ("16-sound-headset", {
            $0.update = .done("Up to date"); $0.steam = .done("Signed in as player123")
            $0.sound = .done("MacBook Pro Speakers. To hear the game in AirPods Pro instead, pick it in the Sound menu "
                             + "before you press Play: the game keeps the sound output it starts with.")
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
        snapshot(ContentView(m: m), name: name, to: dir)
    }

    // the disk image's first-run window
    let setupStates: [(String, Bool, (SetupModel) -> Void)] = [
        ("20-setup-checklist", false, { s in
            s.checks = [Check(id: "mac", title: "Apple Silicon Mac, macOS 26", ok: true, detail: ""),
                        Check(id: "disk", title: "Free disk space: 210 GB", ok: true, detail: ""),
                        Check(id: "tools", title: "Apple's developer tools", ok: true, detail: ""),
                        Check(id: "rosetta", title: "Rosetta (Apple's Intel translator)", ok: nil,
                              detail: "Installed during setup; macOS asks for your password.")]
            s.phase = .ready
        }),
        ("21-setup-blocked", false, { s in
            s.checks = [Check(id: "mac", title: "Apple Silicon Mac, macOS 26", ok: true, detail: ""),
                        Check(id: "disk", title: "Free disk space: 31 GB", ok: false,
                              detail: "Halo 3 needs about 45 GB. Free up 14 GB (empty the Trash, delete big downloads), then press Check Again."),
                        Check(id: "tools", title: "Apple's developer tools", ok: false,
                              detail: "A small free Apple component the helper scripts use. Press the button below: macOS asks to install it (click Install, then Agree). It takes about 5 minutes.")]
            s.needsDevTools = true
            s.phase = .blocked
        }),
        ("22-setup-qr", false, { s in
            s.steps = ["Getting the Windows compatibility layer", "Getting the menu graphics library",
                       "Setting up the helper scripts", "Downloading Project Reclaimer",
                       "Preparing the Windows environment", "Getting the Steam downloader",
                       "Downloading Halo 3 from your Steam account"]
            s.qr = QRGrid(rows: qrRows)
            s.phase = .installing
        }),
        ("23-setup-download", false, { s in
            s.steps = ["Getting the Windows compatibility layer", "Getting the menu graphics library",
                       "Setting up the helper scripts", "Downloading Project Reclaimer",
                       "Preparing the Windows environment", "Getting the Steam downloader",
                       "Downloading Halo 3 from your Steam account"]
            s.progress = 0.37
            s.remaining = "About 14 minutes left"
            s.phase = .installing
        }),
        ("24-setup-failed", false, { s in
            s.steps = ["Getting the Windows compatibility layer", "Downloading Halo 3 from your Steam account"]
            s.phase = .failed("This Steam account doesn't own Halo: The Master Chief Collection.")
        }),
        ("25-setup-done", false, { s in
            s.steps = ["Getting the Windows compatibility layer", "Downloading Halo 3 from your Steam account",
                       "Setting up the network (asks for your Mac password)", "Adding Project Reclaimer to Applications"]
            s.phase = .done
        }),
        ("26-upgrade", true, { s in
            s.checks = [Check(id: "mac", title: "Apple Silicon Mac, macOS 26", ok: true, detail: ""),
                        Check(id: "tools", title: "Apple's developer tools", ok: true, detail: "")]
            s.phase = .ready
        }),
    ]
    for (name, upgrading, setup) in setupStates {
        let s = SetupModel(upgrading: upgrading)
        setup(s)
        snapshot(SetupView(m: s), name: name, to: dir)
    }

    // Tools
    let m = Launcher()
    m.logging = false
    m.tools.freeBytes = 41_000_000_000
    m.tools.mods = [ModItem(id: "1", title: "Ultimate Forge 2.0", bytes: 8_900_000_000),
                    ModItem(id: "2", title: "Warlock", bytes: 1_600_000_000),
                    ModItem(id: "3", title: "Halo 3 Foundation", bytes: 337_000_000)]
    m.tools.say("The report is on your Desktop: Project Reclaimer report 2026-10-10 12.31.zip")
    snapshot(ToolsSheet(launcher: m, t: m.tools), name: "30-tools", to: dir)

    // an older version chosen: the main window, and Tools with the version list open
    let v = Launcher()
    v.logging = false
    v.update = .done("Playing an older Project Reclaimer (0.9.11) for servers that haven't updated yet")
    v.steam = .done("Signed in as player123")
    v.chosenVersion = "0.9.11"
    snapshot(ContentView(m: v), name: "31-older-version", to: dir)
    v.tools.showVersions = true
    let today = ISO8601DateFormatter().string(from: Date()).prefix(10)
    let yesterday = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86400)).prefix(10)
    v.tools.versions = GameVersions(chosen: "0.9.11", versions: [
        .init(version: "0.9.13", date: String(today), downloaded: true),
        .init(version: "0.9.12", date: String(today), downloaded: true),
        .init(version: "0.9.11", date: String(yesterday), downloaded: true),
        .init(version: "0.9.10", date: String(yesterday), downloaded: false)])
    snapshot(ToolsSheet(launcher: v, t: v.tools), name: "32-tools-versions", to: dir)

    // a failed join: older server, and a server that didn't answer
    let jt = Launcher()
    jt.logging = false
    jt.update = .done("Up to date"); jt.steam = .done("Signed in as player123"); jt.playing = true
    jt.joinTrouble = .init(address: "75.98.127.226:49241", serverName: "Official Star Wars 24/7 Server",
                           serverVersion: "0.9.11", mine: "0.9.13")
    snapshot(ContentView(m: jt), name: "33-join-older-server", to: dir)
    jt.joinTrouble = .init(address: "108.28.165.49:49176", mine: "0.9.13", unreachable: true)
    snapshot(ContentView(m: jt), name: "34-join-no-answer", to: dir)
}

@MainActor
func snapshot<V: View>(_ view: V, name: String, to dir: URL) {
    // a real window on screen: SwiftUI's layer-backed content (and AppKit controls) only draw there
    let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark)
        .background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.6))
    defer { window.orderOut(nil) }
    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        print(dir.appendingPathComponent("\(name).png").path)
    }
}

/// The picture in the disk image: how to get past macOS's one-time block on an app not signed by Apple.
struct OpenAnywayGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Opening Project Reclaimer the first time").font(.title2.bold())
            Text("macOS blocks apps that aren't from the App Store or a paid Apple developer account, once. This is how to let it open:")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            step(1, "cursorarrow.click.2", "Double-click **Project Reclaimer**. macOS says it can't verify it: click **Done**.")
            step(2, "gearshape", "Open **System Settings**, then **Privacy & Security**. Scroll down to Security.")
            step(3, "lock.open", "Next to “Project Reclaimer was blocked”, click **Open Anyway**. Confirm with **Open Anyway** and your Mac password.")
            step(4, "checkmark.seal", "That's it. The Project Reclaimer window opens and installs everything; you won't see this again.")
        }
        .padding(28)
        .frame(width: 560)
    }

    private func step(_ n: Int, _ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.headline).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(Circle().fill(accent))
            Image(systemName: icon).font(.title2).foregroundStyle(accent).frame(width: 30)
            Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}
