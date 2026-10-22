// LauncherCore: everything the launcher window needs that isn't UI: reading the helper scripts' output lines,
// the QR code DepotDownloader draws, and the per-mod status files. Tested by launcher/Tests/main.swift.
import CoreGraphics
import Foundation

/// One line from `updater.py run`.
enum UpdaterEvent: Equatable {
    case status(String), progress(Double), relaunch, done(String), offline(String), error(String), other

    init(line: String) {
        func rest(_ prefix: String) -> String? {
            line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        if line == "relaunch" { self = .relaunch }
        else if let s = rest("status: ") { self = .status(s) }
        else if let s = rest("progress: "), let v = Double(s) { self = .progress(min(max(v, 0), 100) / 100) }
        else if let s = rest("done: ") { self = .done(s) }
        else if let s = rest("offline: ") { self = .offline(s) }
        else if let s = rest("error: ") { self = .error(s) }
        else { self = .other }
    }
}

/// One line from `tools.py audio-check`: where the Mac's sound goes (tab-separated, as device names have spaces).
enum SoundEvent: Equatable {
    case ok(output: String), muted(output: String), virtual(output: String), headset(String, output: String), other

    init(line: String) {
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        switch (parts[0], parts.count) {
        case ("ok", 2): self = .ok(output: parts[1])
        case ("muted", 2): self = .muted(output: parts[1])
        case ("virtual", 2): self = .virtual(output: parts[1])
        case ("headset", 3): self = .headset(parts[1], output: parts[2])
        default: self = .other
        }
    }
}

/// One line from `workshop_helper.py login-check` or `login-qr`.
enum SteamEvent: Equatable {
    case qrBegin, qrRow(String), qrEnd, ok(account: String), needLogin, offline, error(String), other

    init(line: String) {
        if line == "qr-begin" { self = .qrBegin }
        else if line == "qr-end" { self = .qrEnd }
        else if line.hasPrefix("qr: ") { self = .qrRow(String(line.dropFirst(4))) }
        else if line.hasPrefix("ok ") { self = .ok(account: String(line.dropFirst(3))) }
        else if line == "need-login" { self = .needLogin }
        else if line == "offline" { self = .offline }
        else if line.hasPrefix("error: ") { self = .error(String(line.dropFirst(7))) }
        else { self = .other }
    }
}

/// A QR code as DepotDownloader prints it (QRCoder line-by-line ASCII): "██" per dark module, two spaces per light.
struct QRGrid: Equatable {
    let modules: [[Bool]]  // rows of columns, true = dark
    var size: Int { modules.count }

    init?(rows: [String]) {
        let parsed: [[Bool]] = rows.map { row in
            let chars = Array(row)
            return stride(from: 0, to: chars.count - 1, by: 2).map { chars[$0] == "█" }
        }
        let width = parsed.map(\.count).max() ?? 0
        guard width > 0, parsed.contains(where: { $0.contains(true) }) else { return nil }
        // short rows (trailing spaces trimmed somewhere) are light to the right edge
        modules = parsed.map { $0 + Array(repeating: false, count: width - $0.count) }
    }
}

/// Collects QR rows between qr-begin and qr-end; Steam refreshes the code every ~30 s, so later codes replace it.
struct QRCollector {
    private var rows: [String] = []
    private(set) var current: QRGrid?

    mutating func handle(_ event: SteamEvent) {
        switch event {
        case .qrBegin: rows = []
        case .qrRow(let r): rows.append(r)
        case .qrEnd: if let g = QRGrid(rows: rows) { current = g }
        default: break
        }
    }
}

/// logs/mods/<workshop id>.json, written by workshop_helper.py.
struct ModStatus: Decodable, Identifiable, Equatable {
    let id: String
    var title: String?
    var state: String          // downloading | ready | failed | login_needed
    var percent: Double?
    var bytes_total: Int?
    var hint: String?
    var time: Double

