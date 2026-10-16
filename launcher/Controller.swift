// Controller: Test and calibrate game controllers directly before Play.
// Discovers IOHID devices, runs live input tests, tests haptic rumble, and manages gamecontrollerdb.txt.
import AppKit
import SwiftUI
import IOKit.hid

struct ControllerDevice: Identifiable, Equatable {
    let id: String
    let device: IOHIDDevice
    let name: String
    let vendorId: Int
    let productId: Int
    let guid: String
    let is8BitDo: Bool

    static func == (lhs: ControllerDevice, rhs: ControllerDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ControllerManager: ObservableObject {
    @Published var devices: [ControllerDevice] = []
    @Published var playerAssignments: [Int] = [0, 1, 2, 3]
    @Published var selectedPlayerIndex: Int = 0 {
        didSet {
            loadActiveMapping()
            resetInputState()
        }
    }
    @Published var pingingIndex: Int?

    var currentDeviceIndex: Int {
        if playerAssignments.indices.contains(selectedPlayerIndex) {
            let devIdx = playerAssignments[selectedPlayerIndex]
            if devices.indices.contains(devIdx) { return devIdx }
        }
        return devices.indices.contains(selectedPlayerIndex) ? selectedPlayerIndex : 0
    }

    var currentDevice: ControllerDevice? {
        guard devices.indices.contains(currentDeviceIndex) else { return nil }
        return devices[currentDeviceIndex]
    }

    // Live test states for the selected device
    @Published var pressedButtons: Set<Int> = []
    @Published var dpadState: (up: Bool, down: Bool, left: Bool, right: Bool) = (false, false, false, false)
    @Published var leftStick: CGPoint = .zero
    @Published var rightStick: CGPoint = .zero
    @Published var leftTrigger: Double = 0.0
    @Published var rightTrigger: Double = 0.0
    @Published var isVibrating = false
    @Published var activeMapping: [String: String] = [:]

    // Calibration wizard state
    enum CalibStep: Int, CaseIterable {
        case a, b, x, y, lb, rb, lt, rt, back, start, l3, r3, done
        var prompt: String {
            switch self {
            case .a: return "Press A (South Button)"
            case .b: return "Press B (East Button)"
            case .x: return "Press X (West Button)"
            case .y: return "Press Y (North Button)"
            case .lb: return "Press LB (Left Bumper)"
            case .rb: return "Press RB (Right Bumper)"
            case .lt: return "Squeeze & Release LT (Left Trigger)"
            case .rt: return "Squeeze & Release RT (Right Trigger)"
            case .back: return "Press Back / View"
            case .start: return "Press Start / Menu"
            case .l3: return "Click Left Stick (L3)"
            case .r3: return "Click Right Stick (R3)"
            case .done: return "Calibration Complete! Saved."
            }
        }
    }
    @Published var calibrating = false
    @Published var currentStep: CalibStep = .a
    @Published var statusMessage: String?

    private var capturedMapping: [String: String] = [:]
    private var hidManager: IOHIDManager?
    private var canAdvanceStep = true
    private var triggerArmed = false
    private var stepArmedTime = Date()

    init() {
        start()
    }

    func start() {
        guard hidManager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr
        IOHIDManagerSetDeviceMatching(mgr, nil)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchCallback: IOHIDDeviceCallback = { ctx, res, sender, dev in
            guard let ctx = ctx else { return }
            let selfPtr = Unmanaged<ControllerManager>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in selfPtr.scanDevices() }
        }

        let removeCallback: IOHIDDeviceCallback = { ctx, res, sender, dev in
            guard let ctx = ctx else { return }
            let selfPtr = Unmanaged<ControllerManager>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in selfPtr.scanDevices() }
        }

        let valueCallback: IOHIDValueCallback = { ctx, res, sender, val in
            guard let ctx = ctx else { return }
            let selfPtr = Unmanaged<ControllerManager>.fromOpaque(ctx).takeUnretainedValue()
            selfPtr.handleInputValue(val)
        }

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, matchCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, removeCallback, context)
        IOHIDManagerRegisterInputValueCallback(mgr, valueCallback, context)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        scanDevices()
    }

    func stop() {
        if let mgr = hidManager {
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            hidManager = nil
        }
        devices.removeAll()
    }

    func scanDevices() {
        guard let mgr = hidManager, let set = IOHIDManagerCopyDevices(mgr) else {
            devices.removeAll()
            return
        }
        let count = CFSetGetCount(set)
        var devicePtrs = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(set, &devicePtrs)

        var found: [ControllerDevice] = []

        for (idx, ptr) in devicePtrs.enumerated() {
            guard let ptr = ptr else { continue }
            let dev = unsafeBitCast(ptr, to: IOHIDDevice.self)
            let vid = (IOHIDDeviceGetProperty(dev, "VendorID" as CFString) as? Int) ?? 0
            let pid = (IOHIDDeviceGetProperty(dev, "ProductID" as CFString) as? Int) ?? 0
            let usage = (IOHIDDeviceGetProperty(dev, "PrimaryUsage" as CFString) as? Int) ?? 0
            let rawName = (IOHIDDeviceGetProperty(dev, "Product" as CFString) as? String) ?? "Game Controller"

            guard vid > 0 && pid > 0, vid != 0x05AC, (usage == 5 || usage == 4 || vid == 0x2DC8 || vid == 0x057E) else {
                continue
            }

            let name: String
            let guid: String
            let is8B: Bool

            if vid == 0x2DC8 {
                name = rawName.isEmpty ? "8BitDo Controller" : rawName
                guid = "030022e4c82d00002f20000000010000"
                is8B = true
            } else if vid == 0x057E {
                name = "Nintendo Switch Pro Controller"
                guid = "030000007e0500000920000000000000"
                is8B = false
            } else {
                name = rawName
                guid = String(format: "030022e4%02x%02x0000%02x%02x000000010000",
                              vid & 0xff, (vid >> 8) & 0xff,
                              pid & 0xff, (pid >> 8) & 0xff)
                is8B = false
            }

            IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
            let id = "\(vid)-\(pid)-\(idx)"
            found.append(ControllerDevice(id: id, device: dev, name: name,
                                          vendorId: vid, productId: pid,
                                          guid: guid, is8BitDo: is8B))
        }

        self.devices = found
        var newAssignments: [Int] = []
        for i in 0..<max(1, found.count) {
            newAssignments.append(i < found.count ? i : 0)
        }
        self.playerAssignments = newAssignments
        if selectedPlayerIndex >= found.count {
            selectedPlayerIndex = max(0, found.count - 1)
        }
        loadActiveMapping()
    }

    private func resetInputState() {
        pressedButtons.removeAll()
        dpadState = (false, false, false, false)
        leftStick = .zero
        rightStick = .zero
        leftTrigger = 0.0
        rightTrigger = 0.0
    }

    private func loadActiveMapping() {
        guard let current = currentDevice, !current.guid.isEmpty else { return }
        let dbPath = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["RECLAIMER_HOME"]
                                            ?? "\(NSHomeDirectory())/Games/ProjectReclaimer"))
            .appendingPathComponent("game/gamecontrollerdb.txt")

        activeMapping = [
            "a": "b0", "b": "b1", "x": "b3", "y": "b4",
            "leftshoulder": "b6", "rightshoulder": "b7",
            "back": "b10", "start": "b11", "guide": "b12",
            "leftstick": "b13", "rightstick": "b14"
        ]

        if let content = try? String(contentsOf: dbPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines).reversed() {
                if line.starts(with: current.guid) {
                    let parts = line.components(separatedBy: ",")
                    for part in parts.dropFirst(2) {
                        let kv = part.components(separatedBy: ":")
                        if kv.count == 2 {
                            activeMapping[kv[0]] = kv[1]
                        }
                    }
                    break
                }
            }
        }
    }

    func isActionPressed(_ action: String) -> Bool {
        guard let target = activeMapping[action] else { return false }
        if target.starts(with: "b"), let btn = Int(target.dropFirst()) {
            return pressedButtons.contains(btn)
        }
        return false
    }

    private func handleInputValue(_ value: IOHIDValue) {
        guard let current = currentDevice else { return }
        let elem = IOHIDValueGetElement(value)
        let senderDev = IOHIDElementGetDevice(elem)

        // Only process events from the currently selected player's controller
        guard senderDev == current.device else { return }

        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let intVal = IOHIDValueGetIntegerValue(value)

        Task { @MainActor in
            // Handle Nintendo Switch Pro Controller Vendor-Defined Report (page 65281 / 0xFF01)
            if page == 65281 && usage == 48 {
                let len = IOHIDValueGetLength(value)
                guard len >= 11 else { return }
                let ptr = IOHIDValueGetBytePtr(value)
                let b = Array(UnsafeBufferPointer(start: ptr, count: len))

                let b2 = b[2]
                let b3 = b[3]
                let b4 = b[4]

                // Switch buttons (0=A, 1=B, 2=X, 3=Y, etc.)
                var newPressed = Set<Int>()
                if (b2 & 0x08) != 0 { newPressed.insert(0) } // A
                if (b2 & 0x04) != 0 { newPressed.insert(1) } // B
                if (b2 & 0x02) != 0 { newPressed.insert(3) } // X
                if (b2 & 0x01) != 0 { newPressed.insert(4) } // Y
                if (b4 & 0x40) != 0 { newPressed.insert(6) } // LB
                if (b2 & 0x40) != 0 { newPressed.insert(7) } // RB
                if (b3 & 0x01) != 0 { newPressed.insert(10) } // Minus / Back
                if (b3 & 0x02) != 0 { newPressed.insert(11) } // Plus / Start
                if (b3 & 0x10) != 0 { newPressed.insert(12) } // Home / Guide
                if (b3 & 0x08) != 0 { newPressed.insert(13) } // L3
                if (b3 & 0x04) != 0 { newPressed.insert(14) } // R3

                self.pressedButtons = newPressed

                // D-Pad
                dpadState.down = (b4 & 0x01) != 0
                dpadState.up = (b4 & 0x02) != 0
                dpadState.right = (b4 & 0x04) != 0
                dpadState.left = (b4 & 0x08) != 0

                // Triggers
                leftTrigger = (b4 & 0x80) != 0 ? 1.0 : 0.0
                rightTrigger = (b2 & 0x80) != 0 ? 1.0 : 0.0

                // Sticks (12-bit unsigned, center ~2048)
                let rawLX = Int(b[5]) | (Int(b[6] & 0x0F) << 8)
                let rawLY = Int(b[6] >> 4) | (Int(b[7]) << 4)
                let rawRX = Int(b[8]) | (Int(b[9] & 0x0F) << 8)
                let rawRY = Int(b[9] >> 4) | (Int(b[10]) << 4)

                leftStick.x = max(-1.0, min(1.0, Double(rawLX - 2048) / 1400.0))
                leftStick.y = max(-1.0, min(1.0, -Double(rawLY - 2048) / 1400.0))
                rightStick.x = max(-1.0, min(1.0, Double(rawRX - 2048) / 1400.0))
                rightStick.y = max(-1.0, min(1.0, -Double(rawRY - 2048) / 1400.0))

                if calibrating && canAdvanceStep && !newPressed.isEmpty {
                    if let firstBtn = newPressed.first {
                        recordCalibrationButton(firstBtn)
                    }
                }
                return
            }

            // Standard HID Gamepad Parsing (8BitDo, Xbox, etc.)
            if page == 9 { // Button
                let btn = Int(usage - 1)
                if intVal == 1 {
                    pressedButtons.insert(btn)
                    if calibrating && currentStep != .lt && currentStep != .rt {
                        if btn != 8 && btn != 9 && canAdvanceStep && Date().timeIntervalSince(stepArmedTime) > 0.3 {
                            recordCalibrationButton(btn)
                        }
                    }
                } else {
                    pressedButtons.remove(btn)
                    if calibrating && !canAdvanceStep && pressedButtons.isEmpty {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            self.canAdvanceStep = true
                        }
                    }
                }
            } else if page == 1 { // Generic Desktop (Sticks / D-Pad)
                if usage == 0x39 { // Hat switch (D-Pad)
                    if intVal >= 0 && intVal <= 7 {
                        dpadState.up = (intVal == 7 || intVal == 0 || intVal == 1)
                        dpadState.right = (intVal == 1 || intVal == 2 || intVal == 3)
                        dpadState.down = (intVal == 3 || intVal == 4 || intVal == 5)
                        dpadState.left = (intVal == 5 || intVal == 6 || intVal == 7)
                    } else {
                        dpadState = (false, false, false, false)
                    }
                } else if usage == 0x30 { // X axis
                    leftStick.x = Double(intVal - 128) / 128.0
                } else if usage == 0x31 { // Y axis
                    leftStick.y = Double(intVal - 128) / 128.0
                } else if usage == 0x32 { // Z axis / Right Stick X
                    rightStick.x = Double(intVal - 128) / 128.0
                } else if usage == 0x35 { // Rz axis / Right Stick Y
                    rightStick.y = Double(intVal - 128) / 128.0
                }
            } else if page == 2 { // Simulation controls (Triggers)
                if usage == 0xC5 { // Left Trigger (Brake)
                    leftTrigger = Double(intVal) / 255.0
                    handleTriggerCalibration(isLeft: true, value: leftTrigger)
                } else if usage == 0xC4 { // Right Trigger (Accelerator)
                    rightTrigger = Double(intVal) / 255.0
                    handleTriggerCalibration(isLeft: false, value: rightTrigger)
                }
            }
        }
    }

    private func handleTriggerCalibration(isLeft: Bool, value: Double) {
        guard calibrating else { return }
        if isLeft && currentStep == .lt {
            if value > 0.5 {
                triggerArmed = true
            } else if value < 0.2 && triggerArmed {
                triggerArmed = false
                capturedMapping["lefttrigger"] = "a5"
                currentStep = .rt
                stepArmedTime = Date()
            }
        } else if !isLeft && currentStep == .rt {
            if value > 0.5 {
                triggerArmed = true
            } else if value < 0.2 && triggerArmed {
                triggerArmed = false
                capturedMapping["righttrigger"] = "a4"
                currentStep = .back
                canAdvanceStep = false
                stepArmedTime = Date()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    self.canAdvanceStep = true
                }
            }
        }
    }

    func ping(playerIdx: Int) {
        let devIdx = playerAssignments.indices.contains(playerIdx) ? playerAssignments[playerIdx] : playerIdx
        guard devices.indices.contains(devIdx) else { return }
        let dev = devices[devIdx]
        pingingIndex = playerIdx

        Task.detached {
            if dev.is8BitDo {
                var pkt: [UInt8] = [0x05, 0xff, 0xff, 0x64, 0x64]
                IOHIDDeviceSetReport(dev.device, kIOHIDReportTypeOutput, 0x05, &pkt, pkt.count)
                try? await Task.sleep(nanoseconds: 400_000_000)
                var stop: [UInt8] = [0x05, 0x00, 0x00, 0x00, 0x00]
                IOHIDDeviceSetReport(dev.device, kIOHIDReportTypeOutput, 0x05, &stop, stop.count)
            } else if dev.vendorId == 0x057E {
                var pkt = [UInt8](repeating: 0, count: 49)
                pkt[0] = 0x10; pkt[1] = 0x01
                pkt[2] = 0x28; pkt[3] = 0x88; pkt[4] = 0x60; pkt[5] = 0x61
                pkt[6] = 0x28; pkt[7] = 0x88; pkt[8] = 0x60; pkt[9] = 0x61
                IOHIDDeviceSetReport(dev.device, kIOHIDReportTypeOutput, 0x10, &pkt, pkt.count)
                try? await Task.sleep(nanoseconds: 400_000_000)
                var stop = [UInt8](repeating: 0, count: 49)
                stop[0] = 0x10; stop[1] = 0x02
                stop[2] = 0x00; stop[3] = 0x01; stop[4] = 0x40; stop[5] = 0x40
                stop[6] = 0x00; stop[7] = 0x01; stop[8] = 0x40; stop[9] = 0x40
                IOHIDDeviceSetReport(dev.device, kIOHIDReportTypeOutput, 0x10, &stop, stop.count)
            } else {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            await MainActor.run { self.pingingIndex = nil }
        }
    }

    func startCalibration() {
        calibrating = true
        currentStep = .a
        capturedMapping.removeAll()
        canAdvanceStep = true
        triggerArmed = false
        stepArmedTime = Date()
        statusMessage = "Follow the prompts. Press each button on the selected controller, or click Skip."
    }

    func skipStep() {
        guard calibrating else { return }
        canAdvanceStep = true
        triggerArmed = false
        stepArmedTime = Date()

        switch currentStep {
        case .a: currentStep = .b
        case .b: currentStep = .x
        case .x: currentStep = .y
        case .y: currentStep = .lb
        case .lb: currentStep = .rb
        case .rb: currentStep = .lt
        case .lt: currentStep = .rt
        case .rt: currentStep = .back
        case .back: currentStep = .start
        case .start: currentStep = .l3
        case .l3: currentStep = .r3
        case .r3:
            capturedMapping["dpup"] = "h0.1"
            capturedMapping["dpdown"] = "h0.4"
            capturedMapping["dpleft"] = "h0.8"
            capturedMapping["dpright"] = "h0.2"
            capturedMapping["leftx"] = "a0"
            capturedMapping["lefty"] = "a1"
            capturedMapping["rightx"] = "a2"
            capturedMapping["righty"] = "a3"
            saveMapping()
            currentStep = .done
            calibrating = false
            statusMessage = "Mapping saved for \(currentDevice?.name ?? "controller")!"
        default: break
        }
    }

    private func recordCalibrationButton(_ button: Int) {
        guard calibrating, canAdvanceStep else { return }
        canAdvanceStep = false
        stepArmedTime = Date()

        switch currentStep {
        case .a: capturedMapping["a"] = "b\(button)"; currentStep = .b
        case .b: capturedMapping["b"] = "b\(button)"; currentStep = .x
        case .x: capturedMapping["x"] = "b\(button)"; currentStep = .y
        case .y: capturedMapping["y"] = "b\(button)"; currentStep = .lb
        case .lb: capturedMapping["leftshoulder"] = "b\(button)"; currentStep = .rb
        case .rb: capturedMapping["rightshoulder"] = "b\(button)"; currentStep = .lt
        case .lt: break
        case .rt: break
        case .back: capturedMapping["back"] = "b\(button)"; currentStep = .start
        case .start: capturedMapping["start"] = "b\(button)"; currentStep = .l3
        case .l3: capturedMapping["leftstick"] = "b\(button)"; currentStep = .r3
        case .r3:
            capturedMapping["rightstick"] = "b\(button)"
            capturedMapping["dpup"] = "h0.1"
            capturedMapping["dpdown"] = "h0.4"
            capturedMapping["dpleft"] = "h0.8"
            capturedMapping["dpright"] = "h0.2"
            capturedMapping["leftx"] = "a0"
            capturedMapping["lefty"] = "a1"
            capturedMapping["rightx"] = "a2"
            capturedMapping["righty"] = "a3"
            saveMapping()
            currentStep = .done
            calibrating = false
            statusMessage = "Mapping saved for \(currentDevice?.name ?? "controller")!"
        default: break
        }
    }

    private func saveMapping() {
        guard let current = currentDevice, !current.guid.isEmpty else { return }
        activeMapping = capturedMapping
        let mapEntries = capturedMapping.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        let line = "\(current.guid),\(current.name),\(mapEntries),platform:Mac OS X,\n"

        let dbPath = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["RECLAIMER_HOME"]
                                            ?? "\(NSHomeDirectory())/Games/ProjectReclaimer"))
            .appendingPathComponent("game/gamecontrollerdb.txt")

        if let existing = try? String(contentsOf: dbPath, encoding: .utf8) {
            let filtered = existing.components(separatedBy: .newlines).filter { !$0.starts(with: current.guid) && !$0.isEmpty }.joined(separator: "\n")
            try? (filtered + "\n" + line).write(to: dbPath, atomically: true, encoding: .utf8)
        } else {
            try? line.write(to: dbPath, atomically: true, encoding: .utf8)
        }

        let launchPath = URL(fileURLWithPath: (ProcessInfo.processInfo.environment["RECLAIMER_HOME"]
                                               ?? "\(NSHomeDirectory())/Games/ProjectReclaimer"))
            .appendingPathComponent("game/launch.sh")

        if let launchSrc = try? String(contentsOf: launchPath, encoding: .utf8) {
            let re = try? NSRegularExpression(pattern: "export SDL_GAMECONTROLLERCONFIG=\"[^\"]*\"", options: [])
            let replacement = "export SDL_GAMECONTROLLERCONFIG=\"\(line.trimmingCharacters(in: .newlines))\""
            let updated = re?.stringByReplacingMatches(in: launchSrc, options: [], range: NSRange(location: 0, length: launchSrc.utf16.count), withTemplate: replacement) ?? launchSrc
            try? updated.write(to: launchPath, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Exact Vector Outline (from official SVG viewBox 0 0 441 403)

struct ExactXboxBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let sx = rect.width / 441.0
        let sy = rect.height / 403.0

        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * sx, y: y * sy)
        }

        p.move(to: pt(220.5, 92))
        p.addCurve(to: pt(128, 92), control1: pt(200.5, 92), control2: pt(154, 92))
        p.addCurve(to: pt(55, 137.5), control1: pt(95.5, 92), control2: pt(66.5, 109.5))
        p.addCurve(to: pt(4, 317.5), control1: pt(43.5, 165.5), control2: pt(4, 271.1))
        p.addCurve(to: pt(49.5, 378.5), control1: pt(4, 363.9), control2: pt(17.5, 378.5))
        p.addCurve(to: pt(150, 294.5), control1: pt(81.5, 378.5), control2: pt(105, 294.5))
        p.addCurve(to: pt(220.5, 294.5), control1: pt(195, 294.5), control2: pt(220.5, 294.5))
        p.addCurve(to: pt(290.5, 294.5), control1: pt(220.5, 294.5), control2: pt(245.5, 294.5))
        p.addCurve(to: pt(391, 378.5), control1: pt(335.5, 294.5), control2: pt(359, 378.5))
        p.addCurve(to: pt(436.5, 317.5), control1: pt(423, 378.5), control2: pt(436.5, 363.9))
        p.addCurve(to: pt(385.5, 137.5), control1: pt(436.5, 271.1), control2: pt(397, 165.5))
        p.addCurve(to: pt(312.5, 92), control1: pt(374, 109.5), control2: pt(345, 92))
        p.addCurve(to: pt(220.5, 92), control1: pt(286.5, 92), control2: pt(240, 92))
        p.closeSubpath()
        return p
    }
}

