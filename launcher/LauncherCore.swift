// LauncherCore: everything the launcher window needs that isn't UI: reading the helper scripts' output lines,
// the QR code DepotDownloader draws, and the per-mod status files. Tested by launcher/Tests/main.swift.
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
        case "ready": return hint ?? "Ready"
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