    var name: String { title ?? "Workshop item \(id)" }
    var isDownloading: Bool { state == "downloading" }
    var fraction: Double { min(max((percent ?? 0) / 100, 0), 1) }

    var detail: String {
        switch state {
        case "downloading":
            if let total = bytes_total, total > 0 {
                return "\(gigabytes(Double(total) * fraction)) of \(gigabytes(Double(total)))"
            }
            return "Downloading from Steam Workshop…"
        case "ready": return hint.map { "Ready. \($0)" } ?? "Ready"
        case "login_needed": return "Waiting for Steam sign-in"
        default: return "Couldn't download. It will be tried again next time the game asks for it."
        }
    }

    static func load(directory: URL, since: Date) -> [ModStatus] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(ModStatus.self, from: Data(contentsOf: $0)) }
            .filter { $0.time >= since.timeIntervalSince1970 }
            .sorted { $0.time > $1.time }
    }
}

func gigabytes(_ bytes: Double) -> String {
    bytes >= 1e9 ? String(format: "%.1f GB", bytes / 1e9) : String(format: "%.0f MB", bytes / 1e6)
}

/// Workshop item ID from a pasted link ("...filedetails/?id=123") or a bare number.
func workshopID(from input: String) -> String? {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if !s.isEmpty, s.allSatisfy(\.isNumber) { return s }
    guard let r = s.range(of: #"[?&]id=(\d+)"#, options: .regularExpression) else { return nil }
    return String(s[r].drop(while: { !$0.isNumber }))
}

/// Notifications for mods that started downloading or became ready since the last look. The game itself keeps
/// saying "not downloaded: Start Steam…" for these, so the notification says what to do instead.
func modNotifications(before: [ModStatus], after: [ModStatus]) -> [(title: String, body: String)] {
    let old = Dictionary(before.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
    return after.compactMap { m in
        guard old[m.id] != m.state else { return nil }
        switch m.state {
        case "downloading":
            return ("Getting \(m.name) for you",
                    "Ignore the game's “Start Steam” message. You'll get another notification when it's ready.")
        case "ready" where old[m.id] != nil:  // (not mods that were already there when the window opened)
            return ("\(m.name) is ready", "Press Try Again in the game, or leave and rejoin the server.")
        default:
            return nil
        }
    }
}

// MARK: - setup and upgrade

/// What the window opens as.
enum LaunchMode: Equatable {
    case setup      // nothing installed: install everything
    case upgrade    // a 1.0 install (no version file): one-time upgrade
    case handOff    // the DMG copy opened while an up-to-date install exists: open the installed app instead
    case launcher   // the installed app: updates, Steam, Play
}

func launchMode(home: URL, isInstalledApp: Bool, installedAppExists: Bool) -> LaunchMode {
    let fm = FileManager.default
    let game = home.appendingPathComponent("game").path
    let wine = home.appendingPathComponent("wine").path
    guard fm.fileExists(atPath: game), fm.fileExists(atPath: wine) else { return .setup }
    if !fm.fileExists(atPath: home.appendingPathComponent("version").path) {
        // a 1.0 install has its game files and no version file; a first install that stopped partway (window
        // closed, Mac restarted) left a marker, and carries on as Setup instead of a "one-time upgrade"
        let mcc = "prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection"
        let halo = home.appendingPathComponent(mcc + "/halo3/halo3.dll").path
        let incomplete = home.appendingPathComponent(".setup-incomplete").path
        return fm.fileExists(atPath: halo) && !fm.fileExists(atPath: incomplete) ? .upgrade : .setup
    }
    if !isInstalledApp, installedAppExists { return .handOff }
    return .launcher
}

/// One line of install.sh output in GUI mode.
enum SetupEvent: Equatable {
    case step(String), progress(Double), status(String), error(String), steam(SteamEvent), other

    init(line: String) {
        let plain = line.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        if plain.hasPrefix("==> ") { self = .step(String(plain.dropFirst(4))) }
        else if plain.hasPrefix("progress: "), let v = Double(plain.dropFirst(10)) { self = .progress(min(max(v, 0), 100) / 100) }
        else if plain.hasPrefix("error: ") { self = .error(String(plain.dropFirst(7))) }
        else if plain.hasPrefix("status: ") { self = .status(String(plain.dropFirst(8))) }
        else if plain == "qr-begin" || plain == "qr-end" || plain.hasPrefix("qr: ") { self = .steam(SteamEvent(line: plain)) }
        else { self = .other }
    }
}

/// install.sh's step headings, said plainly (nil: a step not worth showing on its own).
func friendlyStep(_ heading: String) -> String? {
    let table: [(String, String?)] = [
        ("Project Reclaimer Mac Port", nil),
        ("Installing Rosetta", "Installing Rosetta (Apple's Intel translator)"),
        ("Wine", "Getting the Windows compatibility layer"),
        ("Menu library", "Getting the menu graphics library"),
        ("Game scripts", "Setting up the helper scripts"),
        ("Project Reclaimer (latest", "Downloading Project Reclaimer"),
        ("Windows environment", "Preparing the Windows environment"),
        ("DepotDownloader", "Getting the Steam downloader"),
        ("Halo 3 game files", "Downloading Halo 3 from your Steam account"),
        ("Local network addresses", "Setting up the network (asks for your Mac password)"),
        ("Tuned graphics settings", "Choosing graphics settings for your Mac"),
        ("This Mac", "Checking this Mac's memory"),
        ("Launcher app", "Adding Project Reclaimer to Applications"),
        ("Done", nil), ("Updated to", nil),
    ]
    return table.first { heading.hasPrefix($0.0) }.map { $0.1 } ?? heading
}

/// "About 12 minutes left" from how fast a download has been going.
struct RateEstimator {
    private var start: (time: Date, fraction: Double)?

    mutating func remaining(fraction: Double, now: Date = Date()) -> String? {
        guard let s = start else { start = (now, fraction); return nil }
        let done = fraction - s.fraction, elapsed = now.timeIntervalSince(s.time)
        guard done > 0.002, elapsed > 5 else { return nil }
        let left = (1 - fraction) * elapsed / done
        switch left {
        case ..<90: return "About a minute left"
        case ..<3600: return "About \(Int((left / 60).rounded())) minutes left"
        default:
            let h = left / 3600
            return h < 1.5 ? "About an hour left" : "About \(Int(h.rounded())) hours left"
        }
    }
}

// MARK: - game versions

/// "today", "yesterday", "3 days ago" for a release date like "2026-10-09" (UTC, as GitHub gives it).
func relativeDay(_ day: String, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    guard let date = f.date(from: day) else { return day }
    let today = f.date(from: f.string(from: now)) ?? now
    let days = Int((today.timeIntervalSince(date) / 86400).rounded())
    switch days {
    case ..<1: return "today"
    case 1: return "yesterday"
    default: return "\(days) days ago"
    }
}

/// updater.py versions
struct GameVersions: Decodable, Equatable {
    struct Release: Decodable, Equatable, Identifiable {
        let version: String
        let date: String
        let downloaded: Bool
        var id: String { version }
    }
    let chosen: String?
    let versions: [Release]
}

// MARK: - failed joins

/// logs/join-problem.json, written by workshop_helper.py when a join fails.
struct JoinProblem: Decodable, Equatable {
    let address: String?
    let server_version: String?
    let mine: String?
    let kind: String      // "version" (the game said which version the server runs) or "no-answer"
    let time: Double
}

func versionParts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }

/// The version to switch to for a server: its own when it's older than ours, "newest" when it's newer.
func switchTarget(server: String, mine: String) -> String {
    versionParts(server).lexicographicallyPrecedes(versionParts(mine)) ? server : "newest"
}

/// The version a game folder starts: the chosen older one, else the newest exe there.
func installedVersion(gameDir: URL) -> String? {
    if let chosen = try? String(contentsOf: gameDir.appendingPathComponent("chosen-version"), encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !chosen.isEmpty { return chosen }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: gameDir.path)) ?? []
    return names.compactMap { n -> String? in
        guard n.hasPrefix("project-reclaimer-v"), n.hasSuffix(".exe") else { return nil }
        return String(n.dropFirst(19).dropLast(4))
    }.max { versionParts($0).lexicographicallyPrecedes(versionParts($1)) }
}

