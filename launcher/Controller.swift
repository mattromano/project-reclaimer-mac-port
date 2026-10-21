// Controller: Test and calibrate game controllers directly before Play.
// Discovers IOHID devices, runs live input tests, tests haptic rumble, and manages gamecontrollerdb.txt.
import AppKit
import SwiftUI
import IOKit.hid
import GameController

struct AxisID: Hashable, Comparable {
    let page: Int
    let usage: Int

    static func < (lhs: AxisID, rhs: AxisID) -> Bool {
        if lhs.page != rhs.page { return lhs.page < rhs.page }
        return lhs.usage < rhs.usage
    }
}

struct ControllerDevice: Identifiable, Equatable {
    let id: String
    let device: IOHIDDevice
    let name: String
    let vendorId: Int
    let productId: Int
    let versionNumber: Int
    let guid: String
    let axes: [AxisID]  // the pad's axes in SDL's order (read once: element lookups are slow)

    var isNintendo: Bool { vendorId == 0x057E }
    var isXbox: Bool { vendorId == 0x045E }
    var isSony: Bool { vendorId == 0x054C }
    // ponytail: knownLayout covers first-party pads (Microsoft, Sony, Nintendo) handled by SDL's HIDAPI
    var canRemap: Bool { knownLayout(vendor: vendorId) == nil }

