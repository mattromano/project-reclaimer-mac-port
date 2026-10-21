// First install and the one-time upgrade of a 1.0 install, in the window instead of Terminal. Runs the same
// install.sh as the Terminal line (fetched from GitHub at one commit) in its GUI mode, and shows its steps, the Steam
// QR code and the Halo 3 download's progress.
import AppKit
import SwiftUI

struct Check: Identifiable, Equatable {
    let id: String
    var title: String
    var ok: Bool?       // nil: informational
    var detail: String
}

@MainActor
final class SetupModel: ObservableObject {
    enum Phase: Equatable { case checking, blocked, ready, installing, failed(String), done }

    let upgrading: Bool
    @Published var phase: Phase = .checking
    @Published var checks: [Check] = []
    @Published var needsDevTools = false
    @Published var needsLicense = false  // Xcode is there, but its license isn't accepted yet
    @Published var acceptingLicense = false
    @Published var waitingForDevTools = false
    @Published var steps: [String] = []
    @Published var progress: Double?
    @Published var remaining: String?
    @Published var qr: QRGrid?
    @Published var status: String?   // e.g. "Signed in to Steam. Getting the file list…"
    @Published var offersODST = false  // only while the big download is still ahead
    /// Also download Halo 3: ODST (~9 GB): Project Reclaimer 0.9.19+ plays its campaign and Firefight.
    @Published var withODST = false { didSet { if withODST != oldValue { runChecks() } } }
    var installing: Bool { phase == .installing }
    private var awake: NSObjectProtocol?

    private var estimator = RateEstimator()
    private var collector = QRCollector()
    private var installer: LineProcess?
    private var lastError: String?
    private var started = false
    var neededGB: Double { withODST ? 54 : 45 }

    init(upgrading: Bool) { self.upgrading = upgrading }

    func start() {
        guard !started else { return }
        started = true
        log("setup started (\(upgrading ? "upgrade" : "fresh install"), home \(home.path))")
        runChecks()
    }

    private func log(_ text: String) {
        try? FileManager.default.createDirectory(at: home.appendingPathComponent("logs"), withIntermediateDirectories: true)
        guard let h = LineProcess.logFile() else { return }
        h.write(Data("\(ISO8601DateFormatter().string(from: Date())) setup \(text)\n".utf8))
        try? h.close()
    }

    // 1. requirements
    private var devToolsState = DevTools.ok

    /// The checks, after finding out (off the main thread) whether the helper scripts can run.
    func runChecks() {
        phase = .checking
        checkDevTools { [self] state in
            devToolsState = state
            listChecks()
        }
    }

    /// Xcode's license, accepted behind macOS's password dialog; then the checks again.
    func acceptLicense() {
        acceptingLicense = true
        acceptXcodeLicense { [self] accepted in
            acceptingLicense = false
            log("xcode license accepted: \(accepted)")
            runChecks()
        }
    }

    private func listChecks() {
        var list: [Check] = []
        let v = ProcessInfo.processInfo.operatingSystemVersion
        list.append(Check(id: "mac", title: "Apple Silicon Mac, macOS \(v.majorVersion)", ok: true, detail: ""))
        if let fit = fitFacts(), let ram = fit["ram_gb"] as? Int, let tier = fit["tier"] as? String {
            list.append(Check(id: "memory", title: "Memory: \(ram) GB (\(tier) tier)", ok: nil,
                              detail: tier == "constrained"
                                ? "Project Reclaimer recommends 16 GB. With \(ram) GB the first Forge asset library build may not fit, so the game can sit on \"Building Asset Library\" for a long time. You can still install."
                                : ""))
        }
        let halo = home.appendingPathComponent(
            "prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/halo3/halo3.dll")
        let copying = ProcessInfo.processInfo.environment["RECLAIMER_MCC_FROM"] != nil  // (install.sh skips it too)
        offersODST = !upgrading && !copying && !FileManager.default.fileExists(atPath: halo.path)
        if offersODST {  // (no big download left otherwise)
            let free = freeGigabytes()
            list.append(Check(id: "disk", title: "Free disk space: \(Int(free)) GB", ok: free >= neededGB,
                              detail: free >= neededGB ? "" :
                                "\(withODST ? "Halo 3 and ODST need" : "Halo 3 needs") about \(Int(neededGB)) GB. Free up \(Int((neededGB - free).rounded(.up))) GB (empty the Trash, delete big downloads), then press Check Again."))
        }
        let tools = devToolsState
        needsDevTools = tools == .missing
        needsLicense = tools == .license
        list.append(Check(id: "tools", title: "Apple's developer tools", ok: tools == .ok,
                          detail: tools == .ok ? "" : tools == .license
                            ? "They're installed with Xcode, but Xcode's license hasn't been accepted yet, so the helper scripts can't run. Press Accept below: macOS asks for your password."
                            : "A small free Apple component the helper scripts use. Press the button below: macOS asks to install it (click Install, then Agree). It takes about 5 minutes."))
        if !commandSucceeds("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]) {
            list.append(Check(id: "rosetta", title: "Rosetta (Apple's Intel translator)", ok: nil,
                              detail: "Installed during setup; macOS asks for your password."))
        }
        checks = list
        phase = list.allSatisfy { $0.ok != false } ? .ready : .blocked
        log("checks: \(list.map { "\($0.id)=\($0.ok.map(String.init) ?? "info")" })")
        // for automated end-to-end tests only: press Install as soon as the checks pass
        if phase == .ready, ProcessInfo.processInfo.environment["RECLAIMER_TEST_AUTOINSTALL"] == "1" { install() }
    }