// MARK: - Apple's developer tools

/// Whether the helper scripts can run: /usr/bin/python3 belongs to Apple's developer tools. With Xcode installed but
/// its license not yet accepted, that python refuses to start ("You have not agreed to the Xcode license
/// agreements"), and every script fails: once an "internet connection" error that hid the cause (GitHub #10).
enum DevTools: Equatable { case ok, missing, license }

/// selected: `xcode-select -p` succeeded; pythonStatus: `/usr/bin/python3 -c pass`'s exit status (nil: it couldn't
/// start); pythonOutput: what it printed.
func devTools(selected: Bool, pythonStatus: Int32?, pythonOutput: String) -> DevTools {
    guard selected, let status = pythonStatus else { return .missing }
    if status == 0 { return .ok }
    return pythonOutput.contains("xcodebuild -license") || pythonOutput.contains("Xcode license") ? .license : .missing
}

// MARK: - machine fit

/// The machine-fit tier: whether the window mentions memory at all. fit.py decides it (RAM is its business) and the
/// window only repeats the answer. A name this build doesn't know counts as `.standard`, so an unknown tier never
/// invents a memory warning.
enum Tier: String, Equatable {
    case constrained, standard

    /// fit.py's name for a tier; anything else is standard.
    init(name: String) { self = Tier(rawValue: name) ?? .standard }
}