    static func == (lhs: ControllerDevice, rhs: ControllerDevice) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
final class ControllerManager: ObservableObject {
    @Published var devices: [ControllerDevice] = []
    @Published var playerAssignments: [Int] = [0, 1, 2, 3]
    @Published var selectedPlayerIndex: Int = 0 {
        didSet { selectionChanged() }
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
    @Published var hasActiveMapping: Bool = false

    var displayLeftTrigger: Double {
        if let binding = activeMapping["lefttrigger"] {
            let axes = currentDevice?.axes ?? []
            if let idx = Int(binding.dropFirst()), axes.indices.contains(idx) {
                let axis = axes[idx]
                if axis.page == 2 && axis.usage == 0xC5 { return leftTrigger }
                if axis.page == 2 && axis.usage == 0xC4 { return rightTrigger }
                if axis.page == 1 && axis.usage == 0x32 { return leftTrigger }
                if axis.page == 1 && axis.usage == 0x35 { return rightTrigger }
            }
        }
        return hasActiveMapping ? leftTrigger : 0.0
    }
    var displayRightTrigger: Double {
        if let binding = activeMapping["righttrigger"] {
            let axes = currentDevice?.axes ?? []
            if let idx = Int(binding.dropFirst()), axes.indices.contains(idx) {
                let axis = axes[idx]
                if axis.page == 2 && axis.usage == 0xC4 { return rightTrigger }
                if axis.page == 2 && axis.usage == 0xC5 { return leftTrigger }
                if axis.page == 1 && axis.usage == 0x35 { return rightTrigger }
                if axis.page == 1 && axis.usage == 0x32 { return leftTrigger }
            }
        }
        return hasActiveMapping ? rightTrigger : 0.0
    }

    var displayLeftStick: CGPoint {
        var pt = leftStick
        if activeMapping["lefty"]?.contains("~") == true {
            pt.y = -pt.y
        }
        return pt
    }

    var displayRightStick: CGPoint {
        var pt = rightStick
        if activeMapping["righty"]?.contains("~") == true {
            pt.y = -pt.y
        }
        return pt
    }

    // Calibration wizard state
    enum CalibStep: Int, CaseIterable {
        case a, b, x, y, lb, rb, lt, rt, back, start, l3, lup, r3, rup, done

        var prompt: String {
            prompt(for: nil)
        }

        func prompt(for dev: ControllerDevice?) -> String {
            switch self {
            case .a: return dev?.isNintendo == true ? "Press A (Right Button)" : "Press A (Bottom Button)"
            case .b: return dev?.isNintendo == true ? "Press B (Bottom Button)" : "Press B (Right Button)"
            case .x: return dev?.isNintendo == true ? "Press X (Top Button)" : "Press X (Left Button)"
            case .y: return dev?.isNintendo == true ? "Press Y (Left Button)" : "Press Y (Top Button)"
            case .lb: return dev?.isNintendo == true ? "Press L (Left Bumper)" : "Press LB (Left Bumper)"
            case .rb: return dev?.isNintendo == true ? "Press R (Right Bumper)" : "Press RB (Right Bumper)"
            case .lt: return dev?.isNintendo == true ? "Squeeze & Release ZL (Left Trigger)" : "Squeeze & Release LT (Left Trigger)"
            case .rt: return dev?.isNintendo == true ? "Squeeze & Release ZR (Right Trigger)" : "Squeeze & Release RT (Right Trigger)"
            case .back: return dev?.isNintendo == true ? "Press Minus (-)" : "Press Back / View / Minus"
            case .start: return dev?.isNintendo == true ? "Press Plus (+)" : "Press Start / Menu / Plus"
            case .l3: return "Click Left Stick (L3)"
            case .lup: return "Push Left Stick Up"
            case .r3: return "Click Right Stick (R3)"
            case .rup: return "Push Right Stick Up"
            case .done: return "Calibration Complete! Saved."
            }
        }
    }
    @Published var calibrating = false
    @Published var currentStep: CalibStep = .a
    @Published var statusMessage: String?

    private var capturedMapping: [String: String] = [:]
    private var hidManager: IOHIDManager?
    private var gcObservers: [NSObjectProtocol] = []
    private var gcPad: GCController?  // the selected pad, when it's read through the GameController framework
    private var canAdvanceStep = true
    private var awaitingButtonRelease = false
    private var triggerArmed = false
    private var triggerAxis = AxisID(page: 0, usage: 0)
    private var stickArmed = false
    private var stickPeak: Double = 0.0
    private var stickAxis = AxisID(page: 0, usage: 0)
    private var stepArmedTime = Date()
    private var calibratingDevice: IOHIDDevice?  // the pad a remap is for (stops if the selection changes)
    private var pendingTriggerButton: Int?  // a button pressed on the LT/RT step: the trigger, unless an axis moved

    init() {
        start()
    }

    func start() {
        guard hidManager == nil else { return }
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        hidManager = mgr

        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Joystick],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey as String: kHIDUsage_GD_GamePad],
            [kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey as String: kHIDUsage_GD_MultiAxisController],
            [kIOHIDDeviceUsagePageKey as String: 0xFF01, kIOHIDVendorIDKey as String: 0x057E]  // Switch Pro
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)

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
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            gcObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attachGameController() }
            })
        }
        scanDevices()
    }

    /// The callbacks hold an unretained pointer to self: unregister them before self can go away.
    func stop() {
        gcObservers.forEach(NotificationCenter.default.removeObserver)
        gcObservers = []
        gcPad?.extendedGamepad?.valueChangedHandler = nil
        gcPad = nil
        if let mgr = hidManager {
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
            IOHIDManagerRegisterInputValueCallback(mgr, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))  // (closes the devices it opened)
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
            let rawName = IOHIDDeviceGetProperty(dev, "Product" as CFString) as? String

            let virtualCopy = (IOHIDDeviceGetProperty(dev, "HIDVirtualDevice" as CFString) as? Bool) ?? false
            guard !virtualCopy, vid > 0 && pid > 0, vid != 0x05AC, (usage == 5 || usage == 4 || vid == 0x2DC8 || vid == 0x057E) else {
                continue
            }

            let ver = (IOHIDDeviceGetProperty(dev, "VersionNumber" as CFString) as? Int) ?? 0
            var name = sdlMappingName(rawName)
            if vid == 0x057E && name == sdlMappingName(nil) { name = "Nintendo Switch Controller" }
            let guid = sdlWildcardGuid(vendorId: vid, productId: pid)

            let id = "\(vid)-\(pid)-\(idx)"
            found.append(ControllerDevice(id: id, device: dev, name: name,
                                          vendorId: vid, productId: pid,
                                          versionNumber: ver,
                                          guid: guid, axes: axisList(of: dev)))
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

    func selectionChanged() {
        loadActiveMapping()
        resetInputState()
    }

    private func resetInputState() {
        pressedButtons.removeAll()
        dpadState = (false, false, false, false)
        leftStick = .zero
        rightStick = .zero
        leftTrigger = 0.0
        rightTrigger = 0.0
    }

    /// PlayStation pads (see readsThroughGameController): show the selected one's input from the GameController
    /// framework. Pads of one kind are paired with macOS's list of them in order.
    private func attachGameController() {
        gcPad?.extendedGamepad?.valueChangedHandler = nil
        gcPad = nil
        guard let current = currentDevice, readsThroughGameController(vendor: current.vendorId) else { return }
        let same = devices.filter { $0.vendorId == current.vendorId }
        let pads = GCController.controllers().filter { pad in
            pad.extendedGamepad != nil
                && ["DualSense", "DualShock"].contains { (pad.productCategory + " " + (pad.vendorName ?? "")).contains($0) }
        }
        guard let n = same.firstIndex(of: current), pads.indices.contains(n) else { return }
        gcPad = pads[n]
        gcPad?.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.show(pad) }
        }
    }

    private func show(_ pad: GCExtendedGamepad) {
        let buttons: [(GCButton, GCControllerButtonInput?)] = [
            (.a, pad.buttonA), (.b, pad.buttonB), (.x, pad.buttonX), (.y, pad.buttonY),
            (.leftShoulder, pad.leftShoulder), (.rightShoulder, pad.rightShoulder), (.back, pad.buttonOptions),
            (.start, pad.buttonMenu), (.guide, pad.buttonHome), (.leftStick, pad.leftThumbstickButton),
            (.rightStick, pad.rightThumbstickButton)]
        pressedButtons = Set(buttons.compactMap { $0.1?.isPressed == true ? $0.0.rawValue : nil })
        dpadState = (pad.dpad.up.isPressed, pad.dpad.down.isPressed, pad.dpad.left.isPressed, pad.dpad.right.isPressed)
        // (the framework's y points up; the window's, like HID's, down)
        leftStick = CGPoint(x: Double(pad.leftThumbstick.xAxis.value), y: -Double(pad.leftThumbstick.yAxis.value))
        rightStick = CGPoint(x: Double(pad.rightThumbstick.xAxis.value), y: -Double(pad.rightThumbstick.yAxis.value))
        leftTrigger = Double(pad.leftTrigger.value)
        rightTrigger = Double(pad.rightTrigger.value)
    }

    private func loadActiveMapping() {
        defer { attachGameController() }
        if calibrating && currentDevice?.device != calibratingDevice {
            calibrating = false
            statusMessage = "Remap stopped: the selected controller changed."
        }
        guard let current = currentDevice, !current.guid.isEmpty else {
            hasActiveMapping = false
            activeMapping = [:]
            return
        }
        let baseDir = home
        let bundledDb = baseDir.appendingPathComponent("game/gamecontrollerdb.txt")
        let userMappings = baseDir.appendingPathComponent("controller-mappings.txt")

        hasActiveMapping = false

        if let layout = knownLayout(vendor: current.vendorId) {
            hasActiveMapping = true  // (the game's SDL maps these itself)
            activeMapping = layout
        } else {
            // Raw generic HID fallback in Wine (what Wine sees when NO mapping exists)
            activeMapping = [
                "a": "b0", "b": "b1", "x": "b2", "y": "b3",
                "leftshoulder": "b4", "rightshoulder": "b5",
                "back": "b8", "start": "b9", "guide": "b10",
                "leftstick": "b11", "rightstick": "b12"
            ]
        }

        for path in [bundledDb, userMappings] {
            if let content = try? String(contentsOf: path, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines).reversed() {
                    if line.starts(with: current.guid) {
                        // (a line replaces earlier ones for this pad, as in SDL)
                        if knownLayout(vendor: current.vendorId) == nil { activeMapping = [:] }
                        let parts = line.components(separatedBy: ",")
                        for part in parts.dropFirst(2) {
                            let kv = part.components(separatedBy: ":")
                            if kv.count == 2 && kv[0] != "platform" {
                                activeMapping[kv[0]] = kv[1]
                            }
                        }
                        hasActiveMapping = true
                        break
                    }
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
        guard let current = currentDevice, !readsThroughGameController(vendor: current.vendorId) else { return }
        let elem = IOHIDValueGetElement(value)
        let senderDev = IOHIDElementGetDevice(elem)

        // Only process events from the currently selected player's controller
        guard senderDev == current.device else { return }

        let page = IOHIDElementGetUsagePage(elem)
        let usage = IOHIDElementGetUsage(elem)
        let intVal = IOHIDValueGetIntegerValue(value)
        let lo = IOHIDElementGetLogicalMin(elem), hi = IOHIDElementGetLogicalMax(elem)  // (each control's own range)

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

                // Switch buttons: map physical buttons to raw button indices (0=A, 1=B, 2=X, 3=Y)
                var newPressed = Set<Int>()
                if (b2 & 0x08) != 0 { newPressed.insert(0) } // Physical A (East)
                if (b2 & 0x04) != 0 { newPressed.insert(1) } // Physical B (South)
                if (b2 & 0x02) != 0 { newPressed.insert(2) } // Physical X (North)
                if (b2 & 0x01) != 0 { newPressed.insert(3) } // Physical Y (West)
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

                if calibrating {
                    if currentStep == .lt || currentStep == .rt {
                        handleTriggerCalibration(page: 2, usage: 0xC5, value: leftTrigger)
                        handleTriggerCalibration(page: 2, usage: 0xC4, value: rightTrigger)
                    } else if currentStep == .lup {
                        handleStickCalibration(page: 1, usage: 0x31, pos: leftStick.y)
                    } else if currentStep == .rup {
                        handleStickCalibration(page: 1, usage: 0x35, pos: rightStick.y)
                    } else {
                        if canAdvanceStep && !newPressed.isEmpty {
                            if let firstBtn = newPressed.first {
                                recordCalibrationButton(firstBtn)
                            }
                        } else if awaitingButtonRelease && newPressed.isEmpty {
                            awaitingButtonRelease = false
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 50_000_000)
                                self.canAdvanceStep = true
                            }
                        }
                    }
                }
                return
            }

            // Standard HID Gamepad Parsing (8BitDo, Xbox, etc.)
            if page == 9 { // Button
                let btn = Int(usage - 1)
                if intVal == 1 {
                    pressedButtons.insert(btn)
                    if calibrating && (currentStep == .lt || currentStep == .rt) {
                        if pendingTriggerButton == nil { pendingTriggerButton = btn }
                    } else if calibrating && currentStep != .lup && currentStep != .rup {
                        if canAdvanceStep {
                            recordCalibrationButton(btn)
                        }
                    }
                } else {
                    pressedButtons.remove(btn)
                    if calibrating && (currentStep == .lt || currentStep == .rt) && pendingTriggerButton == btn {
                        pendingTriggerButton = nil
                        if !triggerArmed { recordTrigger("b\(btn)") }  // (no axis moved: a digital trigger)
                    } else if calibrating && awaitingButtonRelease && pressedButtons.isEmpty {
                        awaitingButtonRelease = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            self.canAdvanceStep = true
                        }
                    }
                }
            } else if page == 1 { // Generic Desktop (Sticks / D-Pad / 360 Triggers)
                let is360Style = currentDevice?.axes.contains(AxisID(page: 1, usage: 0x34)) == true
                if usage == 0x39 { // Hat switch (D-Pad)
                    let hat = hatDirections(intVal, min: lo, max: hi)
                    dpadState = (hat.up, hat.down, hat.left, hat.right)
                } else if usage == 0x30 { // X axis
                    leftStick.x = stickPosition(intVal, min: lo, max: hi)
                } else if usage == 0x31 { // Y axis
                    leftStick.y = stickPosition(intVal, min: lo, max: hi)
                    handleStickCalibration(page: 1, usage: Int(usage), pos: leftStick.y)
                } else if usage == 0x32 { // Z axis
                    if is360Style {
                        leftTrigger = axisFraction(intVal, min: lo, max: hi)
                        handleTriggerCalibration(page: 1, usage: 0x32, value: leftTrigger)
                    } else {
                        rightStick.x = stickPosition(intVal, min: lo, max: hi)
                    }
                } else if usage == 0x33 { // Rx axis (Right Stick X on 360 pads)
                    if is360Style {
                        rightStick.x = stickPosition(intVal, min: lo, max: hi)
                    }
                } else if usage == 0x34 { // Ry axis (wired Xbox 360 Right Stick Y)
                    rightStick.y = stickPosition(intVal, min: lo, max: hi)
                    handleStickCalibration(page: 1, usage: Int(usage), pos: rightStick.y)
                } else if usage == 0x35 { // Rz axis
                    if is360Style {
                        rightTrigger = axisFraction(intVal, min: lo, max: hi)
                        handleTriggerCalibration(page: 1, usage: 0x35, value: rightTrigger)
                    } else {
                        rightStick.y = stickPosition(intVal, min: lo, max: hi)
                        handleStickCalibration(page: 1, usage: Int(usage), pos: rightStick.y)
                    }
                }
            } else if page == 2 { // Simulation controls (Triggers on 8BitDo / standard HID)
                if usage == 0xC5 { // Left Trigger (Brake)
                    leftTrigger = axisFraction(intVal, min: lo, max: hi)
                    handleTriggerCalibration(page: 2, usage: 0xC5, value: leftTrigger)
                } else if usage == 0xC4 { // Right Trigger (Accelerator)
                    rightTrigger = axisFraction(intVal, min: lo, max: hi)
                    handleTriggerCalibration(page: 2, usage: 0xC4, value: rightTrigger)
                }
            }
        }
    }

    /// The pad's axes in the order SDL's IOKit driver numbers them (sorted by usage; Generic Desktop X…Wheel, then
    /// Simulation rudder, throttle, accelerator and brake).
    private func axisList(of device: IOHIDDevice) -> [AxisID] {
        let fallback = [AxisID(page: 1, usage: 0x30), AxisID(page: 1, usage: 0x31),
                        AxisID(page: 1, usage: 0x32), AxisID(page: 1, usage: 0x35)]
        guard let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] else { return fallback }
        var axes = Set<AxisID>()
        for elem in elements {
            let type = IOHIDElementGetType(elem)
            guard type == kIOHIDElementTypeInput_Axis || type == kIOHIDElementTypeInput_Misc else { continue }
            let page = Int(IOHIDElementGetUsagePage(elem))
            let usage = Int(IOHIDElementGetUsage(elem))
            if (page == 1 && (0x30...0x38).contains(usage)) || (page == 2 && [0xBA, 0xBB, 0xC4, 0xC5].contains(usage)) {
                axes.insert(AxisID(page: page, usage: usage))
            }
        }
        return axes.isEmpty ? fallback : axes.sorted()
    }

    private func handleTriggerCalibration(page: Int, usage: Int, value: Double) {
        guard calibrating, currentStep == .lt || currentStep == .rt, let dev = currentDevice else { return }
        let currentAxis = AxisID(page: page, usage: usage)
        if value > 0.5 {
            triggerArmed = true
            triggerAxis = currentAxis
        } else if value < 0.2 && triggerArmed {
            triggerArmed = false
            let target = triggerAxis.page > 0 ? triggerAxis : currentAxis
            triggerAxis = AxisID(page: 0, usage: 0)
            if let idx = dev.axes.firstIndex(of: target) { recordTrigger("a\(idx)") }  // (else: Skip)
        }
    }

    /// LT or RT captured: an axis ("aN") or, for a digital trigger, a button ("bN").
    private func recordTrigger(_ binding: String) {
        pendingTriggerButton = nil
        triggerArmed = false
        if currentStep == .lt {
            capturedMapping["lefttrigger"] = binding
            currentStep = .rt
            stepArmedTime = Date()
        } else if currentStep == .rt {
            capturedMapping["righttrigger"] = binding
            currentStep = .back
            canAdvanceStep = false
            awaitingButtonRelease = false
            stepArmedTime = Date()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.canAdvanceStep = true
            }
        }
    }

    private func handleStickCalibration(page: Int, usage: Int, pos: Double) {
        guard calibrating, let dev = currentDevice else { return }
        let currentAxis = AxisID(page: page, usage: usage)
        if currentStep == .lup {
            if abs(pos) > 0.6 {
                stickArmed = true
                if abs(pos) > abs(stickPeak) {
                    stickPeak = pos
                    stickAxis = currentAxis
                }
            } else if abs(pos) < 0.25 && stickArmed {
                stickArmed = false
                let axes = dev.axes
                let yAxis = stickAxis.page > 0 ? stickAxis : currentAxis
                let yIndex = axes.firstIndex(of: yAxis) ?? 1
                let xIndex = axes.firstIndex(of: AxisID(page: 1, usage: 0x30)) ?? 0
                capturedMapping["leftx"] = "a\(xIndex)"
                capturedMapping["lefty"] = "a\(yIndex)\(stickPeak > 0 ? "~" : "")"
                stickPeak = 0.0
                stickAxis = AxisID(page: 0, usage: 0)
                currentStep = .r3
                canAdvanceStep = false
                awaitingButtonRelease = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.canAdvanceStep = true
                }
            }
        } else if currentStep == .rup {
            if abs(pos) > 0.6 {
                stickArmed = true
                if abs(pos) > abs(stickPeak) {
                    stickPeak = pos
                    stickAxis = currentAxis
                }
            } else if abs(pos) < 0.25 && stickArmed {
                stickArmed = false
                let axes = dev.axes
                let yAxis = stickAxis.page > 0 ? stickAxis : currentAxis
                let yIndex = axes.firstIndex(of: yAxis) ?? (axes.count > 4 ? 4 : 3)
                let xUsage = (yAxis.usage == 0x34) ? 0x33 : 0x32
                let xIndex = axes.firstIndex(of: AxisID(page: 1, usage: xUsage)) ?? (yIndex - 1)
                capturedMapping["rightx"] = "a\(xIndex)"
                capturedMapping["righty"] = "a\(yIndex)\(stickPeak > 0 ? "~" : "")"
                stickPeak = 0.0
                stickAxis = AxisID(page: 0, usage: 0)
                finishCalibration()
            }
        }
    }

    private func finishCalibration() {
        if capturedMapping["dpup"] == nil { capturedMapping["dpup"] = activeMapping["dpup"] ?? "h0.1" }
        if capturedMapping["dpdown"] == nil { capturedMapping["dpdown"] = activeMapping["dpdown"] ?? "h0.4" }
        if capturedMapping["dpleft"] == nil { capturedMapping["dpleft"] = activeMapping["dpleft"] ?? "h0.8" }
        if capturedMapping["dpright"] == nil { capturedMapping["dpright"] = activeMapping["dpright"] ?? "h0.2" }
        if capturedMapping["leftx"] == nil { capturedMapping["leftx"] = activeMapping["leftx"] ?? "a0" }
        if capturedMapping["lefty"] == nil { capturedMapping["lefty"] = activeMapping["lefty"] ?? "a1" }
        if capturedMapping["rightx"] == nil { capturedMapping["rightx"] = activeMapping["rightx"] ?? "a2" }
        if capturedMapping["righty"] == nil { capturedMapping["righty"] = activeMapping["righty"] ?? "a3" }
        saveMapping()
        currentStep = .done
        calibrating = false
        statusMessage = "Mapping saved for \(currentDevice?.name ?? "controller")!"
    }

    func ping(playerIdx: Int) {
        let devIdx = playerAssignments.indices.contains(playerIdx) ? playerAssignments[playerIdx] : playerIdx
        guard devices.indices.contains(devIdx) else { return }
        let dev = devices[devIdx]
        pingingIndex = playerIdx

        Task.detached {
            if dev.vendorId == 0x2DC8 {
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
        calibratingDevice = currentDevice?.device
        pendingTriggerButton = nil
        currentStep = .a
        capturedMapping = hasActiveMapping ? activeMapping : [:]  // (what was mapped before, never the raw view's guesses)
        canAdvanceStep = true
        awaitingButtonRelease = false
        triggerArmed = false
        triggerAxis = AxisID(page: 0, usage: 0)
        stickArmed = false
        stickPeak = 0.0
        stickAxis = AxisID(page: 0, usage: 0)
        stepArmedTime = Date()
        statusMessage = nil
    }

    func skipStep() {
        guard calibrating else { return }
        canAdvanceStep = true
        pendingTriggerButton = nil
        awaitingButtonRelease = false
        triggerArmed = false
        triggerAxis = AxisID(page: 0, usage: 0)
        stickArmed = false
        stickPeak = 0.0
        stickAxis = AxisID(page: 0, usage: 0)
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
        case .l3: currentStep = .lup
        case .lup: currentStep = .r3
        case .r3: currentStep = .rup
        case .rup: finishCalibration()
        default: break
        }
    }

    private func recordCalibrationButton(_ button: Int) {
        guard calibrating, canAdvanceStep else { return }
        canAdvanceStep = false
        awaitingButtonRelease = true
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
        case .l3:
            capturedMapping["leftstick"] = "b\(button)"
            currentStep = .lup
            canAdvanceStep = false
            awaitingButtonRelease = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.canAdvanceStep = true
            }
        case .lup: break
        case .r3:
            capturedMapping["rightstick"] = "b\(button)"
            currentStep = .rup
            canAdvanceStep = false
            awaitingButtonRelease = false
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.canAdvanceStep = true
            }
        case .rup: break
        default: break
        }
    }

    private func saveMapping() {
        guard let current = currentDevice, !current.guid.isEmpty else { return }
        activeMapping = capturedMapping
        let mapEntries = capturedMapping
            .filter { $0.key != "platform" }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        let safeName = sdlMappingName(current.name)
        let wildcardGuid = sdlWildcardGuid(vendorId: current.vendorId, productId: current.productId)
        var newLines = ["\(wildcardGuid),\(safeName),\(mapEntries),platform:Mac OS X,\n"]
        var guidsToRemove = [wildcardGuid]
        if current.versionNumber != 0 {
            let verGuid = sdlGuid(vendorId: current.vendorId, productId: current.productId, version: current.versionNumber)
            if verGuid != wildcardGuid {
                newLines.append("\(verGuid),\(safeName),\(mapEntries),platform:Mac OS X,\n")
                guidsToRemove.append(verGuid)
            }
        }
        let addedText = newLines.joined()

        // Calibrations live in ~/Games/ProjectReclaimer/controller-mappings.txt so installer updates never touch them
        let baseDir = home
        let userMappingsPath = baseDir.appendingPathComponent("controller-mappings.txt")

        if let existing = try? String(contentsOf: userMappingsPath, encoding: .utf8) {
            let filtered = existing.components(separatedBy: .newlines).filter { line in
                !guidsToRemove.contains { line.starts(with: $0) } && !line.isEmpty
            }.joined(separator: "\n")
            try? (filtered.isEmpty ? addedText : filtered + "\n" + addedText).write(to: userMappingsPath, atomically: true, encoding: .utf8)
        } else {
            try? addedText.write(to: userMappingsPath, atomically: true, encoding: .utf8)
        }

        // Refresh controller-mappings-active.txt so active mappings exist immediately for Wine
        let activePath = baseDir.appendingPathComponent("controller-mappings-active.txt")
        let bundledPath = baseDir.appendingPathComponent("game/gamecontrollerdb.txt")
        var merged = (try? String(contentsOf: bundledPath, encoding: .utf8)) ?? ""
        if let userText = try? String(contentsOf: userMappingsPath, encoding: .utf8) {
            merged += (merged.isEmpty ? "" : "\n") + userText
        }
        if !merged.isEmpty {
            try? merged.write(to: activePath, atomically: true, encoding: .utf8)
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
    var highlighted: Bool = false
    var showUpArrow: Bool = false

    private var isDeflected: Bool {
        hypot(stick.x, stick.y) > 0.08
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .strokeBorder(isPressed || isDeflected || highlighted ? accent : Color(nsColor: .separatorColor),
                                  lineWidth: highlighted ? 2.5 : 2)
                    .background(Circle().fill(highlighted ? accent.opacity(0.15) : Color(nsColor: .controlBackgroundColor)))
                    .frame(width: 48, height: 48)

                Circle()
                    .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.3))
                    .frame(width: 4, height: 4)

                if showUpArrow {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                        .offset(y: -14)
                }

                Circle()
                    .fill(isPressed || isDeflected ? accent : Color.white)
                    .frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(stick.x) * 14, y: CGFloat(stick.y) * 14)
            }
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(highlighted ? accent : .secondary)
        }
    }
}