    /// Free space as `df` (and so install.sh) sees it, without space macOS could purge.
    private func freeGigabytes() -> Double {
        let values = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Double(values?.volumeAvailableCapacity ?? 0) / 1e9
    }

    /// What fit.py says about this Mac. Absent on a first run from the disk image (the scripts aren't installed yet),
    /// and the window's checks must not depend on the network, so a missing script simply means no memory row.
    private func fitFacts() -> [String: Any]? {
        let script = home.appendingPathComponent("game/fit.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func commandSucceeds(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// macOS's own "install developer tools" dialog; this window carries on by itself once they're there. If the
    /// dialog was cancelled or the install failed, the button comes back.
    func installDevTools() {
        _ = commandSucceeds("/usr/bin/xcode-select", ["--install"])
        waitingForDevTools = true
        let asked = Date()
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if self.commandSucceeds("/usr/bin/xcode-select", ["-p"]) {  // (runChecks then tests python too)
                    timer.invalidate()
                    self.waitingForDevTools = false
                    self.runChecks()
                } else if Date().timeIntervalSince(asked) > 20,
                          !self.commandSucceeds("/usr/bin/pgrep", ["-x", "Install Command Line Developer Tools"]) {
                    timer.invalidate()  // Apple's installer isn't running any more: cancelled or failed
                    self.waitingForDevTools = false
                }
            }
        }
    }

    // 2. install (or upgrade)
    func install() {
        phase = .installing
        steps = []
        progress = nil
        remaining = nil
        qr = nil
        status = nil
        lastError = nil
        log("installing\(withODST ? " with ODST" : "")")
        // a 35 GB download: the Mac must not fall asleep on it (the screen may)
        awake = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                      reason: "Installing Project Reclaimer")
        setCloseButton(enabled: false)  // (Cmd-Q asks first; see AppDelegate)
        // the installer from GitHub, pinned to main's current commit so every file it fetches matches
        let bootstrap = """
            raw=${RECLAIMER_REPO_RAW:-}
            if [ -z "$raw" ]; then
              sha=$(/usr/bin/curl -fsS --connect-timeout 15 -H 'Accept: application/vnd.github.sha' \\
                https://api.github.com/repos/mattromano/project-reclaimer-mac-port/commits/main 2>/dev/null)
              case "$sha" in *[!0-9a-f]*|'') sha=main ;; esac
              raw=https://raw.githubusercontent.com/mattromano/project-reclaimer-mac-port/$sha
            fi
            f=${TMPDIR:-/tmp}/project-reclaimer-install.sh
            /usr/bin/curl -fsSL --connect-timeout 20 --speed-limit 1024 --speed-time 60 "$raw/install.sh" -o "$f" ||
              { echo "error: Couldn't download the installer. Check your internet connection and try again."; exit 1; }
            RECLAIMER_REPO_RAW="$raw" RECLAIMER_GUI=1 \(withODST && offersODST ? "RECLAIMER_ODST=1 " : "")exec /bin/bash "$f"
            """
        installer = LineProcess("/bin/bash", ["-c", bootstrap], onLine: { [self] line in
            switch SetupEvent(line: line) {
            case .step(let heading):
                if let title = friendlyStep(heading) {
                    steps.append(title)
                    progress = nil
                    remaining = nil
                    status = nil
                    qr = nil
                    estimator = RateEstimator()
                }
            case .status(let s):
                qr = nil  // (Steam accepted the scan)
                status = s
            case .progress(let v):
                qr = nil  // signed in: the download started
                status = nil
                progress = v
                remaining = estimator.remaining(fraction: v)
            case .steam(let e):
                collector.handle(e)
                if e == .qrEnd { qr = collector.current }
            case .error(let e):
                if lastError == nil { lastError = e }  // the first error is the specific one
            case .other:
                break
            }
        }, onExit: { [self] status in
            installer = nil
            qr = nil
            if let awake { ProcessInfo.processInfo.endActivity(awake) }
            awake = nil
            setCloseButton(enabled: true)
            log("installer exited \(status)\(lastError.map { ": \($0)" } ?? "")")
            if status == 0 {
                phase = .done
                // a disk image copy that was dragged somewhere would show up twice in Spotlight: the installed app
                // in ~/Applications is the one that updates itself (a copy still on the disk image can't be moved)
                if !isInstalledApp, Bundle.main.bundleIdentifier == "local.projectreclaimer.setup",
                   Bundle.main.bundleURL.pathExtension == "app", !Bundle.main.bundlePath.hasPrefix("/Volumes/"),
                   Bundle.main.bundleURL.standardizedFileURL != installedAppURL.standardizedFileURL {
                    try? FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { openInstalledAppAndQuit() }
            } else {
                phase = .failed(lastError ?? "The install stopped before it finished.")
            }
        })
        if installer == nil { phase = .failed("The installer couldn't start.") }
    }