struct StickGimbal: View {
    let label: String
    let stick: CGPoint
    let isPressed: Bool

    private var isDeflected: Bool {
        hypot(stick.x, stick.y) > 0.08
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .strokeBorder(isPressed || isDeflected ? accent : Color(nsColor: .separatorColor), lineWidth: 2)
                    .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    .frame(width: 48, height: 48)

                Circle()
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                    .frame(width: 4, height: 4)

                Circle()
                    .fill(isPressed || isDeflected ? accent : Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(stick.x) * 14, y: CGFloat(stick.y) * 14)
            }
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

struct TriggerBar: View {
    let label: String
    let value: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 38, height: 26)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(nsColor: .separatorColor), lineWidth: 1.5))
            RoundedRectangle(cornerRadius: 4)
                .fill(accent)
                .frame(width: 35, height: max(2, CGFloat(value) * 23))
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(value > 0.4 ? .white : .secondary)
                .padding(.bottom, 4)
        }
    }
}

struct ControllerSheet: View {
    @ObservedObject var launcher: Launcher
    @StateObject private var c = ControllerManager()
    @Environment(\.dismiss) private var dismiss

    private let s: CGFloat = 390.0 / 441.0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Controller").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if !c.devices.isEmpty {
                // Player Assignment Dropdowns with Ping Buttons
                VStack(spacing: 8) {
                    ForEach(0..<max(1, c.devices.count), id: \.self) { playerIdx in
                        HStack(spacing: 12) {
                            Text("Player \(playerIdx + 1)")
                                .font(.headline)
                                .frame(width: 68, alignment: .leading)

                            Picker("", selection: bindingFor(playerIdx)) {
                                ForEach(c.devices.indices, id: \.self) { devIdx in
                                    Text(c.devices[devIdx].name).tag(devIdx)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Ping button with haptic buzz and visual ring pulse
                            Button {
                                c.ping(playerIdx: playerIdx)
                            } label: {
                                Label(c.pingingIndex == playerIdx ? "Buzzing…" : "Ping",
                                      systemImage: "dot.radiowaves.left.and.right")
                            }
                            .controlSize(.regular)
                            .disabled(c.pingingIndex != nil)
                            .help("Vibrate this controller to identify which physical gamepad is assigned to Player \(playerIdx + 1)")

                            // Radio selection to focus diagram
                            Button {
                                c.selectedPlayerIndex = playerIdx
                            } label: {
                                Image(systemName: c.selectedPlayerIndex == playerIdx ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(c.selectedPlayerIndex == playerIdx ? accent : .secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Select this player to test inputs and calibrate below")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(c.selectedPlayerIndex == playerIdx
                                      ? accent.opacity(0.12)
                                      : Color(nsColor: .controlBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(c.pingingIndex == playerIdx ? accent : Color.clear, lineWidth: 2)
                                )
                        )
                    }
                }

                // Selected Controller Diagnostic Card
                if let dev = c.currentDevice {
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.title3)
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(dev.name) (Player \(c.selectedPlayerIndex + 1))").font(.headline)
                            Text(String(format: "VID: 0x%04X · PID: 0x%04X · GUID: %@", dev.vendorId, dev.productId, dev.guid))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))

                    // 1:1 Vector Gamepad Canvas
                    ZStack {
                        ExactXboxBodyShape()
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                            .overlay(
                                ExactXboxBodyShape()
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.85), lineWidth: 2)
                            )
                            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

                        // 1. Left Trigger & Bumper
                        TriggerBar(label: "LT", value: c.leftTrigger)
                            .position(x: 138.5 * s, y: 26 * s)
                        buttonBadge("LB", active: c.isActionPressed("leftshoulder"), w: 42, h: 18)
                            .position(x: 132.0 * s, y: 64 * s)

                        // 2. Right Trigger & Bumper
                        TriggerBar(label: "RT", value: c.rightTrigger)
                            .position(x: 303.5 * s, y: 26 * s)
                        buttonBadge("RB", active: c.isActionPressed("rightshoulder"), w: 42, h: 18)
                            .position(x: 310.0 * s, y: 64 * s)

                        // 3. Left Thumbstick
                        StickGimbal(label: "LS (L3)", stick: c.leftStick, isPressed: c.isActionPressed("leftstick"))
                            .position(x: 113 * s, y: 160 * s)

                        // 4. D-Pad
                        buttonBadge("▲", active: c.dpadState.up, w: 24, h: 20)
                            .position(x: 166 * s, y: (238 - 24) * s)
                        buttonBadge("◀", active: c.dpadState.left, w: 24, h: 20)
                            .position(x: (166 - 24) * s, y: 238 * s)
                        Circle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.35))
                            .frame(width: 8, height: 8)
                            .position(x: 166 * s, y: 238 * s)
                        buttonBadge("▶", active: c.dpadState.right, w: 24, h: 20)
                            .position(x: (166 + 24) * s, y: 238 * s)
                        buttonBadge("▼", active: c.dpadState.down, w: 24, h: 20)
                            .position(x: 166 * s, y: (238 + 24) * s)

