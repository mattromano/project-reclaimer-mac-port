// The launcher window's state: updates, Steam sign-in, mods, Play, and what happens around the game.
import AppKit
import SwiftUI
import UserNotifications

// MARK: - state

enum Step: Equatable {
    case waiting, working(String), done(String), warning(String), failed(String)
    var finished: Bool { if case .waiting = self { return false }; if case .working = self { return false }; return true }
    var isWarning: Bool { if case .warning = self { return true }; return false }
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
    @Published var playing = false {
        didSet {
            if playing != oldValue { log("playing: \(playing)") }
            if !playing, oldValue { startupStopped() }
        }
    }
    @Published var gameError: String? { didSet { if let e = gameError { log("game error: \(e)") } } }
    /// What startup is doing, from `tools.py startup-state`: the window reports starting, building the Forge asset
    /// library (with how long), ready, stalled or stopped. nil (unreadable, or not playing): nothing is said about
    /// startup, exactly as before this existed.
    @Published var startup: StartupDisplay? {
        didSet {
            // (the elapsed time changes on every poll: log a state change, not a ticking clock)
            guard startup?.title != oldValue?.title else { return }
            log("startup: " + (startup.map { "\($0.title). \($0.detail)" } ?? "unreadable"))
        }
    }
    /// A stop is in flight (`tools.py force-quit`, from Try Again or Force Quit). Both row actions are off until it
    /// finishes, so a second click can't run a second stop and start a second game, and the tick stops judging the
    /// game's liveness: the game going away is what this stop is doing.
    @Published var stopping = false {
        didSet { if stopping != oldValue { log("stopping: \(stopping)") } }
    }
    /// The row the window draws: while a stop is in flight it offers no actions and says what it is doing.
    var startupRow: StartupDisplay? { stopping ? startup?.whileStopping : startup }
    @Published var steamSlow = false  // the Steam check is taking long: offer Skip
    @Published var link = ""
    @Published var linkError: String?
    @Published var helpOpen = false
    @Published var network: Step? { didSet { if network != oldValue, let n = network { log("network: \(n)") } } }
    @Published var controllers: Step? { didSet { if controllers != oldValue, let c = controllers { log("controllers: \(c)") } } }
    /// Where the Mac's sound goes: the game keeps that output once it starts, so it is shown (and warned about) before Play.
    // (logged without device names, which go into reports people send: "Chris AirPods Pro")
    @Published var sound: Step? { didSet { if sound != oldValue, let s = sound { log("sound: \(s.finished ? s.isWarning ? "warning" : "ok" : "checking")") } } }
    /// fit.py's tier says this Mac is below the recommended memory: what the first start will do, said before Play.
    /// nil on a standard Mac, and when fit.py couldn't answer at all.
    @Published var memoryNotice: String? { didSet { if memoryNotice != oldValue, let n = memoryNotice { log("memory notice: \(n)") } } }
    @Published var notice: String?   // a plain-language note, e.g. after Tools stopped the game
    @Published var showTools = false
    @Published var needsLicense = false  // Xcode's license isn't accepted: no helper script can run until it is
    @Published var acceptingLicense = false
    /// Halo 3 was removed in Tools: Play turns into Install Halo 3, which opens the game checklist.
    @Published var halo3Missing = !FileManager.default.fileExists(atPath: mccFolder.appendingPathComponent("halo3/halo3.dll").path)
    @Published var showInstallGames = false
    @Published var showController = false
    /// An older Project Reclaimer the player chose for servers that haven't updated (nil: the newest).
    @Published var chosenVersion: String? { didSet { if chosenVersion != oldValue { log("chosen version: \(chosenVersion ?? "newest")") } } }
    let tools = ToolsModel()
    private var checkingCrash = false