/// fit.py's answer for this Mac, as far as the window needs it: the machine-fit tier, decoded once from its JSON.
/// nil when fit.py couldn't be read or said nothing about the tier: no answer is not a verdict.
func machineTier(fitJSON: String) -> Tier? {
    guard let data = fitJSON.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let name = object["tier"] as? String else { return nil }
    return Tier(name: name)
}

/// What the window says before Play about the first start, if anything. A constrained Mac (below the 16 GB the game
/// recommends) is told the first asset-library build takes a long time, and why; a standard Mac is told nothing.
/// nil for a tier fit.py didn't give, so a failed probe never invents a warning.
///
/// `cacheBuilt` is `tools.py startup-state`'s `forge_cache` facts: the note is for the *first* start, so it goes once
/// the library exists — a Mac that has built it has nothing long to expect on every later launch. nil (nobody asked
/// yet, or the answer couldn't be read) keeps the note, the behaviour before this was known.
func startupExpectation(tier: Tier?, cacheBuilt: Bool? = nil) -> String? {
    guard tier == .constrained, cacheBuilt != true else { return nil }
    return "This Mac has less memory than the 16 GB the game recommends, so its first start can take a long time: "
        + "before the menu appears, the game builds its Forge asset library. That can take half an hour or more, and "
        + "it can look stuck while it works. Quitting other apps before Play gives it more room."
}

// MARK: - a game left running without a window

/// A window owned by one of this install's Wine processes.
struct WineWindow: Equatable {
    var number: Int
    var width: Double
    var height: Double
    var onscreen: Bool
}

/// Project Reclaimer can leave the game running under Wine after the player quits it: its window closes, but the
/// game and its engine worker never exit, and the worker spins a full CPU core until it's killed (seen with 0.9.21:
/// "EXIT GAME confirmed", "Local runtime stopped", then neither process ended).
///
/// The game counts as over once a window of its has been on screen and then none of those is left, for `grace`
/// seconds when the game's log says its runtime stopped, else (some other way of quitting) `longGrace`. Only a window
/// that was on screen counts: Wine keeps hidden 500×500 helper windows and 1512×33 menu-bar strips that never are.
/// A shown window that is minimized, hidden or on another Space still counts.
struct WindowlessGame {
    static let grace: TimeInterval = 20
    static let longGrace: TimeInterval = 120
    private var shown: Set<Int> = []
    private(set) var goneSince: Date?

