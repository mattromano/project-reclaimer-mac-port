// The launcher window's views.
import AppKit
import SwiftUI
import UserNotifications

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

/// What startup is doing while a game starts: a title, a plain line, and how to draw it (spinner, tick, or a warning).
/// When startup has stopped progressing it also carries the advice and the actions that help: trying again, or
/// force-quitting a build that will not finish.
struct StartupRow: View {
    let display: StartupDisplay
    var act: (StartupAction) -> Void = { _ in }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph.frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(display.title).font(.headline)
                Text(display.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let advice = display.advice {
                    Text(advice).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !display.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(display.actions, id: \.self) { actionButton($0) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(display.warning ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08)))
    }

    @ViewBuilder private func actionButton(_ action: StartupAction) -> some View {
        switch action {
        // (trying again is Play again, so it stays the primary action; force-quit is the way out that always works)
        case .tryAgain: Button(action.title) { act(action) }.buttonStyle(.borderedProminent).tint(accent)
        case .forceQuit: Button(action.title) { act(action) }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var glyph: some View {
        switch display.look {
        case .working: ProgressView().controlSize(.small).frame(width: 22, height: 22)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).font(.title3)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
        case .stopped: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary).font(.title3)
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

/// The Steam QR code with how to scan it (Steam sign-in for mods, the Halo 3 download, Repair game files).
struct SignInCard: View {
    let qr: QRGrid?
    var onSkip: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let qr {
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
                Text("This page moves on by itself once you approve. If the code runs out, a new one appears.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let onSkip { Button("Skip for now", action: onSkip).buttonStyle(.link).font(.caption) }
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
         "The server hasn't updated yet; you have the newest version. This window notices and offers \u{201C}Switch to (its version) and rejoin\u{201D}: one click, and the game restarts on that version and joins. Next time you open Project Reclaimer it's back on the newest."),
        ("Public join timed out; check the server address and forwarded ports",
         "That server didn't answer the join. Usually it runs an older Project Reclaimer (its card says \u{201C}This server runs an older version\u{201D}) or its port isn't open. This window asks the server which version it runs and offers to switch and rejoin when that's the problem; otherwise pick another server. If every server says this, quit the game and open Project Reclaimer again: it checks your Mac's network setup."),
        ("Steam Workshop's version of a mod differs from the server's",
         "The server uses an older copy of a mod than Steam has. Only the server's owner can fix it by updating the mod. Pick another server."),
        ("This game is Halo 3: ODST, which isn't installed. Enable Halo 3: ODST in Steam…",
         "On a Mac there's no Steam to enable it in: open Tools (the gear button) and, under Installed games, press Add next to Halo 3: ODST. It downloads ODST (about 9 GB) from your Steam copy of MCC. Then ODST's games join, and Campaign and Firefight in the game's menu have ODST too."),
        ("Could not join that server (every server)",
         "Quit the game and open Project Reclaimer again: it installs any fix it needs (it may ask for your Mac password)."),
        ("Stuck on Synchronizing players",
         "Usually the server's fault. Leave and try another server."),
        ("Controller connected in Bluetooth, but the game ignores it",
         "Turn the controller on before you press Play: the game looks for controllers when it starts. If it still isn't seen, restart your Mac. macOS's game controller service sometimes gets stuck, and then no app can see a controller until a restart (this window warns you when it notices)."),
        ("Graphics card stopped responding",
         "Start the game again. If it keeps happening, lower Settings > Render resolution in the game."),
        ("No sound, or sound from the wrong speakers",
         "The game keeps the sound output your Mac had when you pressed Play, so headphones put in afterwards stay silent, and so does a muted output. This window's Sound line shows where the sound goes: pick the output you want in the Sound menu (and un-mute it) before Play. Already playing? Switch your Mac's sound back to the output the game started with, or quit and press Play again."),
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
            Label("Problems joining or playing?", systemImage: "questionmark.circle").font(.callout.weight(.medium))
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
                if m.chosenVersion != nil, !m.playing, m.update.finished {
                    Button("Back to the newest version") { m.useVersion("newest") { _ in } }
                        .padding(.leading, 34)
                }
                Divider()
                StepRow(title: "Steam (for Workshop mods)", step: m.steam)
                if let network = m.network {
                    Divider()
                    StepRow(title: "Network setup", step: network)
                }
                if let controllers = m.controllers {
                    Divider()
                    StepRow(title: "Controller", step: controllers)
                }
                if let sound = m.sound {
                    Divider()
                    StepRow(title: "Sound", step: sound)
                }
                if m.signingIn { SignInCard(qr: m.qr, onSkip: m.skipSteam) }
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

            if m.needsLicense {
                HStack {
                    Button(m.acceptingLicense ? "Waiting for your password…" : "Accept Xcode's license") {
                        m.acceptLicense()
                    }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(m.acceptingLicense)
                    if m.acceptingLicense { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }

            if let j = m.joinTrouble { JoinTroubleCard(m: m, j: j) }

            if let s = m.startupRow {
                StartupRow(display: s) { action in
                    switch action {
                    case .tryAgain: m.tryAgainAfterStall()
                    case .forceQuit: m.startForceQuit()
                    }
                }
            }

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
            if let n = m.notice {
                Label(n, systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            // fit.py says this Mac is below the recommended memory: set the first start's expectation, without
            // touching the Play button (the warning never gates playing).
            if !m.playing, let note = m.memoryNotice {
                Label {
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: "memorychip").foregroundStyle(.orange)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
            }

            Button(action: installing ? { m.showInstallGames = true } : m.play) {
                Label(playLabel, systemImage: m.playing ? "gamecontroller.fill" : installing ? "arrow.down.circle.fill" : "play.fill")
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!m.ready)
            .sheet(isPresented: $m.showInstallGames) { InstallGamesSheet(m: m, t: m.tools) }
        }
        .padding(24)
        .frame(width: 540)
        .sheet(isPresented: $m.showTools) { ToolsSheet(launcher: m, t: m.tools) }
        .sheet(isPresented: $m.showController) { ControllerSheet(launcher: m) }
    }

    /// Halo 3 was removed in Tools: the Play button installs it instead.
    private var installing: Bool { m.halo3Missing && !m.playing }

    private var playLabel: String {
        if m.playing { return "Playing" }
        if m.ready { return installing ? "Install Halo 3…" : "Play" }
        if m.signingIn { return "Scan the code above to continue" }
        if case .failed = m.steam { return "Try again or skip Steam above" }
        return "Getting ready…"
    }

    private var header: some View {
        AppHeader(subtitle: m.playing ? "Have fun! This window shows mod downloads while you play." : "Halo 3 on your Mac") {
            Button { m.showController = true } label: {
                Label("Controller", systemImage: "gamecontroller").labelStyle(.titleAndIcon)
            }
            .controlSize(.large)
            .fixedSize()
            .help("Test and map game controller, check inputs and vibration")

            Button { m.showTools = true } label: {
                Label("Tools", systemImage: "gearshape").labelStyle(.titleAndIcon)
            }
            .controlSize(.large)
            .fixedSize()
            .help("Force quit, repair, mods and disk space, reports, uninstall")
        }
    }
}

/// A failed join, said plainly, with the fix: switch to the server's version (or back to the newest) and rejoin.
struct JoinTroubleCard: View {
    @ObservedObject var m: Launcher
    let j: Launcher.JoinTrouble

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Couldn't join \(j.serverName ?? "that server")", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Spacer()
                Button { m.joinTrouble = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            Text(explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let server = j.serverVersion, let mine = j.mine, server != mine, j.address != nil {
                let target = switchTarget(server: server, mine: mine)
                Button(target == "newest" ? "Switch to the newest and rejoin" : "Switch to \(server) and rejoin",
                       action: m.switchAndRejoin)
                    .buttonStyle(PlayButtonStyle())
                Text(target == "newest" ? "The game restarts on the newest version and joins the server."
                     : "The game restarts on that version and joins the server. Next time you open Project Reclaimer it's back on the newest.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if j.asking { HStack { ProgressView().controlSize(.small); Text("Asking the server which version it runs…").font(.caption) } }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
    }

    private var explanation: String {
        if j.asking { return "The server didn't answer the join." }
        if j.unreachable { return "The server didn't answer at all. It may be offline or blocking new players right now. Pick another server, or try again later." }
        guard let server = j.serverVersion, let mine = j.mine else { return "The server didn't answer the join." }
        if server == mine { return "It runs the same Project Reclaimer as you (\(mine)), but didn't answer the join. It may be busy or have a closed port. Try again in a minute, or pick another server." }
        return versionParts(server).lexicographicallyPrecedes(versionParts(mine))
            ? "It runs an older Project Reclaimer (\(server)) than you (\(mine)). Both need the same version."
            : "It runs a newer Project Reclaimer (\(server)) than you (\(mine)). Both need the same version."
    }
}

/// The icon, name and a line about what's happening, with room for a button on the right.
struct AppHeader<Trailing: View>: View {
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Project Reclaimer").font(.title.bold()).fixedSize()
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
        }
    }
}

extension AppHeader where Trailing == EmptyView {
    init(subtitle: String) { self.init(subtitle: subtitle) { EmptyView() } }
}