    // a join that failed (logs/join-problem.json): what the window says about it, and the fix it offers
    struct JoinTrouble: Equatable {
        var address: String?
        var serverName: String?
        var serverVersion: String?   // nil: still asking the server, or it didn't answer
        var mine: String?
        var unreachable = false
        var asking = false
    }
    @Published var joinTrouble: JoinTrouble? { didSet { if joinTrouble != oldValue, let j = joinTrouble { log("join trouble: \(j)") } } }
    private var lastJoinProblem = Date().timeIntervalSince1970
    private var pendingJoin: String?   // rejoin this server once the restarted game reaches its menu

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
    private var windowless = WindowlessGame()  // a game that quit but left Wine running
    private var startupPoll: LineProcess?      // `tools.py startup-state` while a game starts (one at a time)
    private var startupPollSince: Date?
    private var startupAnswer = ""             // the JSON line that poll printed
    /// fit.py's tier for this Mac, read once before Play. It decides whether a stall may mention memory, and starts
    /// standard so a failed or pending probe never invents a warning (and never invents a shortage either).
    private var tier: Tier = .standard
    private var fitAnswer: Tier?       // fit.py's own answer; nil: it hasn't answered, so nothing is said before Play
    /// Whether the Forge asset library already exists, from the one `startup-state` probe at startup (its own
    /// `forge_cache` facts) and from each poll's: nil until one answers. The note before Play is for the first start.
    private var cacheBuilt: Bool?
    private var timer: Timer?
    private var ticks = 0
    private var didStart = false

