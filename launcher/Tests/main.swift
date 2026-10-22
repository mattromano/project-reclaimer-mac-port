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

// sound lines
check(SoundEvent(line: "ok\tChris AirPods Pro") == .ok(output: "Chris AirPods Pro"), "sound ok")
check(SoundEvent(line: "muted\tMacBook Pro Speakers") == .muted(output: "MacBook Pro Speakers"), "sound muted")
check(SoundEvent(line: "virtual\tMicrosoft Teams Audio") == .virtual(output: "Microsoft Teams Audio"), "sound virtual")
check(SoundEvent(line: "headset\tChris AirPods Pro\tMacBook Pro Speakers")
      == .headset("Chris AirPods Pro", output: "MacBook Pro Speakers"), "sound headset")
check(SoundEvent(line: "ok") == .other, "sound unknown stays quiet")
check(SoundEvent(line: "") == .other, "sound empty line")

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

// launch modes
let fm = FileManager.default
let h = fm.temporaryDirectory.appendingPathComponent("launcher-mode-\(getpid())")
try? fm.removeItem(at: h)
check(launchMode(home: h, isInstalledApp: false, installedAppExists: false) == .setup, "nothing installed")
try? fm.createDirectory(at: h.appendingPathComponent("game"), withIntermediateDirectories: true)
try? fm.createDirectory(at: h.appendingPathComponent("wine"), withIntermediateDirectories: true)
check(launchMode(home: h, isInstalledApp: false, installedAppExists: false) == .setup,
      "first install stopped before Halo 3 downloaded: Setup again, not Upgrade")
let mcc = h.appendingPathComponent("prefix-wine/drive_c/Program Files (x86)/Steam/steamapps/common/Halo The Master Chief Collection/halo3")
try? fm.createDirectory(at: mcc, withIntermediateDirectories: true)
fm.createFile(atPath: mcc.appendingPathComponent("halo3.dll").path, contents: Data())
fm.createFile(atPath: h.appendingPathComponent(".setup-incomplete").path, contents: Data())
check(launchMode(home: h, isInstalledApp: false, installedAppExists: false) == .setup,
      "first install stopped after the download (marker left): Setup again")
try? fm.removeItem(at: h.appendingPathComponent(".setup-incomplete"))
check(launchMode(home: h, isInstalledApp: true, installedAppExists: true) == .upgrade, "1.0 install")
try? "1.2.0".write(to: h.appendingPathComponent("version"), atomically: true, encoding: .utf8)
check(launchMode(home: h, isInstalledApp: false, installedAppExists: true) == .handOff, "DMG copy, installed")
check(launchMode(home: h, isInstalledApp: false, installedAppExists: false) == .launcher, "DMG copy, app deleted")
check(launchMode(home: h, isInstalledApp: true, installedAppExists: true) == .launcher, "installed app")
try? fm.removeItem(at: h.appendingPathComponent("wine"))
check(launchMode(home: h, isInstalledApp: true, installedAppExists: true) == .setup, "half-installed: setup resumes")
try? fm.removeItem(at: h)

// installer output in GUI mode
check(SetupEvent(line: "\u{1B}[1m==> Wine (Gcenx Wine Staging 11.18)\u{1B}[0m") == .step("Wine (Gcenx Wine Staging 11.18)"), "step")
check(SetupEvent(line: "progress: 42.5") == .progress(0.425), "progress")
check(SetupEvent(line: "error: Couldn't reach Steam.") == .error("Couldn't reach Steam."), "error")
check(SetupEvent(line: "qr-begin") == .steam(.qrBegin), "qr")
check(SetupEvent(line: "status: Signed in to Steam.") == .status("Signed in to Steam."), "status")
check(SetupEvent(line: "    ok") == .other, "other")
check(friendlyStep("Halo 3 game files (your Steam copy)") == "Downloading Halo 3 from your Steam account", "friendly")
check(friendlyStep("Project Reclaimer Mac Port") == nil && friendlyStep("Done") == nil, "hidden steps")
check(friendlyStep("Something new") == "Something new", "unknown steps shown as they are")