                        // 5. Center Console: Guide emblem + Back/Start
                        let guideActive = c.isActionPressed("guide") || c.pressedButtons.contains(12)
                        ZStack {
                            Circle()
                                .fill(guideActive ? accent : Color(nsColor: .tertiaryLabelColor).opacity(0.25))
                                .frame(width: 32, height: 32)
                            Image(systemName: "circle.circle")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(guideActive ? .white : .primary)
                        }
                        .help("Guide button. In System Settings > Game Controllers, set Home Button to None so macOS passes it to games.")
                        .position(x: 220.5 * s, y: 130 * s)

                        VStack(spacing: 2) {
                            buttonBadge("◀", active: c.isActionPressed("back"), w: 26, h: 18)
                            Text("Back").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        .position(x: 185 * s, y: 162 * s)

                        VStack(spacing: 2) {
                            buttonBadge("▶", active: c.isActionPressed("start"), w: 26, h: 18)
                            Text("Start").font(.system(size: 8)).foregroundStyle(.secondary)
                        }
                        .position(x: 259 * s, y: 162 * s)

                        // 6. Face Buttons ABXY
                        buttonBadge("Y", active: c.isActionPressed("y"), w: 24, h: 22)
                            .position(x: 329 * s, y: (160 - 26) * s)
                        buttonBadge("X", active: c.isActionPressed("x"), w: 24, h: 22)
                            .position(x: (329 - 26) * s, y: 160 * s)
                        buttonBadge("B", active: c.isActionPressed("b"), w: 24, h: 22)
                            .position(x: (329 + 26) * s, y: 160 * s)
                        buttonBadge("A", active: c.isActionPressed("a"), w: 24, h: 22)
                            .position(x: 329 * s, y: (160 + 26) * s)

                        // 7. Right Thumbstick
                        StickGimbal(label: "RS (R3)", stick: c.rightStick, isPressed: c.isActionPressed("rightstick"))
                            .position(x: 278 * s, y: 238 * s)
                    }
                    .frame(width: 390, height: 356)
                    .frame(maxWidth: .infinity, alignment: .center)