    var steamReady: Bool { if case .done = steam { return true }; if case .warning = steam { return true }; return false }
    var ready: Bool { update.finished && steamReady && !playing && network?.finished != false }

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
        tools.onGames = { [weak self] games in
            if let h = games.first(where: { $0.id == "halo3" }) { self?.halo3Missing = !h.installed }
        }
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
                checkDevTools { [self] state in
                    guard state == .license else {
                        runUpdate()  // (then the network check and Steam: never alongside an update's own network step)
                        checkSound()
                        checkMachine()
                        return
                    }
                    needsLicense = true
                    update = .warning("Xcode's license hasn't been accepted (an Xcode update asks again), so Project "
                                      + "Reclaimer can't check for updates or download mods. Press Accept below: "
                                      + "macOS asks for your password.")
                }
            }
        }
    }

    /// Xcode's license, behind macOS's password dialog; then the usual start.
    func acceptLicense() {
        acceptingLicense = true
        acceptXcodeLicense { [self] accepted in
            acceptingLicense = false
            log("xcode license accepted: \(accepted)")
            guard accepted else { return }
            needsLicense = false
            runUpdate()
            checkSound()
            checkMachine()
        }
    }

    /// fit.py's tier for this Mac sets an expectation only: a constrained Mac (below 16 GB) is told before Play that
    /// the first start builds the Forge asset library and can take a long time. It never blocks Play, and a missing or
    /// failing fit.py leaves the window silent rather than guessing. The note is for the *first* start, so one probe
    /// says whether that build already happened; `startup-state` already knows (its `forge_cache` facts are the same
    /// cache a stall is judged on), so nothing here walks the cache a second way.
    func checkMachine() {
        keep(python("fit.py", ["--json"], onLine: { [self] line in
            // decoded once: the notice before Play and the stalled copy both read this one tier
            let answer = machineTier(fitJSON: line)
            if let answer { tier = answer }
            fitAnswer = answer
            updateMemoryNotice()
        }, onExit: { _ in }))
        // one probe, not a poll (the launcher already runs fit.py here): before Play, nothing needs watching
        keep(python("tools.py", ["startup-state"], onLine: { [self] line in
            guard let built = forgeCacheBuilt(stateJSON: line) else { return }
            cacheBuilt = built
            updateMemoryNotice()
        }, onExit: { _ in }))
    }

    private func updateMemoryNotice() {
        memoryNotice = startupExpectation(tier: fitAnswer, cacheBuilt: cacheBuilt)
    }

    /// The local network addresses Reclaimer needs (added by a startup task) can go missing, e.g. right after a restart
    /// or a macOS update; without them every server refuses the join. Fix them before Play, with one password box.
    func checkNetwork() {
        keep(python("tools.py", ["net-check"], onLine: { [self] line in
            guard line == "missing" else { return }
            network = .working("Fixing the network setup. macOS will ask for your Mac password.")
            keep(python("tools.py", ["net-fix"], onLine: { [self] result in
                if result == "ok" { network = .done("Fixed") }
                else if result.hasPrefix("error: ") { network = .warning(String(result.dropFirst(7))) }
            }, onExit: { [self] _ in
                if network?.finished == false { network = .warning("The network setup couldn't be fixed. Servers may refuse to let you join.") }
            }))
        }, onExit: { _ in }))
    }

    /// macOS's game controller service sometimes gets stuck for good: Bluetooth shows the controller connected, but
    /// no app (the game included) sees it until the Mac restarts. Say so before Play instead of leaving people guessing.
    func checkControllers() {
        keep(python("tools.py", ["controller-check"], onLine: { [self] line in
            guard line == "stuck" else { return }
            controllers = .warning("Your Mac's game controller service is stuck, so the game won't see a controller. "
                                   + "Restart your Mac to fix it (Apple menu > Restart). Keyboard and mouse still work.")
        }, onExit: { _ in }))
    }

    /// The game (Wine's CoreAudio driver) keeps the sound output it starts with: headphones put in afterwards stay
    /// silent, and so does an output that is muted or a virtual device with no speaker behind it. Show where the
    /// sound goes before Play, and warn. Re-run every few seconds while waiting, since people put headphones in late.
    private var checkingSound = false
    func checkSound() {
        guard !checkingSound else { return }
        let before = "before you press Play: the game keeps the sound output it starts with."
        let check = python("tools.py", ["audio-check"], onLine: { [self] line in
            switch SoundEvent(line: line) {
            case .ok(let output): sound = .done(output)
            case .muted(let output):
                sound = .warning("Your Mac's sound goes to \(output), which is muted, so the game will be silent. "
                                 + "Un-mute it (or pick your headphones) in the Sound menu \(before)")
            case .virtual(let output):
                sound = .warning("Your Mac's sound goes to \(output), a virtual device (e.g. a meeting or recording app's). "
                                 + "If it doesn't pass sound on to speakers or headphones, you won't hear the game: pick "
                                 + "your speakers or headphones in the Sound menu \(before)")
            case .headset(let headset, let output):  // (a note, not a warning: often on purpose)
                sound = .done("\(output). To hear the game in \(headset) instead, pick it in the Sound menu \(before)")
            case .other: break
            }
        }, onExit: { [self] _ in checkingSound = false })
        checkingSound = check != nil
        keep(check)
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
            case .done(let s) where s.hasPrefix("using "):
                chosenVersion = String(s.dropFirst(6))
                update = .done("Playing an older Project Reclaimer (\(chosenVersion!)) for servers that haven't updated yet")
            case .done(let s):
                chosenVersion = nil
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
            checkNetwork()
            checkControllers()
            checkSteam()
        })
        if updater == nil {
            update = .warning("Couldn't check for updates. You can still play.")
            checkNetwork()
            checkSteam()
        }
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
                steam = .failed(e.hasSuffix(".") ? e : "Sign-in didn't finish (\(e)).")
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
        notice = nil
        joinTrouble = nil
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
        startup = nil  // (the first poll fills it in)
        playing = true
        playedAt = Date()
        gameGoneSince = nil
        windowless = WindowlessGame()
        game = LineProcess("/bin/zsh", [gameDir.appendingPathComponent("launch.sh").path],
                           onLine: { _ in }, onExit: { _ in })
        if game == nil { gameStopped(early: true) }
    }

    /// Ask `tools.py startup-state` what startup is doing: the command walks the Forge cache and lists processes, so
    /// it runs off the main thread and one poll at a time. Its verdict is the window's only source: nothing here
    /// infers "ready" from the game still running.
    ///
    /// It asks while startup is unsettled and stops there: `ready` is final (`StartupDisplay.settled`), so polling a
    /// whole session would only spawn a Python process every 2 s to re-read the log and walk a cache whose answer can
    /// no longer change. Nothing is asked while a stop is in flight either: that is the window's own doing, not
    /// startup's.
    private func pollStartup() {
        guard playing, !stopping, startup?.settled != true else { return }
        if let poll = startupPoll {
            // a wedged probe would leave the line at a stale state: let it go and ask again next tick
            guard let since = startupPollSince, Date().timeIntervalSince(since) > 30 else { return }
            log("startup state didn't answer in 30 s: asking again")
            poll.stop()
            startupPoll = nil
            startupPollSince = nil
            return
        }
        startupAnswer = ""
        startupPollSince = Date()
        let poll = python("tools.py", ["startup-state"], onLine: { [self] line in
            if line.hasPrefix("{") { startupAnswer = line }  // (anything else is an error the log already has)
        }, onExit: { [self] status in
            startupPoll = nil
            startupPollSince = nil
            // (the game ended, a stop is running, or ready was already seen while this poll was out: nothing to add)
            guard playing, !stopping, startup?.settled != true else { return }
            if status == 0, let shown = startupDisplay(json: startupAnswer, tier: tier) {
                startup = shown
                // the same answer says whether the Forge library exists: once it does, the note before Play is spent
                if forgeCacheBuilt(stateJSON: startupAnswer) == true, cacheBuilt != true {
                    cacheBuilt = true
                    updateMemoryNotice()
                }
            } else {
                if !startupAnswer.isEmpty { log("startup state unreadable (exit \(status)): \(startupAnswer)") }
                startup = nil  // no verdict, so the window behaves exactly as it did before
            }
        })
        startupPoll = poll
        if poll == nil {
            startupPollSince = nil
            log("startup state couldn't run")
            startup = nil
        }
    }

    /// The game ended: stop asking, and say startup stopped (only if a verdict was being shown, so a probe that
    /// never worked is never turned into a claim).
    private func startupStopped() {
        startupPoll?.stop()
        startupPoll = nil
        startupPollSince = nil
        guard startup != nil else { return }
        startup = startupDisplay(state: "stopped")
    }

    /// The game ended within seconds of Play: say so and let the player try again, instead of quietly closing.
    /// Tools > Game version picked a release ("newest" for the latest): the next Play starts it.
    func useVersion(_ version: String, progress: ((Double) -> Void)? = nil, done: @escaping (String?) -> Void) {
        let previous = update
        update = .working(version == "newest" ? "Going back to the newest Project Reclaimer…"
                                              : "Getting Project Reclaimer \(version)…")
        var error: String?
        keep(python("updater.py", ["use", version], onLine: { [self] line in
            switch UpdaterEvent(line: line) {
            case .progress(let v): updateProgress = v; progress?(v)
            case .done(let s) where s.hasPrefix("using "):
                chosenVersion = String(s.dropFirst(6))
                update = .done("Playing an older Project Reclaimer (\(chosenVersion!)) for servers that haven't updated yet")
            case .done:
                chosenVersion = nil
                update = .done("Back on the newest version")
            case .error(let e), .offline(let e):
                error = e
            default: break
            }
        }, onExit: { [self] _ in
            updateProgress = nil
            if error != nil { update = previous }
            done(error)
        }))
    }

    /// This launch's log says the game stopped its runtime (the player quit it). Only the end of the log is read.
    private func gameSaidRuntimeStopped() -> Bool {
        let url = home.appendingPathComponent("logs/client-wine.log")
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        let tail = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        return tail.contains("Local runtime stopped")
    }

    private func gameReachedMenu() -> Bool {
        let url = home.appendingPathComponent("logs/client-wine.log")
        // this launch's log only (launch.sh empties it at start): never the previous game's "menu ready" line
        guard Date().timeIntervalSince(playedAt) > 5,
              let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              modified > playedAt else { return false }
        let log = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return log.contains("Menu loading screen finished")
    }

    /// A failed join the helper recorded: work out the server's version (asking it, when the game didn't say),
    /// bring the window forward, and offer to switch versions and rejoin.
    private func checkJoinProblem() {
        let url = home.appendingPathComponent("logs/join-problem.json")
        guard let data = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(JoinProblem.self, from: data),
              p.time > lastJoinProblem else { return }
        lastJoinProblem = p.time
        var trouble = JoinTrouble(address: p.address, serverVersion: p.server_version,
                                  mine: p.mine ?? installedVersion(gameDir: gameDir))
        NSApp.activate(ignoringOtherApps: true)  // (the player is at the game's menu: the fix needs one click here)
        if trouble.serverVersion == nil, let address = p.address {
            trouble.asking = true
            joinTrouble = trouble
            keep(python("tools.py", ["server-version", address], onLine: { [self] line in
                guard var j = joinTrouble, j.address == address else { return }
                j.asking = false
                if line == "unreachable" || line.hasPrefix("error: ") { j.unreachable = true }
                else {
                    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                    j.serverVersion = parts.first
                    j.serverName = parts.count > 1 ? parts[1] : nil
                }
                joinTrouble = j
            }, onExit: { _ in }))
        } else {
            joinTrouble = trouble
        }
        notify("Couldn't join that server", "The Project Reclaimer window explains why and can fix it.")
    }

    /// Quit the game, switch to the server's version (or back to the newest), start again and rejoin.
    func switchAndRejoin() {
        guard let j = joinTrouble, let address = j.address, let server = j.serverVersion, let mine = j.mine else { return }
        let target = switchTarget(server: server, mine: mine)
        joinTrouble = nil
        notice = target == "newest" ? "Switching back to the newest Project Reclaimer and rejoining…"
                                    : "Switching to Project Reclaimer \(target) and rejoining…"
        keep(python("tools.py", ["force-quit"], onLine: { _ in }, onExit: { [self] _ in
            markGameStopped()
            notice = "Getting Project Reclaimer \(target == "newest" ? "(newest)" : target)…"
            useVersion(target) { [self] error in
                if let error { notice = nil; gameError = error; return }
                pendingJoin = address
                play()
                notice = "Starting the game, then joining the server…"
            }
        }))
    }

    /// Called when `tools.py force-quit` has stopped the game (from Tools, from a stalled row, or before switching
    /// versions): reset the window to "not playing" but stay open, ready to Play again. It spawns nothing.
    func markGameStopped() {
        playing = false
        gameGoneSince = nil
        stopping = false   // (the stop this window was running is over)
        // a rejoin queued for the game that just stopped (a start that never reached its menu) is not the next
        // game's to replay: after a stop there is no server to join
        pendingJoin = nil
        notice = "The game was stopped. Press Play to start it again."
    }

    /// From a stalled startup row: stop this attempt and start it again, so "quit other apps and try again" is one
    /// action in the same window. The game's own completion marker still decides whether it is ready. Only a game
    /// that really stopped is started again: if force-quit failed, the stall stays on screen and its error is shown,
    /// rather than a second game starting over the running one.
    func tryAgainAfterStall() {
        guard mayStop(stopping: stopping) else { return }  // (a second click while the first stop runs: nothing to do)
        stopping = true
        notice = "Stopping the game and starting it again…"
        var answer = ""
        let stop = python("tools.py", ["force-quit"], onLine: { line in answer = line }, onExit: { [self] status in
            switch tryAgainStep(forceQuitExit: status, said: answer) {
            case .restart:
                notice = nil
                markGameStopped()  // (ends the stop, and drops the old game's join)
                play()
            case .failed(let why):
                stopping = false  // (the stall stays on screen, and its buttons work again)
                notice = nil
                gameError = why   // (nothing is launched)
            }
        })
        if stop == nil {
            // the command couldn't even start: the same rule applies, so nothing is launched over the running game
            stopping = false
            notice = nil
            gameError = "The game couldn't be stopped, so it wasn't started again. Restart your Mac (Apple menu > "
                + "Restart), then press Play."
            return
        }
        keep(stop)
    }

    /// The process a Force Quit starts, from a stalled startup row or Tools: the same command as Tools > Force Quit.
    /// It stops a build that will not finish; `markGameStopped()` decides what the window then shows.
    func startForceQuit() {
        guard mayStop(stopping: stopping) else { return }  // (a second click while the first stop runs: nothing to do)
        stopping = true
        notice = "Stopping the game…"
        let stop = python("tools.py", ["force-quit"], onLine: { _ in }, onExit: { [self] _ in markGameStopped() })
        guard let stop else {
            stopping = false  // (nothing ran, so the row's actions work again rather than staying off for good)
            return
        }
        keep(stop)
    }

    /// The game ended: if its log shows a crash, say what happened and stay open for Play again; otherwise close
    /// (or, within seconds of Play, say it closed right away). Never while Tools is open: macOS refuses to quit
    /// with a sheet open (and beeps each time), then quit as soon as Done closed it, mid-way through what the
    /// player was doing there (an ODST download, say). The window stays, ready to Play again.
    private func gameEnded(early: Bool) {
        guard !checkingCrash else { return }
        checkingCrash = true
        // first whatever the game left running under Wine (its engine worker can outlive it, spinning a CPU core)
        let stop = python("tools.py", ["force-quit"], onLine: { _ in }, onExit: { [self] _ in checkCrash(early: early) })
        if let stop { keep(stop) } else { checkCrash(early: early) }
    }

    private func checkCrash(early: Bool) {
        var crash: String?
        let check = python("tools.py", ["crash-check"], onLine: { line in
            if line.hasPrefix("crash: ") { crash = String(line.dropFirst(7)) }
        }, onExit: { [self] _ in
            checkingCrash = false
            if let crash {
                playing = false
                gameGoneSince = nil
                gameError = crash
            } else {
                closeOrStay(early: early)
            }
        })
        guard let check else {  // couldn't even run the check: never stay stuck on "Playing"
            checkingCrash = false
            return closeOrStay(early: early)
        }
        keep(check)
    }

    private func closeOrStay(early: Bool) {
        if early || showTools || tools.busy != nil { gameStopped(early: early) } else { NSApp.terminate(nil) }
    }

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
    private lazy var testSwitch = env["RECLAIMER_TEST_SWITCH"] == "1"

    private func tick() {
        ticks += 1
        running.removeAll { !$0.isRunning }
        if ticks % 10 == 0, !playing { checkSound() }  // headphones put in while the window waits
        if let id = testGet, case .done = steam { testGet = nil; link = id; getMod() }
        if testAutoplay, ready { testAutoplay = false; play() }
        if testSwitch, let j = joinTrouble, j.serverVersion != nil, !j.asking { testSwitch = false; switchAndRejoin() }
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
        checkJoinProblem()
        if let address = pendingJoin, playing, gameReachedMenu() {
            pendingJoin = nil
            notice = "Joining the server…"
            keep(python("tools.py", ["join", address], onLine: { _ in }, onExit: { _ in }))
        }
        // the helper found no working Steam login (e.g. it expired mid-game): check it again, which shows the QR
        // code if it really is gone, then retry those mods once; not after the player chose Skip
        let needLogin = Set(mods.filter { $0.state == "login_needed" }.map(\.id)).subtracting(retried)
        if !needLogin.isSubset(of: waitingForLogin) {
            waitingForLogin.formUnion(needLogin)
            if !signingIn, !checkingSteam, !steamSkipped { checkSteam() }
        }
        guard ticks % 2 == 0 else { return }
        if playing { pollStartup() }  // (the command runs off the main thread; nothing is asked while nothing runs)
        processRunning(#"workshop_helper\.py (watch|get)"#) { [self] in helperRunning = $0 }
        // While a stop is in flight the game is meant to be disappearing, so its liveness is not judged here: the
        // windowless and process checks would fire a second stop, and gameEnded() would quit the app right after the
        // relaunch. Hands off until the stop ends (it always does: force-quit has its own timeouts).
        guard mayWatchForGameGone(playing: playing, stopping: stopping) else { return }
        // the game quit but Wine kept it running with no window (see WindowlessGame): it's over, so stop it
        let stopped = windowless.goneSince != nil && gameSaidRuntimeStopped()
        if !checkingCrash, windowless.isOver(windows: wineWindows(wineDir: home.appendingPathComponent("wine")),
                                             stopped: stopped) {
            log("the game's window has been gone for \(Int(stopped ? WindowlessGame.grace : WindowlessGame.longGrace)) s"
                + "\(stopped ? " after it said its runtime stopped" : ""), but it is still running: stopping it")
            windowless = WindowlessGame()
            return gameEnded(early: false)
        }
        processRunning(gameProcess) { [self] gameUp in
            guard playing else { return }
            if game?.isRunning == true || gameUp {
                gameGoneSince = nil
                return
            }
            if Date().timeIntervalSince(playedAt) < 20 { return gameEnded(early: true) }
            gameGoneSince = gameGoneSince ?? Date()
            // 15 s grace: Reclaimer restarts itself for some settings. Stay while a mod is still downloading (the
            // helper finishes it after the game; an interrupted one shows as failed above) or a sign-in is open
            if Date().timeIntervalSince(gameGoneSince!) > 15, !mods.contains(where: \.isDownloading), !signingIn {
                gameEnded(early: false)
            }
        }
    }

    func shutdown() {
        log("quitting")
        qrProcess?.stop()
        startupPoll?.stop()
    }
}