// time remaining
var est = RateEstimator()
let t0 = Date()
check(est.remaining(fraction: 0.10, now: t0) == nil, "first sample")
check(est.remaining(fraction: 0.20, now: t0.addingTimeInterval(60)) == "About 8 minutes left", "rate")
var est2 = RateEstimator()
_ = est2.remaining(fraction: 0, now: t0)
check(est2.remaining(fraction: 0.01, now: t0.addingTimeInterval(60)) == "About 2 hours left", "hours")

// release dates
let noon = ISO8601DateFormatter().date(from: "2026-10-10T12:00:00Z")!
check(relativeDay("2026-10-10", now: noon) == "today", "today")
check(relativeDay("2026-10-09", now: noon) == "yesterday", "yesterday")
check(relativeDay("2026-10-06", now: noon) == "4 days ago", "days ago")
check(relativeDay("soon", now: noon) == "soon", "unparseable stays as it is")
let listing = #"{"chosen": "0.9.11", "versions": [{"version": "0.9.12", "date": "2026-10-10", "downloaded": true}]}"#
check((try? JSONDecoder().decode(GameVersions.self, from: Data(listing.utf8)))?.chosen == "0.9.11", "versions json")

// failed joins
check(switchTarget(server: "0.9.7", mine: "0.9.13") == "0.9.7", "older server: its version")
check(switchTarget(server: "0.9.13", mine: "0.9.11") == "newest", "newer server: back to the newest")
check(switchTarget(server: "0.9.10", mine: "0.9.9") == "newest", "numeric, not text, comparison")
let gd = fm.temporaryDirectory.appendingPathComponent("launcher-gamedir-\(getpid())")
try? fm.createDirectory(at: gd, withIntermediateDirectories: true)
for n in ["project-reclaimer-v0.9.9.exe", "project-reclaimer-v0.9.13.exe", "project-reclaimer-dedicated-v0.9.13.exe"] {
    fm.createFile(atPath: gd.appendingPathComponent(n).path, contents: Data())
}
check(installedVersion(gameDir: gd) == "0.9.13", "newest exe: \(installedVersion(gameDir: gd) ?? "-")")
try? "0.9.11\n".write(to: gd.appendingPathComponent("chosen-version"), atomically: true, encoding: .utf8)
check(installedVersion(gameDir: gd) == "0.9.11", "chosen version")
try? fm.removeItem(at: gd)

// Apple's developer tools: present, missing, or there but blocked by Xcode's license (GitHub #10)
let licenseText = "You have not agreed to the Xcode license agreements. Please run 'sudo xcodebuild -license' from within a Terminal window to review and agree to the Xcode and Apple SDKs license."
check(devTools(selected: false, pythonStatus: nil, pythonOutput: "") == .missing, "no developer tools")
check(devTools(selected: true, pythonStatus: 0, pythonOutput: "") == .ok, "tools work")
check(devTools(selected: true, pythonStatus: 69, pythonOutput: licenseText + "\n") == .license, "license not accepted")
check(devTools(selected: true, pythonStatus: 1, pythonOutput: "xcrun: error: invalid active developer path") == .missing,
      "broken tools: install them again")