    /// windows: this install's Wine windows (nil: macOS couldn't list them); stopped: the log says the runtime
    /// stopped. True once the game counts as over.
    mutating func isOver(windows: [WineWindow]?, stopped: Bool, now: Date = Date()) -> Bool {
        guard let windows else { return false }
        let gameSized = windows.filter { $0.width >= 320 && $0.height >= 200 }
        for w in gameSized where w.onscreen { shown.insert(w.number) }
        if shown.isEmpty || gameSized.contains(where: { shown.contains($0.number) }) {
            goneSince = nil  // still starting (no window yet), or the game's window is there
            return false
        }
        let since = goneSince ?? now
        goneSince = since
        return now.timeIntervalSince(since) >= (stopped ? Self.grace : Self.longGrace)
    }
}

/// The windows owned by processes running from `wineDir` (this install's Wine), including minimized ones, hidden
/// ones and ones on another Space. Owners, sizes and on-screen state need no Screen Recording permission (only
/// window titles do). nil when macOS couldn't list windows at all.
func wineWindows(wineDir: URL) -> [WineWindow]? {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
    let prefix = wineDir.resolvingSymlinksInPath().path + "/"  // (proc_pidpath gives the real path)
    var isWine: [Int32: Bool] = [:]
    var windows: [WineWindow] = []
    for window in list {
        guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
        if isWine[pid] == nil {
            var path = [CChar](repeating: 0, count: 4096)  // PROC_PIDPATHINFO_MAXSIZE
            isWine[pid] = proc_pidpath(pid, &path, UInt32(path.count)) > 0 && String(cString: path).hasPrefix(prefix)
        }
        guard isWine[pid] == true else { continue }
        windows.append(WineWindow(number: number, width: Double(rect.width), height: Double(rect.height),
                                  onscreen: (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false))
    }
    return windows
}

// MARK: - what startup is doing

/// `tools.py startup-state`'s answer. The command is the only thing that decides what startup is doing: this is
/// just its JSON, so the window never infers progress from process liveness, log growth or CPU use.
struct StartupState: Decodable, Equatable {
    let state: String
    let detail: String?
    let elapsed_s: Double?
}

/// Whether the Forge asset library has been built before, from `tools.py startup-state`'s own `forge_cache` facts — the
/// same command that judges a stall, so the window has one source of truth for the cache rather than walking it too.
/// false: no file has been written yet (the first build is still to come); nil: the answer couldn't be read, so the
/// window keeps its earlier behaviour instead of inventing a cached build or a missing one.
func forgeCacheBuilt(stateJSON line: String) -> Bool? {
    guard let data = line.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cache = object["forge_cache"] as? [String: Any] else { return nil }
    let files = cache["files"] as? Int ?? 0
    let bytes = cache["bytes"] as? Int ?? 0
    return files > 0 || bytes > 0
}

/// Something the window offers when startup isn't progressing. The copy lives in the pure mapping, so a test can
/// say what the window offers without launching a game; the view only draws the buttons.
enum StartupAction: String, Equatable, Hashable {
    case tryAgain, forceQuit

    var title: String {
        switch self {
        case .tryAgain: return "Try Again"
        case .forceQuit: return "Force Quit"
        }
    }
}

/// What the window says about a starting game: a title, a plain line of detail, how to draw it, and — when there is
/// something to do about it — a second line of advice and the actions it names.
struct StartupDisplay: Equatable {
    enum Look: Equatable { case working, done, warning, stopped }
    var title: String
    var detail: String
    var look: Look
    var advice: String? = nil
    var actions: [StartupAction] = []
    var warning: Bool { look == .warning }

    /// Startup is over: the game showed its own completion marker. Final, so it can never decay back to "Starting the
    /// game", and polling stops on it (each poll reads the whole log, which keeps growing), which is also why there is
    /// nothing to ask afterwards.
    var settled: Bool { look == .done }

    /// The same row with a stop in flight: its actions are taken away, so a second click can't run a second stop and
    /// start a second game, and it says what is happening instead of the stall it is fixing.
    var whileStopping: StartupDisplay {
        StartupDisplay(title: "Stopping the game", detail: "Stopping the game now. This can take a few seconds.",
                       look: .working)
    }
}

/// The display for one line of `tools.py startup-state`. nil: the answer couldn't be read (or says a state this
/// window doesn't know), so the window keeps exactly the behaviour it had before rather than inventing a verdict.
func startupDisplay(json line: String, tier: Tier = .standard) -> StartupDisplay? {
    guard let data = line.data(using: .utf8),
          let answer = try? JSONDecoder().decode(StartupState.self, from: data) else { return nil }
    return startupDisplay(state: answer.state, detail: answer.detail ?? "", elapsed: answer.elapsed_s, tier: tier)
}

/// The state vocabulary (starting, building, ready, stalled, stopped) as the window shows it. Pure: no dates, no
/// processes, so the display decision can be tested without launching a game. A long build is still a build: only
/// the command calls a stall, since only it knows the cache and when this run started. `elapsed` is time since the
/// game started, which is when the build starts, so the building state can say how long it has been building.
/// `tier` decides whether a stall may mention memory: fit.py's tier, not a guess of the window's.
func startupDisplay(state: String, detail: String = "", elapsed: TimeInterval? = nil,
                    tier: Tier = .standard) -> StartupDisplay? {
    func words(_ fallback: String) -> String { detail.isEmpty ? fallback : detail }
    switch state {
    case "starting":
        return StartupDisplay(title: "Starting the game", detail: words("The game is starting."), look: .working)
    case "building":
        let since = elapsed.map { " for \(elapsedText($0))" } ?? ""
        return StartupDisplay(title: "Building the Forge asset library",
                              detail: "Building\(since). The first start takes a while.", look: .working)
    case "ready":
        return StartupDisplay(title: "Game ready", detail: words("The game is up."), look: .done)
    case "stalled":
        // The command has already compared the cache with this run's start time, so the window repeats its verdict
        // in plain words rather than re-checking anything. Both ways out stay offered: trying again restarts the
        // build, force-quitting stops it — neither is taken away by a stall. Memory is named only on a constrained
        // Mac: the tier decides whether the window mentions it at all, so a standard Mac is never told about a
        // shortage it doesn't have.
        guard tier == .constrained else {
            return StartupDisplay(
                title: "Startup stopped progressing",
                detail: "The game stopped making progress while building its Forge asset library.",
                look: .warning,
                advice: "Try again. If it still doesn't finish, force-quit it.",
                actions: [.tryAgain, .forceQuit])
        }
        return StartupDisplay(
            title: "Startup stopped progressing",
            detail: "The game stopped making progress while building its Forge asset library. The likely cause is "
                + "not enough free memory: that build needs more than this Mac has available right now.",
            look: .warning,
            advice: "Quit other apps, then try again. If it still doesn't finish, force-quit it.",
            actions: [.tryAgain, .forceQuit])
    case "stopped":
        return StartupDisplay(title: "Game stopped", detail: words("The game isn't running."), look: .stopped)
    default:
        return nil
    }
}

/// "45 s", "2 min 12 s", "10 min", "1 h 2 min" for how long something has been going.
func elapsedText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded(.down)))
    if s < 60 { return "\(s) s" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
    return s % 3600 == 0 ? "\(s / 3600) h" : "\(s / 3600) h \(s % 3600 / 60) min"
}