    func shutdown() { installer?.stop() }

    /// Closing the window would quit mid-install before anything could ask; it waits until the install ends.
    private func setCloseButton(enabled: Bool) {
        for w in NSApp.windows { w.standardWindowButton(.closeButton)?.isEnabled = enabled }
    }
}

struct SetupView: View {
    @ObservedObject var m: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppHeader(subtitle: m.upgrading ? "A one-time upgrade to the new version" : "Let's get Halo 3 running on your Mac")
            switch m.phase {
            case .checking, .blocked, .ready: checklist
            case .installing, .failed, .done: progressList
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    // requirements, what to expect, Install
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(m.checks) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "xmark.circle.fill" : "info.circle.fill")
                            .foregroundStyle(c.ok == true ? accent : c.ok == false ? .red : .secondary)
                            .font(.title3).frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.title).font(.headline)
                            if !c.detail.isEmpty {
                                Text(c.detail).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if m.needsDevTools {
                    HStack {
                        Button(m.waitingForDevTools ? "Waiting for the install to finish…" : "Install Apple's developer tools") {
                            m.installDevTools()
                        }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(m.waitingForDevTools)
                        if m.waitingForDevTools { ProgressView().controlSize(.small) }
                    }
                }
                if m.needsLicense {
                    HStack {
                        Button(m.acceptingLicense ? "Waiting for your password…" : "Accept Xcode's license") {
                            m.acceptLicense()
                        }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(m.acceptingLicense)
                        if m.acceptingLicense { ProgressView().controlSize(.small) }
                    }
                }
                if m.offersODST {
                    Divider()
                    Text("Games to download").font(.headline)
                    GameChecklist(halo3Size: "About 35 GB", odstSize: "About 9 GB more", odst: $m.withODST,
                                  odstNote: "For ODST's campaign, Firefight and co-op. You can add it later in Tools too.")
                }
                if m.phase == .blocked {
                    Button("Check Again") { m.runChecks() }.disabled(m.waitingForDevTools)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))

            Label {
                Text(m.upgrading
                     ? "Keeps your Halo 3 files, mods and settings. Takes a minute or two, and macOS may ask for your Mac password."
                     : "You'll need the **Steam app on your phone** (you scan a code with it, to download Halo 3 from your own account) and your **Mac password**. The download is about \(m.withODST ? 44 : 35) GB, so it can take a while: leave this window open (your Mac won't go to sleep meanwhile).")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } icon: { Image(systemName: "info.circle.fill").foregroundStyle(accent) }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(accent.opacity(0.12)))

            Button(action: m.install) {
                Label(m.upgrading ? "Upgrade" : "Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(PlayButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(m.phase != .ready)
        }
    }

    // the installer's steps, the QR code, the download bar
    private var progressList: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(m.steps.enumerated()), id: \.offset) { i, title in
                    let current = i == m.steps.count - 1 && m.phase == .installing
                    HStack(alignment: .top, spacing: 12) {
                        Group {
                            if current { ProgressView().controlSize(.small) }
                            else if i == m.steps.count - 1, case .failed = m.phase {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                            } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
                        }
                        .font(.title3).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(current ? .headline : .body)
                            if current, let s = m.status { Text(s).font(.callout).foregroundStyle(.secondary) }
                            if current, let p = m.progress {
                                ProgressView(value: p).tint(accent)
                                Text("\(Int(p * 100))%" + (m.remaining.map { " · \($0)" } ?? ""))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if current, m.qr != nil {
                        SignInCard(qr: m.qr)
                    }
                }
                if m.steps.isEmpty, m.phase == .installing {
                    HStack(spacing: 12) { ProgressView().controlSize(.small); Text("Starting…") }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(.background.secondary))

            switch m.phase {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                Button(action: m.install) { Label("Try Again", systemImage: "arrow.clockwise") }
                    .buttonStyle(PlayButtonStyle())
                Text("It picks up where it stopped.").font(.caption).foregroundStyle(.secondary)
            case .done:
                Label("All set! Opening Project Reclaimer…", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(accent)
                if !isInstalledApp {
                    Text("It's in your Applications folder now, so you can eject the disk image and move it to the Trash.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            default:
                Text(m.upgrading ? "Upgrading… keep this window open." : "Installing… keep this window open. Your Mac can stay in use meanwhile.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