check(devTools(selected: true, pythonStatus: nil, pythonOutput: "") == .missing, "python couldn't start")
// a game that quit but left Wine running without a window
let w0 = Date(timeIntervalSince1970: 1_000_000)
let gameWin = WineWindow(number: 7, width: 2560, height: 1440, onscreen: true)
let minimized = WineWindow(number: 7, width: 2560, height: 1440, onscreen: false)
let helper = WineWindow(number: 3, width: 500, height: 500, onscreen: false)    // never on screen
let strip = WineWindow(number: 4, width: 1512, height: 33, onscreen: true)      // menu-bar strip
var wg = WindowlessGame()
check(!wg.isOver(windows: [helper], stopped: true, now: w0), "starting (no window shown yet): not over")
check(!wg.isOver(windows: [helper], stopped: true, now: w0 + 300), "never shown a window: never over")
check(!wg.isOver(windows: [helper, gameWin], stopped: false, now: w0 + 301), "game window on screen")
check(!wg.isOver(windows: [helper, minimized], stopped: false, now: w0 + 400), "minimized/other Space: still there")
check(!wg.isOver(windows: [helper, strip], stopped: true, now: w0 + 401), "window gone")
check(wg.goneSince == w0 + 401, "grace started")
check(!wg.isOver(windows: [helper, strip], stopped: true, now: w0 + 420), "gone 19 s: not yet")
check(!wg.isOver(windows: [gameWin], stopped: true, now: w0 + 420.5), "window back (a restart): not over")
check(wg.goneSince == nil, "grace reset")
check(!wg.isOver(windows: [helper], stopped: true, now: w0 + 421), "gone again: grace starts over")
check(!wg.isOver(windows: nil, stopped: true, now: w0 + 430), "windows couldn't be listed: never over")
check(wg.isOver(windows: [helper], stopped: true, now: w0 + 441), "gone 20 s after the runtime stopped: over")
var quiet = WindowlessGame()  // gone without the log saying the runtime stopped: the long grace
_ = quiet.isOver(windows: [gameWin], stopped: false, now: w0)
check(!quiet.isOver(windows: [], stopped: false, now: w0 + 1), "gone, log quiet")
check(!quiet.isOver(windows: [], stopped: false, now: w0 + 60), "60 s, log quiet: not yet")
check(quiet.isOver(windows: [], stopped: false, now: w0 + 121), "120 s: over")
var newer = WindowlessGame()  // a new window that is shown replaces the old one
_ = newer.isOver(windows: [gameWin], stopped: false, now: w0)
check(!newer.isOver(windows: [WineWindow(number: 9, width: 1920, height: 1080, onscreen: true)], stopped: true,
                    now: w0 + 100), "recreated window shown: not over")
let noWine = fm.temporaryDirectory.appendingPathComponent("no-wine-\(getpid())")
check(wineWindows(wineDir: noWine) == [], "nothing runs from a missing folder: no windows")

// controller axes, scaled by the range each control reports (8BitDo: 8-bit sticks; Xbox: 16-bit sticks, 10-bit triggers)
check(axisFraction(0, min: 0, max: 1023) == 0 && axisFraction(1023, min: 0, max: 1023) == 1, "10-bit trigger ends")
check(abs(axisFraction(512, min: 0, max: 1023) - 0.5) < 0.001, "10-bit trigger half way")
check(abs(stickPosition(32768, min: 0, max: 65535)) < 0.001, "16-bit stick centred")
check(stickPosition(0, min: 0, max: 65535) == -1 && stickPosition(65535, min: 0, max: 65535) == 1, "16-bit stick ends")
check(abs(stickPosition(128, min: 0, max: 255) - 0.0039) < 0.001, "8-bit stick centred")
check(stickPosition(-32768, min: -32768, max: 32767) == -1, "signed stick")
check(axisFraction(5, min: 0, max: 0) == 0 && axisFraction(900, min: 0, max: 255) == 1, "odd ranges stay in 0...1")

// D-pad hats count from their own minimum: 8BitDo 0...7, Xbox 1...8 (both north first, clockwise; outside = released)
check(hatDirections(1, min: 1, max: 8) == HatDirections(up: true), "Xbox hat 1 is up only")
check(hatDirections(3, min: 1, max: 8) == HatDirections(right: true), "Xbox hat 3 is right")
check(hatDirections(2, min: 1, max: 8) == HatDirections(up: true, right: true), "Xbox hat 2 is up-right")
check(hatDirections(0, min: 1, max: 8) == HatDirections(), "Xbox hat released")
check(hatDirections(0, min: 0, max: 7) == HatDirections(up: true) && hatDirections(8, min: 0, max: 7) == HatDirections(),
      "8BitDo hat")
// the controller window draws an Xbox controller's buttons where they are (not as an unmapped pad)
check(knownLayout(vendor: 0x045E)?["x"] == "b3" && knownLayout(vendor: 0x045E)?["y"] == "b4"
      && knownLayout(vendor: 0x045E)?["leftshoulder"] == "b6", "Xbox layout")
check(knownLayout(vendor: 0x057E)?["a"] == "b0" && knownLayout(vendor: 0x057E)?["b"] == "b1"
      && knownLayout(vendor: 0x057E)?["x"] == "b2", "Nintendo layout")
