// Tools: the fixes and chores that would otherwise need Terminal or a trip into hidden folders. Each runs one
// tools.py command and says what happened in plain words.
import AppKit
import SwiftUI

struct ModItem: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let bytes: Int64
}

/// Halo 3 or Halo 3: ODST in the MCC folder, as tools.py `games` lists it.
struct GameItem: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let installed: Bool
    let bytes: Int64   // its own folder: what Remove frees (MCC's shared files belong to neither)
    let path: String
}

let mccFolder = home.appendingPathComponent(
    "prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection")

@MainActor
final class ToolsModel: ObservableObject {
    @Published var busy: String?                    // the tool running now
    @Published var result: (text: String, ok: Bool)?
    @Published var mods: [ModItem] = []
    @Published var freeBytes: Int64 = 0
    @Published var repairProgress: Double?
    @Published var repairRemaining: String?
    @Published var repairQR: QRGrid?
    @Published var versions: GameVersions?
    @Published var showVersions = false
    @Published var games: [GameItem] = [] { didSet { onGames?(games) } }
    @Published var mccBytes: Int64 = 0              // the whole MCC folder, shared files included
    @Published var downloading: String?             // the game(s) a Steam download is for, e.g. "halo3+odst"
    var onGames: (([GameItem]) -> Void)?            // (the main window follows whether Halo 3 is there)
    private var running: LineProcess?

    func game(_ id: String) -> GameItem? { games.first { $0.id == id } }
    var odstInstalled: Bool { game("odst")?.installed ?? false }

    /// Run a tools.py command; `done` gets its last line.
    func run(_ title: String, _ args: [String], done: @escaping (String) -> Void = { _ in }) {
        stream(title, args, onLine: { _ in }, done: done)
    }

    /// Like run, also handing every line to `onLine` as it arrives (Repair's QR code and progress).
    func stream(_ title: String, _ args: [String], onLine: @escaping (String) -> Void,
                done: @escaping (String) -> Void) {
        busy = title
        result = nil
        var last = ""
        running = python("tools.py", args, onLine: { line in
            last = line
            onLine(line)
        }, onExit: { [self] _ in
            busy = nil
            running = nil
            done(last)
        })
        if running == nil { busy = nil; result = ("That tool couldn't start.", false) }
    }

    func cancel() {
        running?.stop()
        repairQR = nil
        repairProgress = nil
        say("Stopped.", ok: false)
    }

    /// Only an exact "ok" (or "ok <detail>") is success: a tool that crashed or said nothing didn't work.
    func succeeded(_ line: String) -> Bool { line == "ok" || line.hasPrefix("ok ") }

    func say(_ text: String, ok: Bool = true) { result = (text, ok) }

    func error(in line: String) -> String? { line.hasPrefix("error: ") ? String(line.dropFirst(7)) : nil }

    func loadVersions() {
        busy = "Looking up Project Reclaimer versions…"
        var listing: GameVersions?
        var problem: String?
        running = python("updater.py", ["versions"], onLine: { line in
            if let data = line.data(using: .utf8), let v = try? JSONDecoder().decode(GameVersions.self, from: data) { listing = v }
            if line.hasPrefix("offline: ") || line.hasPrefix("error: ") { problem = line }
        }, onExit: { [self] _ in
            busy = nil
            running = nil
            versions = listing
            if listing == nil { say(problem == nil ? "The list of versions couldn't be loaded." : "Couldn't reach GitHub to list the versions. Check your internet connection.", ok: false) }
        })
    }

    func loadMods() {
        run("Looking at your mods…", ["mods"]) { [self] line in
            struct Listing: Decodable { let free_bytes: Int64; let mods: [ModItem] }
            if let data = line.data(using: .utf8), let l = try? JSONDecoder().decode(Listing.self, from: data) {
                mods = l.mods
                freeBytes = l.free_bytes
            }
            result = nil
        }
    }