// MARK: - this installation's processes

/// Whether a path is inside this installation (`root`), compared by whole path components: `/a/ProjectReclaimer2`
/// is not inside `/a/ProjectReclaimer`. Symlinks are resolved on both sides, because `lsof` reports the real path
/// (a test install under /var is /private/var) while the window holds the path it was given.
func insideInstall(_ path: String, root: String) -> Bool {
    let inside = realPath(path)
    var base = realPath(root)
    while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
    return inside == base || inside.hasPrefix(base + "/")
}

/// The path with symlinks resolved, for a path that doesn't exist yet too (an install being made): Foundation's
/// resolvingSymlinksInPath leaves such a path alone, so the deepest part that does exist is resolved and the rest
/// appended, as `realpath` would with the missing tail.
func realPath(_ path: String) -> String {
    var existing = URL(fileURLWithPath: path).standardizedFileURL
    var missing: [String] = []
    while existing.path != "/" && !FileManager.default.fileExists(atPath: existing.path) {
        missing.insert(existing.lastPathComponent, at: 0)
        existing = existing.deletingLastPathComponent()
    }
    var resolved = existing.resolvingSymlinksInPath().path
    for part in missing { resolved = (resolved as NSString).appendingPathComponent(part) }
    return resolved
}

// MARK: - trying again after a stall