struct TriggerBar: View {
    let label: String
    let value: Double
    var highlighted: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
                .frame(width: 38, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(highlighted ? accent : Color(nsColor: .separatorColor), lineWidth: highlighted ? 2 : 1.5)
                )
            RoundedRectangle(cornerRadius: 4)
                .fill(accent)
                .frame(width: 35, height: max(2, CGFloat(value) * 23))
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(value > 0.4 ? .white : (highlighted ? accent : .secondary))
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
                            HStack(spacing: 8) {
                                Text(String(format: "VID: 0x%04X · PID: 0x%04X", dev.vendorId, dev.productId))
                                    .font(.caption).foregroundStyle(.secondary)
                                if c.hasActiveMapping {
                                    Label("Mapped in Wine", systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.medium)).foregroundStyle(accent)
                                } else {
                                    Label("Unmapped (raw Wine inputs)", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2.weight(.medium)).foregroundStyle(.orange)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))

                    let isNintendo = dev.isNintendo

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
                        TriggerBar(label: isNintendo ? "ZL" : "LT",
                                   value: c.displayLeftTrigger,
                                   highlighted: c.calibrating && c.currentStep == .lt)
                            .position(x: 138.5 * s, y: 26 * s)
                        buttonBadge(isNintendo ? "L" : "LB",
                                    active: c.isActionPressed("leftshoulder"),
                                    w: 42, h: 18,
                                    highlighted: c.calibrating && c.currentStep == .lb)
                            .position(x: 132.0 * s, y: 64 * s)

                        // 2. Right Trigger & Bumper
                        TriggerBar(label: isNintendo ? "ZR" : "RT",
                                   value: c.displayRightTrigger,
                                   highlighted: c.calibrating && c.currentStep == .rt)
                            .position(x: 303.5 * s, y: 26 * s)
                        buttonBadge(isNintendo ? "R" : "RB",
                                    active: c.isActionPressed("rightshoulder"),
                                    w: 42, h: 18,
                                    highlighted: c.calibrating && c.currentStep == .rb)
                            .position(x: 310.0 * s, y: 64 * s)

                        // 3. Left Thumbstick
                        StickGimbal(label: "LS (L3)", stick: c.displayLeftStick,
                                    isPressed: c.isActionPressed("leftstick"),
                                    highlighted: c.calibrating && (c.currentStep == .l3 || c.currentStep == .lup),
                                    showUpArrow: c.calibrating && c.currentStep == .lup)
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
                            buttonBadge(isNintendo ? "-" : "◀",
                                        active: c.isActionPressed("back"),
                                        w: 26, h: 18,
                                        highlighted: c.calibrating && c.currentStep == .back)
                            Text(isNintendo ? "Minus" : "Back")
                                .font(.system(size: 8))
                                .foregroundStyle(c.calibrating && c.currentStep == .back ? accent : .secondary)
                        }
                        .position(x: 185 * s, y: 162 * s)

                        VStack(spacing: 2) {
                            buttonBadge(isNintendo ? "+" : "▶",
                                        active: c.isActionPressed("start"),
                                        w: 26, h: 18,
                                        highlighted: c.calibrating && c.currentStep == .start)
                            Text(isNintendo ? "Plus" : "Start")
                                .font(.system(size: 8))
                                .foregroundStyle(c.calibrating && c.currentStep == .start ? accent : .secondary)
                        }
                        .position(x: 259 * s, y: 162 * s)

                        // 6. Face Buttons ABXY
                        buttonBadge(isNintendo ? "X" : "Y",
                                    active: isNintendo ? c.isActionPressed("x") : c.isActionPressed("y"),
                                    w: 24, h: 22,
                                    highlighted: c.calibrating && (isNintendo ? c.currentStep == .x : c.currentStep == .y))
                            .position(x: 329 * s, y: (160 - 26) * s)
                        buttonBadge(isNintendo ? "Y" : "X",
                                    active: isNintendo ? c.isActionPressed("y") : c.isActionPressed("x"),
                                    w: 24, h: 22,
                                    highlighted: c.calibrating && (isNintendo ? c.currentStep == .y : c.currentStep == .x))
                            .position(x: (329 - 26) * s, y: 160 * s)
                        buttonBadge(isNintendo ? "A" : "B",
                                    active: isNintendo ? c.isActionPressed("a") : c.isActionPressed("b"),
                                    w: 24, h: 22,
                                    highlighted: c.calibrating && (isNintendo ? c.currentStep == .a : c.currentStep == .b))
                            .position(x: (329 + 26) * s, y: 160 * s)
                        buttonBadge(isNintendo ? "B" : "A",
                                    active: isNintendo ? c.isActionPressed("b") : c.isActionPressed("a"),
                                    w: 24, h: 22,
                                    highlighted: c.calibrating && (isNintendo ? c.currentStep == .b : c.currentStep == .a))
                            .position(x: 329 * s, y: (160 + 26) * s)

                        // 7. Right Thumbstick
                        StickGimbal(label: "RS (R3)", stick: c.displayRightStick,
                                    isPressed: c.isActionPressed("rightstick"),
                                    highlighted: c.calibrating && (c.currentStep == .r3 || c.currentStep == .rup),
                                    showUpArrow: c.calibrating && c.currentStep == .rup)
                            .position(x: 278 * s, y: 238 * s)
                    }
                    .frame(width: 390, height: 356)
                    .frame(maxWidth: .infinity, alignment: .center)

                    // Calibration Area with Skip Option
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                if c.calibrating {
                                    Text(c.currentStep.prompt(for: dev))
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(accent)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(isNintendo
                                         ? "Press buttons as labeled on your controller. You can switch to Xbox Layout (Bottom = A) at any time."
                                         : "Follow the prompts. Press each button on the selected controller, or click Skip.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if dev.canRemap {
                                    Text("Controller Mapping").font(.subheadline.bold())
                                    Text("Controls feel swapped or inverted? Run calibration for Player \(c.selectedPlayerIndex + 1).")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Controller Mapping").font(.subheadline.bold())
                                    Text("This controller is already supported by the game.")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
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
                            } else if dev.canRemap {
                                Button("Remap Player \(c.selectedPlayerIndex + 1)") { c.startCalibration() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(accent)
                            } else {
                                Text("Supported by game")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
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
        .onDisappear { c.stop() }
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
                    c.selectionChanged()
                }
            }
        )
    }

    private func buttonBadge(_ text: String, active: Bool, w: CGFloat = 26, h: CGFloat = 22, highlighted: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? accent : (highlighted ? accent.opacity(0.3) : Color(nsColor: .tertiaryLabelColor).opacity(0.2)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(highlighted ? accent : Color.clear, lineWidth: highlighted ? 2 : 0)
            )
            .foregroundStyle(active ? .white : (highlighted ? accent : .primary))
    }
}