    /// Halo 3 and ODST with their sizes; `done` runs once the list is in (after an add or remove).
    func loadGames(done: @escaping () -> Void = {}) {
        run("Looking at your games…", ["games"]) { [self] line in
            struct Listing: Decodable { let free_bytes: Int64; let mcc_bytes: Int64; let games: [GameItem] }
            if let data = line.data(using: .utf8), let l = try? JSONDecoder().decode(Listing.self, from: data) {
                games = l.games
                freeBytes = l.free_bytes
                mccBytes = l.mcc_bytes
            }
            result = nil
            done()
        }
    }

    private func titles(_ ids: [String]) -> String {
        ids.map { game($0)?.title ?? ($0 == "odst" ? "Halo 3: ODST" : "Halo 3") }.joined(separator: " and ")
    }

    /// Download games from the player's Steam copy; `done` says whether they all arrived.
    func addGames(_ ids: [String], done: @escaping (Bool) -> Void = { _ in }) {
        let names = titles(ids)
        steamDownload("Downloading \(names) from Steam…", ids.joined(separator: "+"), ["add-game"] + ids) { [self] last in
            if result?.text == "Stopped." { return loadGames { [self] in say("Stopped.", ok: false); done(false) } }
            let message = error(in: last) ?? "The download didn't finish. Try again to resume."
            loadGames { [self] in
                if succeeded(last), ids.allSatisfy({ game($0)?.installed == true }) {
                    say(ids == ["odst"] ? "Halo 3: ODST is ready: Campaign and Firefight in the game's menu."
                        : "\(names) \(ids.count > 1 ? "are" : "is") ready.")
                    done(true)
                } else { say(message, ok: false); done(false) }
            }
        }
    }

    func removeGame(_ g: GameItem, done: @escaping (Bool) -> Void = { _ in }) {
        run("Removing \(g.title)…", ["remove-game", g.id]) { [self] last in
            guard succeeded(last) else { say(error(in: last) ?? "\(g.title) couldn't be removed.", ok: false); return done(false) }
            loadGames { [self] in
                say(g.id == "halo3" ? "Halo 3 was removed. Press Install Halo 3 in the main window to play again."
                    : "\(g.title) was removed. Add it again any time from here.")
                done(true)
            }
        }
    }

    func repairGame(_ g: GameItem) {
        steamDownload("Checking \(g.title)'s files against Steam…", g.id, ["repair-game", g.id]) { [self] last in
            if succeeded(last) { say("\(g.title)'s files are all there and match Steam.") }
            else if result?.text == "Stopped." { }
            else { say(error(in: last) ?? "Repair didn't finish. Try it again.", ok: false) }
        }
    }

    /// The install checklist's choice: Halo 3, and ODST kept, added or (unchecked while installed) removed.
    func applySelection(odst: Bool, done: @escaping (Bool) -> Void) {
        if let o = game("odst"), o.installed, !odst {
            removeGame(o) { [self] ok in ok ? addGames(["halo3"], done: done) : done(false) }
        } else {
            addGames(odst && !odstInstalled ? ["halo3", "odst"] : ["halo3"], done: done)
        }
    }

    /// A download from the player's Steam copy (Add, Repair), with the QR code when Steam wants a sign-in, and
    /// progress with the time left.
    private func steamDownload(_ title: String, _ which: String, _ args: [String], done: @escaping (String) -> Void) {
        var collector = QRCollector()
        var estimator = RateEstimator()
        repairProgress = nil
        downloading = which
        stream(title, args, onLine: { [self] line in
            switch SetupEvent(line: line) {
            case .steam(let e):
                collector.handle(e)
                if e == .qrEnd { repairQR = collector.current }
            case .progress(let v):
                repairQR = nil
                repairProgress = v
                repairRemaining = estimator.remaining(fraction: v)
            default: break
            }
        }, done: { [self] last in
            repairQR = nil
            repairProgress = nil
            repairRemaining = nil
            downloading = nil
            done(last)
        })
    }
}