/// Whether the window may stop the game now. While a stop is already in flight it may not: a second Try Again or
/// Force Quit would run a second stop and then a second start, and two games would end up running on one install.
func mayStop(stopping: Bool) -> Bool { !stopping }

/// Whether this tick may judge the game gone (its process finished, or its window went). While a stop is in flight
/// the game is *meant* to be disappearing — Try Again's own force-quit is doing it — so watching for it would fire a
/// second stop, and `gameEnded(false)` would quit the app right after the relaunch.
func mayWatchForGameGone(playing: Bool, stopping: Bool) -> Bool { playing && !stopping }

/// Try Again's first step is stopping this attempt, so `tools.py force-quit`'s answer decides whether a second start
/// may happen. Starting over a game that wouldn't stop would put two on one install.
enum TryAgainStep: Equatable {
    case restart
    case failed(String)  // what to tell the player instead of starting a second game
}

/// The step Try Again takes after force-quit: the game stopped (start it again), or it didn't (say why, launch nothing).
func tryAgainStep(forceQuitExit status: Int32, said line: String) -> TryAgainStep {
    let answer = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if answer.hasPrefix("error: ") { return .failed(String(answer.dropFirst(7))) }
    guard status == 0 else {
        return .failed("The game didn't stop, so it wasn't started again. Restart your Mac (Apple menu > Restart), then press Play.")
    }
    return .restart
}

// MARK: - controller axes

/// A control's value as 0...1 of the range it reports (logical min/max): 8BitDo sticks are 8-bit, an Xbox
/// controller's sticks 16-bit and its triggers 10-bit.
func axisFraction(_ value: Int, min: Int, max: Int) -> Double {
    guard max > min else { return 0 }
    return Swift.min(1, Swift.max(0, Double(value - min) / Double(max - min)))
}

/// A stick axis as -1...1.
func stickPosition(_ value: Int, min: Int, max: Int) -> Double { axisFraction(value, min: min, max: max) * 2 - 1 }

/// Which way a D-pad hat points. Hats count clockwise from north starting at their own minimum (8BitDo 0...7,
/// Xbox 1...8); a value outside the eight directions means released.
struct HatDirections: Equatable {
    var up = false, right = false, down = false, left = false
}

func hatDirections(_ value: Int, min: Int, max: Int) -> HatDirections {
    let h = value - min
    guard (0...7).contains(h) else { return HatDirections() }
    return HatDirections(up: [7, 0, 1].contains(h), right: [1, 2, 3].contains(h), down: [3, 4, 5].contains(h),
                         left: [5, 6, 7].contains(h))
}