check(knownLayout(vendor: 0x1234) == nil, "unknown pads keep the unmapped view")
check(sdlWildcardGuid(vendorId: 0x057E, productId: 0x2009) == "030000007e0500000920000000000000", "Wildcard GUID")
check(sdlGuid(vendorId: 0x045E, productId: 0x028E, version: 0x0110) == "030000005e0400008e02000010010000", "Versioned GUID")
// a device's name goes into a comma-separated, one-per-line SDL mapping: it can't add fields or lines
check(sdlMappingName("Evil,pad\nguid,x,a:b0\r\u{0}") == "Evil pad guid x a:b0", "mapping name can't inject lines")
check(sdlMappingName("  \n") == "Game Controller" && sdlMappingName(nil) == "Game Controller", "empty names get a default")

// PlayStation pads are read through Apple's GameController framework, in its standard button order
check(readsThroughGameController(vendor: 0x054C) && !readsThroughGameController(vendor: 0x045E)
      && !readsThroughGameController(vendor: 0x2DC8), "only PlayStation pads use the GameController framework")
check(knownLayout(vendor: 0x054C)?["back"] == "b\(GCButton.back.rawValue)"
      && knownLayout(vendor: 0x054C)?["y"] == "b\(GCButton.y.rawValue)", "PlayStation layout follows GCButton")