struct ToolsSheet: View {
    @ObservedObject var launcher: Launcher
    @ObservedObject var t: ToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: Confirm?

    enum Confirm: Identifiable {
        case removeMod(ModItem), removeGame(GameItem), resetGraphics, switchSteam, uninstall
        var id: String {
            switch self {
            case .removeMod(let m): return "mod-\(m.id)"
            case .removeGame(let g): return "game-\(g.id)"
            case .resetGraphics: return "graphics"
            case .switchSteam: return "steam"
            case .uninstall: return "uninstall"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Tools").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let busy = t.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                    Spacer()
                    Button("Stop") { t.cancel() }
                }
            }
            if !launcher.update.finished {
                Label("Tools are available once the update check finishes.", systemImage: "hourglass")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let r = t.result {
                Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(r.ok ? accent : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("The game") {
                        tool("Force quit the game", "Force Quit",
                             "For a frozen game window that won't close, even with Force Quit.") {
                            t.run("Stopping the game…", ["force-quit"]) { last in
                                if t.succeeded(last) {
                                    launcher.markGameStopped()
                                    t.say("The game was stopped.")
                                } else { t.say(t.error(in: last) ?? "The game couldn't be stopped. Restart your Mac to close it.", ok: false) }
                            }
                        }
                    }
                    section("Installed games") {
                        ForEach(t.games) { game in gameRow(game) }
                        if t.downloading != nil { DownloadProgress(t: t) }
                    }
                    section("Game version") {
                        Text(launcher.chosenVersion.map { "Playing Project Reclaimer \($0), an older version. Up-to-date servers need the newest." }
                             ?? "Playing the newest Project Reclaimer. A server that hasn't updated yet needs the version it runs.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if launcher.chosenVersion != nil {
                            tool("Back to the newest version", "Switch Back",
                                 "For up-to-date servers (most of them). Takes effect the next time you press Play; opening Project Reclaimer again does it too.") {
                                t.busy = "Switching back…"
                                launcher.useVersion("newest") { e in
                                    t.busy = nil
                                    if let e { t.say(e, ok: false) } else { t.say("Back on the newest version."); t.loadVersions() }
                                }
                            }
                        }
                        tool("Play an older version", t.showVersions ? "Hide" : "Choose…",
                             "Usually not needed: when a join fails because of the version, the main window offers to switch and rejoin. Each version is a ~45 MB download the first time, and lasts until you close Project Reclaimer.") {
                            t.showVersions.toggle()
                            if t.showVersions, t.versions == nil { t.loadVersions() }
                        }
                        if t.showVersions, let list = t.versions {
                            ForEach(list.versions) { r in
                                HStack {
                                    Text(r.version).font(.callout.monospacedDigit().weight(.medium))
                                    Text(relativeDay(r.date)).font(.callout).foregroundStyle(.secondary)
                                    if r.version == list.versions.first?.version { Text("newest").font(.caption.weight(.semibold)) }
                                    if r.downloaded { Text("downloaded").font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if r.version == (list.chosen ?? list.versions.first?.version) {
                                        Text(list.chosen == nil ? "Newest, in use" : "In use").font(.caption.weight(.semibold)).foregroundStyle(accent)
                                    } else if r.version == list.versions.first?.version {
                                        Button("Use") {
                                            t.busy = "Switching back…"
                                            launcher.useVersion("newest") { e in
                                                t.busy = nil
                                                if let e { t.say(e, ok: false) } else { t.say("Back on the newest version."); t.loadVersions() }
                                            }
                                        }.disabled(t.busy != nil || launcher.playing)
                                    } else {
                                        Button("Use") {
                                            t.busy = "Getting Project Reclaimer \(r.version)…"
                                            launcher.useVersion(r.version) { e in
                                                t.busy = nil
                                                if let e { t.say(e, ok: false) }
                                                else { t.say("Project Reclaimer \(r.version) starts the next time you press Play."); t.loadVersions() }
                                            }
                                        }.disabled(t.busy != nil || launcher.playing)
                                    }
                                }
                            }
                            if launcher.playing {
                                Text("Quit the game to switch versions.").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    section("Mods and disk space") {
                        Text("\(gigabytes(Double(t.freeBytes))) free on this Mac. Mods download again by themselves when a server needs them.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if t.mods.isEmpty {
                            Text("No Workshop mods downloaded yet.").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(t.mods) { mod in
                            HStack {
                                Text(mod.title).font(.callout).lineLimit(1)
                                Spacer()
                                Text(gigabytes(Double(mod.bytes))).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Button("Remove") { confirm = .removeMod(mod) }.disabled(t.busy != nil || !launcher.update.finished)
                            }
                        }
                    }
                    section("Settings") {
                        tool("Restore recommended graphics", "Restore",
                             "Puts back the graphics settings tuned for Macs (windowed, 60 fps). Quit the game first.") {
                            confirm = .resetGraphics
                        }
                        tool("Use a different Steam account", "Switch…",
                             "Forgets the Steam account used for mods and shows a new QR code.") {
                            confirm = .switchSteam
                        }
                    }
                    section("Help") {
                        tool("Send a report", "Make Report",
                             "Puts the logs in a zip file on your Desktop to send to whoever set this up for you. It doesn't include your Steam account.") {
                            t.run("Making the report…", ["report"]) { last in
                                if t.succeeded(last), last.count > 3 {
                                    let url = URL(fileURLWithPath: String(last.dropFirst(3)))
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                    t.say("The report is on your Desktop: \(url.lastPathComponent)")
                                } else { t.say(t.error(in: last) ?? "The report couldn't be made.", ok: false) }
                            }
                        }
                    }
                    section("Remove") {
                        tool("Uninstall Project Reclaimer", "Uninstall…",
                             "Removes the app, Halo 3 and Halo 3: ODST, mods and the network setting from this Mac. Your Steam account isn't affected.",
                             role: .destructive) {
                            confirm = .uninstall
                        }
                    }
                }
            }
            .frame(maxHeight: 520)
        }
        .padding(22)
        .frame(width: 480)

        .onAppear { if launcher.logging { t.loadGames { t.loadMods() } } }  // (not in --render-states snapshots)
        .alert(item: $confirm) { c in alert(for: c) }
    }

    private func alert(for c: Confirm) -> Alert {
        switch c {
        case .removeGame(let game):
            return Alert(title: Text("Remove \(game.title)?"),
                         message: Text("Frees \(gigabytes(Double(game.bytes))). " + (game.id == "halo3"
                             ? "Project Reclaimer can't start without it: Play turns into Install Halo 3 until you add it again (about a 13 GB download)."
                             : "ODST's campaign, Firefight and ODST servers need it; you can add it again here (about a 9 GB download).")),
                         primaryButton: .destructive(Text("Remove")) { t.removeGame(game) }, secondaryButton: .cancel())
        case .removeMod(let mod):
            return Alert(title: Text("Remove \(mod.title)?"),
                         message: Text("Frees \(gigabytes(Double(mod.bytes))). It downloads again if a server needs it."),
                         primaryButton: .destructive(Text("Remove")) {
                             t.run("Removing \(mod.title)…", ["remove-mod", mod.id]) { last in
                                 if t.succeeded(last) { t.loadMods(); t.say("\(mod.title) was removed.") }
                                 else { t.say(t.error(in: last) ?? "\(mod.title) couldn't be removed.", ok: false) }
                             }
                         }, secondaryButton: .cancel())
        case .resetGraphics:
            return Alert(title: Text("Restore recommended graphics?"),
                         message: Text("Your graphics settings are replaced; other settings stay."),
                         primaryButton: .default(Text("Restore")) {
                             t.run("Restoring graphics settings…", ["reset-graphics"]) { last in
                                 if t.succeeded(last) { t.say("Done. The game uses them the next time it starts.") }
                                 else { t.say(t.error(in: last) ?? "The graphics settings couldn't be changed.", ok: false) }
                             }
                         }, secondaryButton: .cancel())
        case .switchSteam:
            return Alert(title: Text("Use a different Steam account?"),
                         message: Text("A QR code appears in the main window: scan it with the Steam app of the account you want."),
                         primaryButton: .default(Text("Continue")) {
                             t.run("Forgetting the Steam account…", ["forget-steam"]) { last in
                                 guard t.succeeded(last) else { return t.say("The Steam account couldn't be changed.", ok: false) }
                                 dismiss()
                                 launcher.signIn()
                             }
                         }, secondaryButton: .cancel())
        case .uninstall:
            return Alert(title: Text("Uninstall Project Reclaimer?"),
                         message: Text("This deletes \(uninstalledGames), your downloaded mods and the app. The game closes if it's running, and macOS asks for your password to remove the network setting."),
                         primaryButton: .destructive(Text("Uninstall")) {
                             t.run("Uninstalling…", ["uninstall"]) { last in
                                 guard t.succeeded(last) else {
                                     return t.say(t.error(in: last) ?? "Uninstalling didn't finish. Try it again.", ok: false)
                                 }
                                 let done = NSAlert()
                                 done.messageText = "Project Reclaimer was removed."
                                 done.informativeText = last == "ok network-kept"
                                     ? "Its network setting stayed because the password box was cancelled. It's harmless and goes away if you reinstall and uninstall again."
                                     : "Thanks for playing!"
                                 done.runModal()
                                 NSApp.terminate(nil)
                             }
                         }, secondaryButton: .cancel())
        }
    }

    /// What Uninstall deletes, e.g. "Halo 3 and Halo 3: ODST (40.3 GB in all)" (MCC's shared files included).
    private var uninstalledGames: String {
        let installed = t.games.filter(\.installed).map(\.title)
        guard !installed.isEmpty else { return t.games.isEmpty ? "Halo 3's files (about 35 GB)" : "the game files" }
        return installed.joined(separator: " and ") + " (\(gigabytes(Double(t.mccBytes))) in all)"
    }

    /// One game: its size, then Add or Remove, Repair, and its folder in Finder.
    private func gameRow(_ game: GameItem) -> some View {
        let halo3 = game.id == "halo3"
        let note = game.installed ? (halo3 ? "Campaign and multiplayer." : "Campaign, Firefight and ODST servers.")
            : halo3 ? "About 13 GB from your Steam copy of MCC. Project Reclaimer needs it to start."
            : "About 9 GB from your Steam copy of MCC, for ODST's campaign, Firefight and co-op."
        let blocked = t.busy != nil || !launcher.update.finished || launcher.playing  // one at a time, never mid-update
        let quitFirst = launcher.playing ? " Quit the game first." : ""
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(game.title).font(.callout.weight(.semibold))
                    Text(game.installed ? gigabytes(Double(game.bytes)) : "Not installed")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                tip("Quit the game first: \(game.title) can't be added or removed while it's running.", disabled: blocked) {
                    if game.installed {
                        Button("Remove", role: .destructive) { confirm = .removeGame(game) }
                    } else {
                        Button("Add") { t.addGames([game.id]) }
                    }
                }
                tip("Checks the game files against Steam and downloads anything missing or damaged." + quitFirst,
                    disabled: blocked || !game.installed) {
                    Button("Repair") { t.repairGame(game) }
                }
                tip("Open game directory.", disabled: !game.installed) {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: game.path)) } label: { Image(systemName: "folder") }
                }
            }
            .controlSize(.large).fixedSize()
        }
    }

