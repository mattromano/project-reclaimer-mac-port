// Tests for LauncherCore.swift. Run: scripts/make_launcher.sh test
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// updater lines
check(UpdaterEvent(line: "status: Checking for updates…") == .status("Checking for updates…"), "status")
check(UpdaterEvent(line: "progress: 37") == .progress(0.37), "progress")
check(UpdaterEvent(line: "progress: 140") == .progress(1), "progress clamps")
check(UpdaterEvent(line: "relaunch") == .relaunch, "relaunch")
check(UpdaterEvent(line: "done: up to date") == .done("up to date"), "done")
check(UpdaterEvent(line: "offline: timed out") == .offline("timed out"), "offline")
check(UpdaterEvent(line: "error: checksum") == .error("checksum"), "error")
check(UpdaterEvent(line: "    ok") == .other, "other")

// steam lines
check(SteamEvent(line: "ok RealName_1") == .ok(account: "RealName_1"), "ok")
check(SteamEvent(line: "need-login") == .needLogin, "need-login")
check(SteamEvent(line: "offline") == .offline, "offline")
check(SteamEvent(line: "error: Expired") == .error("Expired"), "error")
check(SteamEvent(line: "qr:   ██") == .qrRow("  ██"), "qr row keeps leading spaces")

// QR grid from real DepotDownloader output (captured 2026-10-10 from DepotDownloader 3.4.0, 37 rows)
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let captured = (try? String(contentsOf: here.appendingPathComponent("qr-sample.txt"), encoding: .utf8)) ?? ""
var collector = QRCollector()
for line in captured.split(separator: "\n", omittingEmptySubsequences: false) {
    collector.handle(SteamEvent(line: String(line)))
}
if let g = collector.current {
    check(g.size == 37, "37 rows, got \(g.size)")
    check(g.modules.allSatisfy { $0.count == 37 }, "square")
    check(g.modules[0].allSatisfy { !$0 }, "quiet zone row is light")
    // finder pattern: the top-left 7x7 square's top edge is dark (after the 4-module quiet zone)
    check((4..<11).allSatisfy { g.modules[4][$0] }, "finder pattern top edge")
    check(!g.modules[5][5] && g.modules[6][6], "finder pattern ring then centre")
} else {
    check(false, "no QR parsed from sample")
}
check(QRGrid(rows: ["    ", "    "]) == nil, "all-light grid is no QR")
check(QRGrid(rows: ["██  ██", "██"])?.modules[1] == [true, false, false], "short rows padded light")

// a refreshed code replaces the old one; a half-received code doesn't
var c2 = QRCollector()
for l in ["qr-begin", "qr: ██", "qr-end", "qr-begin", "qr:   ██"] { c2.handle(SteamEvent(line: l)) }
check(c2.current?.modules == [[true]], "keeps last complete code until the new one ends")
c2.handle(SteamEvent(line: "qr-end"))
check(c2.current?.modules == [[false, true]], "new code after qr-end")

// workshop links
check(workshopID(from: "https://steamcommunity.com/sharedfiles/filedetails/?id=2984061723") == "2984061723", "link")
check(workshopID(from: "https://steamcommunity.com/sharedfiles/filedetails/?l=en&id=123&searchtext=") == "123", "link id later")
check(workshopID(from: " 456 \n") == "456", "bare id")
check(workshopID(from: "Warlock") == nil, "title is not an id")
check(workshopID(from: "") == nil, "empty")

// mod status files
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launcher-tests-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let now = Date().timeIntervalSince1970
func write(_ name: String, _ json: String) { try? json.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
write("1.json", #"{"id":"1","title":"Warlock","state":"downloading","percent":68.75,"bytes_total":1600000000,"time":\#(now)}"#)
write("2.json", #"{"id":"2","title":"Lockout","state":"ready","percent":100,"hint":"Press Try Again in the game.","time":\#(now - 1)}"#)
write("3.json", #"{"id":"3","title":"Old","state":"ready","time":\#(now - 99999)}"#)
write("4.tmp", "{")
write("5.json", "not json")
let mods = ModStatus.load(directory: dir, since: Date(timeIntervalSinceNow: -3600))
check(mods.map(\.id) == ["1", "2"], "recent mods only, newest first: \(mods.map(\.id))")
check(mods.first?.detail == "1.1 GB of 1.6 GB", "progress detail: \(mods.first?.detail ?? "-")")
check(mods.last?.detail == "Ready. Press Try Again in the game.", "ready detail")
check(ModStatus(id: "9", state: "downloading", percent: 12, time: 0).detail == "Downloading from Steam Workshop…",
      "no size known (Steam reports 0 for most MCC mods)")
check(ModStatus.load(directory: dir.appendingPathComponent("missing"), since: .distantPast).isEmpty, "missing dir")
try? FileManager.default.removeItem(at: dir)

check(gigabytes(8.9e9) == "8.9 GB" && gigabytes(250e6) == "250 MB", "sizes")

// notifications: one when a download starts, one when it's ready; nothing for unchanged or pre-existing mods
let dl = ModStatus(id: "7", title: "Hugegrass", state: "downloading", percent: 10, time: 1)
var ready = dl; ready.state = "ready"
let old = ModStatus(id: "8", title: "Lockout", state: "ready", time: 1)
check(modNotifications(before: [], after: [dl]).map(\.title) == ["Getting Hugegrass for you"], "download starts")
check(modNotifications(before: [dl], after: [dl]).isEmpty, "no repeat while downloading")
check(modNotifications(before: [dl], after: [ready]).map(\.title) == ["Hugegrass is ready"], "ready")
check(modNotifications(before: [], after: [old]).isEmpty, "already-ready mod at startup: no notification")
check(modNotifications(before: [ready], after: [ready]).isEmpty, "no repeat when ready")

print(failures == 0 ? "All launcher tests passed" : "\(failures) launcher test(s) failed")
exit(failures == 0 ? 0 : 1)