// the machine-fit tier sets an expectation before Play; fit.py decides it (the window never measures RAM itself)
let constrainedFit = #"{"arch": "arm64", "cores": 8, "free_disk_gb": 120, "macos": "14.0", "ram_gb": 8, "screen": [2560, 1440], "tier": "constrained"}"#
let standardFit = #"{"arch": "arm64", "cores": 10, "free_disk_gb": 200, "macos": "14.0", "ram_gb": 32, "screen": [2560, 1440], "tier": "standard"}"#
let boundaryFit = #"{"arch": "arm64", "cores": 8, "free_disk_gb": 120, "macos": "14.0", "ram_gb": 16, "screen": [2560, 1440], "tier": "standard"}"#
check(machineTier(fitJSON: constrainedFit) == .constrained, "fit.py says 8 GB is constrained")
check(machineTier(fitJSON: standardFit) == .standard, "fit.py says 32 GB is standard")
check(machineTier(fitJSON: boundaryFit) == .standard, "fit.py says 16 GB is standard (the boundary)")
check(machineTier(fitJSON: "") == nil, "no answer from fit.py: no tier")
check(machineTier(fitJSON: "Traceback (most recent call last):") == nil, "a failing fit.py: no tier")
check(machineTier(fitJSON: #"{"ram_gb": 8}"#) == nil, "fit.py without a tier: no tier")
// a name this build doesn't know is standard: an unknown answer never invents a memory warning
check(machineTier(fitJSON: #"{"tier": "something-new"}"#) == .standard, "an unrecognised tier is standard")
check(machineTier(fitJSON: #"{"tier": 3}"#) == nil, "a tier that isn't a name: no tier")
let expectation = startupExpectation(tier: .constrained)
check(expectation != nil, "a constrained Mac is told before Play that the first start takes a long time")
check(expectation?.lowercased().contains("memory") == true, "the expectation says why: \(expectation ?? "-")")
check(startupExpectation(tier: .standard) == nil, "a standard Mac is told nothing")
check(startupExpectation(tier: nil) == nil, "fit.py couldn't answer: no warning, not a guess")
// what the window says about a starting game, from tools.py startup-state's one line (tested state by state)
func startup(_ state: String, elapsed: Double? = nil, detail: String? = nil,
             tier: Tier = .standard) -> StartupDisplay? {
    let seconds = elapsed.map { String($0) } ?? "null"
    var json = "{\"state\": \"\(state)\", \"elapsed_s\": \(seconds), \"stall_after_s\": 180"
    if let detail { json += ", \"detail\": \"\(detail)\"" }
    return startupDisplay(json: json + "}", tier: tier)
}

let sStarting = startup("starting", detail: "The game is starting.")
check(sStarting?.look == .working && sStarting?.warning == false, "starting: working, not a warning")
check(sStarting?.title == "Starting the game", "starting title: \(sStarting?.title ?? "-")")

let sBuilding = startup("building", elapsed: 132)
check(sBuilding?.look == .working, "building: still working")
check(sBuilding?.title == "Building the Forge asset library", "building title: \(sBuilding?.title ?? "-")")
check(sBuilding?.detail.contains("2 min 12 s") == true, "building says how long: \(sBuilding?.detail ?? "-")")
check(sBuilding?.detail.contains("first start takes a while") == true, "building sets the expectation")
check(sBuilding?.actions.isEmpty == true, "building offers no recovery actions")

// a long build is still a build: only the command calls a stall (it has the cache and the start time)
check(startup("building", elapsed: 9000)?.warning == false, "building for a long time is not the window's call")

let sReady = startup("ready", detail: "The game is up.")
check(sReady?.look == .done && sReady?.warning == false, "ready: done, not a warning")
check(sReady?.title == "Game ready" && sReady?.detail == "The game is up.", "ready: the game is up")

// a constrained Mac: the stall names memory as the likely cause, in plain words
let sStalled = startup("stalled", detail: "Startup stopped progressing: the Forge asset library has written nothing",
                       tier: .constrained)
check(sStalled?.look == .warning && sStalled?.warning == true, "stalled: a warning")
check(sStalled?.title == "Startup stopped progressing", "stalled says what happened: \(sStalled?.title ?? "-")")
check(sStalled?.detail.lowercased().contains("memory") == true,
      "stalled names memory as the likely cause: \(sStalled?.detail ?? "-")")
check(sStalled?.advice?.lowercased().contains("other apps") == true,
      "stalled says to quit other apps: \(sStalled?.advice ?? "-")")
check(sStalled?.advice?.lowercased().contains("try again") == true,
      "stalled says to try again: \(sStalled?.advice ?? "-")")
check(sStalled?.advice?.lowercased().contains("force-quit") == true,
      "stalled points at force-quit: \(sStalled?.advice ?? "-")")
for jargon in ["cache", "threshold", "wrote_this_run", "process"] {
    check(sStalled?.advice?.lowercased().contains(jargon) != true, "stalled advice has no jargon: \(jargon)")
}
check(sStalled?.look != .done, "a stall never claims the game is ready")

// a stall leaves both ways out in place: try again (Play, once the build is stopped) and force-quit
check(sStalled?.actions == [.tryAgain, .forceQuit], "stalled offers both actions: \(sStalled?.actions ?? [])")
check(sStalled?.actions.map(\.title) == ["Try Again", "Force Quit"], "stalled names both buttons plainly")

// a standard Mac (or one fit.py couldn't answer for) is told nothing about memory: user story 6
let sStalledStandard = startup("stalled", detail: "Startup stopped progressing: the Forge asset library has written nothing")
check(sStalledStandard?.look == .warning, "a standard Mac's stall is still a warning")
check(sStalledStandard?.title == sStalled?.title, "the stall is named the same way on every Mac")
check(sStalledStandard?.detail.lowercased().contains("memory") != true
      && sStalledStandard?.advice?.lowercased().contains("memory") != true,
      "a standard Mac is told nothing about memory: \(sStalledStandard?.detail ?? "-")")
check(sStalledStandard?.detail.lowercased().contains("progress") == true,
      "the neutral stall still says startup stopped progressing")
check(sStalledStandard?.actions == [.tryAgain, .forceQuit], "the neutral stall still offers both actions")
check(sStalledStandard?.advice?.lowercased().contains("try again") == true
      && sStalledStandard?.advice?.lowercased().contains("force-quit") == true,
      "the neutral stall names both ways out: \(sStalledStandard?.advice ?? "-")")
// no tier at all (fit.py never answered): still neutral, never a guess
check(startupDisplay(json: #"{"state": "stalled", "elapsed_s": 200}"#)?.detail.lowercased().contains("memory") != true,
      "no tier: a neutral stall, not a memory claim")

// the cache is still being written: the window keeps saying building, and offers no recovery
let sWriting = startupDisplay(json: #"{"state": "building", "elapsed_s": 132, "stall_after_s": 0, "wrote_this_run": true, "detail": "Building the Forge asset library."}"#)
check(sWriting?.look == .working && sWriting?.warning == false, "still writing: building, not a warning")
check(sWriting?.actions.isEmpty == true, "still writing: nothing to recover from")
check(sWriting?.advice == nil, "still writing: no advice")
check(sWriting?.detail.lowercased().contains("memory") == false, "still writing: no memory warning")

// a cache left by an earlier run: the command calls the stall, and the window passes that on rather than second-guessing
let sLeftover = startupDisplay(json: #"{"state": "stalled", "elapsed_s": 200, "stall_after_s": 180, "wrote_this_run": false}"#)
check(sLeftover?.warning == true, "a leftover cache does not hide the stall")
check(sLeftover?.actions.contains(.forceQuit) == true, "force quit stays offered while stalled")
check(sLeftover?.actions.contains(.tryAgain) == true, "trying again stays offered while stalled")

// Try Again stops the game first: only a stop that worked may be followed by a second start
check(tryAgainStep(forceQuitExit: 0, said: "ok") == .restart, "a game that stopped is started again")
let failedStop = tryAgainStep(forceQuitExit: 1,
                              said: "error: The game didn't stop. Restart your Mac (Apple menu > Restart) to close it.")
check(failedStop != .restart, "a game that didn't stop is not started again")
if case .failed(let why) = failedStop {
    check(why.contains("didn't stop") && why.contains("Restart your Mac"),
          "the player is told why, in the tool's own words: \(why)")
    check(!why.hasPrefix("error: "), "the error line's prefix is not passed on: \(why)")
} else {
    check(false, "a failed force-quit is a failed Try Again")
}
if case .failed(let why) = tryAgainStep(forceQuitExit: 1, said: "") {
    check(why.contains("didn't stop") && why.contains("Restart your Mac"),
          "a force quit that said nothing still explains itself: \(why)")
} else {
    check(false, "a force-quit that failed without a line is still a failure")
}

let sStopped = startup("stopped", detail: "The game isn't running.")
check(sStopped?.look == .stopped && sStopped?.warning == false, "stopped: not a warning")
check(sStopped?.title == "Game stopped" && sStopped?.detail == "The game isn't running.", "stopped: the game isn't running")

// `ready` is the game's own completion marker, and it is final: the log grows past the 400 KB the command reads, its
// marker falls out of it, and a later poll would say "starting" again. Once ready is seen, it stays (and asking stops).
check(sReady?.settled == true, "ready settles startup")
check(sBuilding?.settled == false && sStalled?.settled == false, "only ready settles startup")
check(sStopped?.settled == false, "a stopped game is not a settled start")

// while a stop is in flight the stall row offers nothing to press: two clicks would run two stops, and two games
let sStopping = sStalled?.whileStopping
check(sStopping?.actions.isEmpty == true, "a stop in flight offers no actions: \(sStopping?.actions ?? [])")
check(sStopping?.look == .working, "a stop in flight is working, not a warning")
check(sStopping?.title == "Stopping the game", "a stop in flight says what it is doing: \(sStopping?.title ?? "-")")
check(mayStop(stopping: false) && !mayStop(stopping: true), "a second stop cannot start over a stop in flight")
check(mayWatchForGameGone(playing: true, stopping: false), "a running game is watched")
check(!mayWatchForGameGone(playing: true, stopping: true),
      "while stopping, the game going away is expected: never judged gone")
check(!mayWatchForGameGone(playing: false, stopping: false), "nothing is watched when nothing plays")

// the note before Play is for the first start: once the Forge library exists there is no long build to expect
let noCacheAnswer = #"{"state": "stopped", "elapsed_s": null, "stall_after_s": 180, "wrote_this_run": false, "forge_cache": {"bytes": 0, "files": 0, "newest_age_s": null}}"#
let cacheAnswer = #"{"state": "stopped", "elapsed_s": null, "stall_after_s": 180, "wrote_this_run": false, "forge_cache": {"bytes": 8417280, "files": 96, "newest_age_s": 90000}}"#
check(forgeCacheBuilt(stateJSON: noCacheAnswer) == false, "no cache yet: the first build is still to come")
check(forgeCacheBuilt(stateJSON: cacheAnswer) == true, "a written cache: the library exists")
check(forgeCacheBuilt(stateJSON: "not json") == nil, "unreadable: no answer about the cache")
check(forgeCacheBuilt(stateJSON: #"{"state": "building"}"#) == nil, "no cache facts: no answer")
check(startupExpectation(tier: .constrained, cacheBuilt: false) != nil, "a constrained Mac's first start is named")
check(startupExpectation(tier: .constrained, cacheBuilt: true) == nil, "the library exists: no note on every launch")
check(startupExpectation(tier: .constrained, cacheBuilt: nil) != nil,
      "no answer about the cache keeps the note rather than guessing")
check(startupExpectation(tier: .standard, cacheBuilt: false) == nil, "a standard Mac is still told nothing")

// no detail from the command: the window still has a plain line to show
check(startup("ready")?.detail == "The game is up.", "ready without a detail line")
check(startup("building")?.detail == "Building. The first start takes a while.", "building without an elapsed time")
check(startup("building", elapsed: 0)?.detail.contains("0 s") == true, "building at zero seconds")

// unreadable or failing: no verdict at all, so the window keeps exactly the behaviour it had before
check(startupDisplay(json: "") == nil, "no answer: no verdict")
check(startupDisplay(json: "error: Permission denied") == nil, "a failure line: no verdict")
check(startupDisplay(json: "not json at all") == nil, "garbage: no verdict")
check(startupDisplay(json: "{\"state\": \"ready\"") == nil, "truncated json: no verdict")
check(startupDisplay(json: #"{"state": "warming-up"}"#) == nil, "a state the window doesn't know: no verdict")

// how long startup has been going, said plainly
check(elapsedText(0) == "0 s" && elapsedText(45) == "45 s", "seconds")
check(elapsedText(132) == "2 min 12 s" && elapsedText(600) == "10 min", "minutes")
check(elapsedText(3720) == "1 h 2 min" && elapsedText(3600) == "1 h", "hours")
check(elapsedText(-5) == "0 s", "never negative")

// memory, as fit.py decides it: under 16 GB is constrained (and unknown RAM isn't)
check(memoryGigabytes(8 * 1 << 30) == 8 && isConstrainedMemory(8 * 1 << 30), "8 GB Mac: constrained")
check(!isConstrainedMemory(16 * 1 << 30) && !isConstrainedMemory(0), "16 GB and unknown: not constrained")
// Setup counts RAM itself and fit.py decides the tier after install: they can't share a source, so pin both to the
// same boundary. fit.py's own answer for these numbers is pinned in tests/test_fit.py.
for (ramGB, expected) in [(8, Tier.constrained), (16, Tier.standard)] {
    check(isConstrainedMemory(UInt64(ramGB) << 30) == (expected == .constrained),
          "Setup's memory check agrees with fit.py's tier at \(ramGB) GB")
}
check(friendlyStep("This Mac") == "Checking this Mac's memory", "installer's This Mac step")

// which running processes are this installation's: the working directory decides, by whole path components
check(insideInstall("/Users/p/Games/ProjectReclaimer/game", root: "/Users/p/Games/ProjectReclaimer"),
      "the game folder is inside")
check(insideInstall("/Users/p/Games/ProjectReclaimer/game/versions", root: "/Users/p/Games/ProjectReclaimer"),
      "an older release's folder is inside")
check(insideInstall("/Users/p/Games/ProjectReclaimer", root: "/Users/p/Games/ProjectReclaimer/"),
      "the install itself, with a trailing slash on the root")
check(!insideInstall("/Users/p/Games/ProjectReclaimer2/game", root: "/Users/p/Games/ProjectReclaimer"),
      "a sibling whose name starts the same is not inside")
check(!insideInstall("/Users/p/Games/ProjectReclaimer", root: "/Users/p/Games/ProjectReclaimer/game"),
      "the install is not inside its own game folder")
check(!insideInstall("/", root: "/Users/p/Games/ProjectReclaimer"), "root is not inside an install")
check(insideInstall("/private/var/folders/x/PR/game", root: "/var/folders/x/PR"),
      "lsof's real path matches the path the window was given")

print(failures == 0 ? "All launcher tests passed" : "\(failures) launcher test(s) failed")
exit(failures == 0 ? 0 : 1)