/// Button layouts of controllers the game's SDL already knows, as SDL buttons (HID button usage - 1), so the
/// controller window draws them as the game uses them. Xbox controllers over Bluetooth: A 1, B 2, X 4, Y 5, LB 7,
/// RB 8, View 11, Menu 12, Xbox 13, stick clicks 14/15 (recorded from an Xbox Wireless Controller, firmware 5.x).
func knownLayout(vendor: Int) -> [String: String]? {
    switch vendor {
    case 0x045E:  // Microsoft
        return ["a": "b0", "b": "b1", "x": "b3", "y": "b4", "leftshoulder": "b6", "rightshoulder": "b7",
                "back": "b10", "start": "b11", "guide": "b12", "leftstick": "b13", "rightstick": "b14"]
    case 0x054C:  // Sony: read through Apple's GameController framework, numbered as GCButton
        return ["a": "b\(GCButton.a.rawValue)", "b": "b\(GCButton.b.rawValue)", "x": "b\(GCButton.x.rawValue)",
                "y": "b\(GCButton.y.rawValue)", "leftshoulder": "b\(GCButton.leftShoulder.rawValue)",
                "rightshoulder": "b\(GCButton.rightShoulder.rawValue)", "back": "b\(GCButton.back.rawValue)",
                "start": "b\(GCButton.start.rawValue)", "guide": "b\(GCButton.guide.rawValue)",
                "leftstick": "b\(GCButton.leftStick.rawValue)", "rightstick": "b\(GCButton.rightStick.rawValue)"]
    case 0x057E:  // Nintendo
        return ["a": "b0", "b": "b1", "x": "b2", "y": "b3", "leftshoulder": "b6", "rightshoulder": "b7",
                "back": "b10", "start": "b11", "guide": "b12", "leftstick": "b13", "rightstick": "b14"]
    default: return nil
    }
}

/// Buttons as the controller window numbers those it reads through Apple's GameController framework.
enum GCButton: Int, CaseIterable {
    case a, b, x, y, leftShoulder, rightShoulder, back, start, guide, leftStick, rightStick
}

/// Controllers the window reads through Apple's GameController framework rather than raw HID values. macOS's
/// controller service switches a PlayStation pad (DualSense, DualShock 4) to its full report, which isn't
/// described in HID values, so the raw view showed no input at all (seen with a DualSense on 1.4.1).
func readsThroughGameController(vendor: Int) -> Bool { vendor == 0x054C }

/// SDL2-compatible GUID for macOS IOKit joystick driver.
func sdlGuid(vendorId: Int, productId: Int, version: Int = 0) -> String {
    String(format: "03000000%02x%02x0000%02x%02x0000%02x%02x0000",
           vendorId & 0xff, (vendorId >> 8) & 0xff,
           productId & 0xff, (productId >> 8) & 0xff,
           version & 0xff, (version >> 8) & 0xff)
}

/// A device's reported name, safe as the name field of an SDL mapping line: no commas (field separators) or control
/// characters (a newline would start a new mapping line, e.g. one for another pad's GUID).
func sdlMappingName(_ raw: String?) -> String {
    let cleaned = String((raw ?? "").map { $0 == "," || $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } ? " " : $0 })
        .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    return cleaned.isEmpty ? "Game Controller" : cleaned
}

/// SDL2-compatible wildcard GUID (crc=0, version=0, little-endian VID and PID).
func sdlWildcardGuid(vendorId: Int, productId: Int) -> String {
    sdlGuid(vendorId: vendorId, productId: productId, version: 0)
}

// MARK: - memory

/// RAM in whole GiB, as fit.py counts it (sysctl hw.memsize // 2**30).
func memoryGigabytes(_ bytes: UInt64) -> Int { Int(bytes >> 30) }

/// fit.py's "constrained" tier: less than the 16 GB Project Reclaimer recommends (unknown RAM isn't). Setup asks here
/// rather than running fit.py, which isn't installed yet on a first run from the disk image.
///
/// This is one of the two places that encode "under 16 GB": the other is fit.py's `tier()`, which the window follows
/// after install. They can't share a source (fit.py doesn't exist on a first run), so keep the boundary the same in
/// both; tests/test_fit.py and launcher/Tests pin it at 8 GB constrained, 16 GB not.
func isConstrainedMemory(_ bytes: UInt64) -> Bool {
    let gb = memoryGigabytes(bytes)
    return gb > 0 && gb < 16
}