                    // Calibration Area with Skip Option
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Controller Mapping").font(.subheadline.bold())
                                Text(c.calibrating ? c.currentStep.prompt : "Controls feel swapped or inverted? Run calibration for Player \(c.selectedPlayerIndex + 1).")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if c.calibrating {
                                HStack(spacing: 8) {
                                    Button("Skip") { c.skipStep() }
                                        .controlSize(.regular)
                                        .help("Skip this input if your controller does not have this button")
                                    Button("Cancel") { c.calibrating = false }
                                        .controlSize(.regular)
                                }
                            } else {
                                Button("Remap Player \(c.selectedPlayerIndex + 1)") { c.startCalibration() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(accent)
                            }
                        }

                        if let msg = c.statusMessage {
                            Text(msg)
                                .font(.caption.bold())
                                .foregroundStyle(accent)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }

            } else {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("No Game Controller Detected")
                        .font(.headline)
                    Text("Turn on your controller and connect it via Bluetooth in macOS System Settings.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Open Bluetooth Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.regular)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            }
        }
        .padding(18)
        .frame(width: 500)
    }

    private func bindingFor(_ playerIdx: Int) -> Binding<Int> {
        Binding<Int>(
            get: {
                if c.playerAssignments.indices.contains(playerIdx) {
                    return c.playerAssignments[playerIdx]
                }
                return 0
            },
            set: { newDevIdx in
                if c.playerAssignments.indices.contains(playerIdx) {
                    c.playerAssignments[playerIdx] = newDevIdx
                }
            }
        )
    }

    private func buttonBadge(_ text: String, active: Bool, w: CGFloat = 26, h: CGFloat = 22) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .frame(width: w, height: h)
            .background(RoundedRectangle(cornerRadius: 5).fill(active ? accent : Color(nsColor: .tertiaryLabelColor).opacity(0.2)))
            .foregroundStyle(active ? .white : .primary)
    }
}