    /// A button with a tooltip that also shows while it's greyed out: macOS gives a disabled button none, so a clear
    /// layer on top takes the hover instead.
    private func tip<B: View>(_ text: String, disabled: Bool, @ViewBuilder _ button: () -> B) -> some View {
        button().disabled(disabled).help(text)
            .overlay { if disabled { Color.clear.contentShape(Rectangle()).help(text) } }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private func tool(_ title: String, _ button: String, _ detail: String, role: ButtonRole? = nil,
                      action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, role: role, action: action).controlSize(.large).fixedSize()
                .disabled(t.busy != nil || !launcher.update.finished)  // one at a time, and never mid-update
        }
    }
}

/// The QR code when Steam wants a sign-in, then a game download's progress (Add, Repair, Install Halo 3).
struct DownloadProgress: View {
    @ObservedObject var t: ToolsModel

    var body: some View {
        if t.repairQR != nil { SignInCard(qr: t.repairQR) }
        if let p = t.repairProgress {
            ProgressView(value: p).tint(accent)
            Text("\(Int(p * 100))%" + (t.repairRemaining.map { " · \($0)" } ?? ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// The games to download, as checkboxes: Halo 3 always (Project Reclaimer needs it, so it can't be unchecked),
/// ODST as the player likes. First install and Install Halo 3 both use it.
struct GameChecklist: View {
    let halo3Size: String
    var odstSize = "About 9 GB"
    @Binding var odst: Bool
    var odstNote = "For ODST's campaign, Firefight and co-op."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: .constant(true)) {
                row("Halo 3", halo3Size, "Campaign and multiplayer. Project Reclaimer needs it.")
            }
            .disabled(true).help("Project Reclaimer needs Halo 3.")
            Toggle(isOn: $odst) { row("Halo 3: ODST", odstSize, odstNote) }
        }
        .toggleStyle(.checkbox)
    }

    private func row(_ title: String, _ size: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text(size).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Install Halo 3 (the main window's Play, once Halo 3 was removed in Tools): pick the games, then Continue
/// downloads them. ODST starts checked when it's there; unchecking it removes its files.
struct InstallGamesSheet: View {
    @ObservedObject var m: Launcher
    @ObservedObject var t: ToolsModel
    @Environment(\.dismiss) private var dismiss
    @State private var odst = false
    @State private var touched = false  // (until the player clicks, the box follows whether ODST is installed)

    var body: some View {
        let odstInstalled = t.odstInstalled
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Install Halo 3").font(.title2.bold())
                Spacer()
                Button("Cancel") {
                    if t.busy != nil { t.cancel() }
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Text("Choose the games to download from your Steam copy of MCC. Halo 3 is needed to play.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            GameChecklist(halo3Size: "About 13 GB",
                          odstSize: odstInstalled ? "Installed, \(gigabytes(Double(t.game("odst")?.bytes ?? 0)))" : "About 9 GB",
                          odst: Binding(get: { odst }, set: { odst = $0; touched = true }),
                          odstNote: odstInstalled && !odst ? "Its files will be removed, freeing \(gigabytes(Double(t.game("odst")?.bytes ?? 0)))."
                              : odstInstalled ? "Keeps ODST's campaign, Firefight and co-op. Uncheck to remove its files."
                              : "For ODST's campaign, Firefight and co-op.")
                .disabled(t.busy != nil)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))
            Text("\(gigabytes(Double(t.freeBytes))) free on this Mac.").font(.callout).foregroundStyle(.secondary)
            if let busy = t.busy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout)
                    Spacer()
                    Button("Stop") { t.cancel() }
                }
            }
            DownloadProgress(t: t)
            if let r = t.result, !r.ok {
                Label(r.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                t.applySelection(odst: odst) { ok in
                    guard ok else { return }  // (the sheet stays open: Continue resumes)
                    m.notice = t.result?.text
                    dismiss()
                }
            } label: {
                Label("Continue", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(t.busy != nil || m.playing)
        }
        .padding(22)
        .frame(width: 440)
        .onAppear {
            odst = t.odstInstalled
            if m.logging { t.loadGames() }  // (not in --render-states snapshots)
        }
        .onChange(of: t.games) { if !touched { odst = t.odstInstalled } }
    }
}
