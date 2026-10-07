import CoreHaptics
import GameController
import Observation
import QuartzCore

/// What the launcher responds to.
enum PadAction: String, CaseIterable, Sendable {
    case up, down, left, right
    case a, b, x, y
    case leftShoulder, rightShoulder
    case menu
}

/// Game-controller input for the hub's controller mode.
///
/// Polls the active controller once per frame rather than installing value-changed
/// handlers, so it never fights SDL (which also polls) over the same controller, and
/// stops entirely while a game is running so a button press can't reach both.
@MainActor @Observable
final class ControllerInput {
    /// A controller with a full gamepad profile is connected.
    private(set) var isConnected = false
    /// Product name of the active controller, for display.
    private(set) var controllerName: String?
    /// Forced on with `-VNHubControllerMode` (debug) so the launcher can be tested without hardware.
    private(set) var isForced = false

    /// `-VNHubControllerMode NO` (debug) ignores controllers, e.g. the simulator's virtual one.
    private(set) var isSuppressed = false

    var isActive: Bool { isForced || (isConnected && !isSuppressed) }

    /// Receives each press, including repeats while a direction is held.
    var handler: ((PadAction) -> Void)?

    private var controller: GCController?
    private var displayLink: CADisplayLink?
    private var held: Set<PadAction> = []
    private var repeatAt: [PadAction: CFTimeInterval] = [:]
    private var hapticEngine: CHHapticEngine?

    private static let repeatDelay: CFTimeInterval = 0.35
    private static let repeatInterval: CFTimeInterval = 0.11
    private static let stickThreshold: Float = 0.55

    init() {
        #if DEBUG
        isForced = UserDefaults.standard.bool(forKey: "VNHubControllerMode")
        isSuppressed = UserDefaults.standard.object(forKey: "VNHubControllerMode") != nil && !isForced
        // `-VNHubPadInput "3:right;4:a"` replays pad presses (seconds from launch).
        for step in (UserDefaults.standard.string(forKey: "VNHubPadInput") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]), let action = PadAction(rawValue: String(parts[1])) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.fire(action) }
            }
        }
        #endif
        let center = NotificationCenter.default
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        center.addObserver(forName: .GCControllerDidBecomeCurrent, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        GCController.startWirelessControllerDiscovery {}
        refresh()
    }

    private func refresh() {
        let current = GCController.current ?? GCController.controllers().first { $0.extendedGamepad != nil }
        controller = current?.extendedGamepad != nil ? current : nil
        isConnected = controller != nil
        controllerName = controller?.vendorName
        hapticEngine = controller?.haptics?.createEngine(withLocality: .default)
        try? hapticEngine?.start()
        held.removeAll()
        updatePolling()
    }

    /// Polling runs only while the hub is on screen; `RenPyEngine` games read the
    /// controller through SDL instead.
    var isPaused = false {
        didSet { updatePolling() }
    }

    private func updatePolling() {
        let shouldPoll = controller != nil && !isPaused
        if shouldPoll, displayLink == nil {
            let link = CADisplayLink(target: DisplayLinkTarget { [weak self] in self?.poll() }, selector: #selector(DisplayLinkTarget.tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldPoll {
            displayLink?.invalidate()
            displayLink = nil
            held.removeAll()
        }
    }

    /// What the running game was last told about the pad, to send only changes.
    private var gameButtons: [Int: Bool] = [:]
    private var gameAxes: [Int: Int] = [:]

    private func poll() {
        guard let pad = controller?.extendedGamepad else { return }
        if vnhub_renpy_is_running() != 0 {
            forwardToGame(pad)
            return
        }
        let stick = pad.leftThumbstick
        let pressed: [PadAction: Bool] = [
            .up: pad.dpad.up.isPressed || stick.yAxis.value > Self.stickThreshold,
            .down: pad.dpad.down.isPressed || stick.yAxis.value < -Self.stickThreshold,
            .left: pad.dpad.left.isPressed || stick.xAxis.value < -Self.stickThreshold,
            .right: pad.dpad.right.isPressed || stick.xAxis.value > Self.stickThreshold,
            .a: pad.buttonA.isPressed,
            .b: pad.buttonB.isPressed,
            .x: pad.buttonX.isPressed,
            .y: pad.buttonY.isPressed,
            .leftShoulder: pad.leftShoulder.isPressed,
            .rightShoulder: pad.rightShoulder.isPressed,
            .menu: pad.buttonMenu.isPressed,
        ]
        let now = CACurrentMediaTime()
        for (action, isDown) in pressed {
            if isDown, !held.contains(action) {
                held.insert(action)
                repeatAt[action] = now + Self.repeatDelay
                fire(action)
            } else if isDown, [.up, .down, .left, .right].contains(action), let next = repeatAt[action], now >= next {
                repeatAt[action] = now + Self.repeatInterval
                fire(action)
            } else if !isDown, held.contains(action) {
                held.remove(action)
                repeatAt[action] = nil
            }
        }
    }

    /// SDL's iOS controller driver yields no input for some controllers (a Backbone at
    /// least), though GameController sees every press. While a game runs, pass the pad's
    /// state to it as SDL game-controller events (SDL_GameControllerButton/Axis numbers).
    private func forwardToGame(_ pad: GCExtendedGamepad) {
        let buttons: [Int: Bool] = [
            0: pad.buttonA.isPressed, 1: pad.buttonB.isPressed,
            2: pad.buttonX.isPressed, 3: pad.buttonY.isPressed,
            4: pad.buttonOptions?.isPressed ?? false, 6: pad.buttonMenu.isPressed,
            7: pad.leftThumbstickButton?.isPressed ?? false, 8: pad.rightThumbstickButton?.isPressed ?? false,
            9: pad.leftShoulder.isPressed, 10: pad.rightShoulder.isPressed,
            11: pad.dpad.up.isPressed, 12: pad.dpad.down.isPressed,
            13: pad.dpad.left.isPressed, 14: pad.dpad.right.isPressed,
        ]
        for (button, down) in buttons where gameButtons[button, default: false] != down {
            gameButtons[button] = down
            vnhub_renpy_controller_button(Int32(button), down ? 1 : 0)
        }
        func stick(_ value: Float) -> Int { Int((max(-1, min(1, value)) * 32767).rounded()) }
        // SDL's Y axes point down; GameController's point up. Triggers run 0...32767.
        let axes: [Int: Int] = [
            0: stick(pad.leftThumbstick.xAxis.value), 1: -stick(pad.leftThumbstick.yAxis.value),
            2: stick(pad.rightThumbstick.xAxis.value), 3: -stick(pad.rightThumbstick.yAxis.value),
            4: stick(pad.leftTrigger.value), 5: stick(pad.rightTrigger.value),
        ]
        for (axis, value) in axes where abs(gameAxes[axis, default: 0] - value) > 512 || (value == 0 && gameAxes[axis, default: 0] != 0) {
            gameAxes[axis] = value
            vnhub_renpy_controller_axis(Int32(axis), Int32(value))
        }
    }

    /// Delivers an action as if it came from the controller (debug scripting, tests).
    func fire(_ action: PadAction) {
        handler?(action)
    }

    /// A short, light tap on the controller's motors, for focus moves and selections.
    func tick(strong: Bool = false) {
        guard let engine = hapticEngine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: strong ? 0.8 : 0.4),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? engine.makePlayer(with: pattern)
        {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }

    /// The SF Symbol the controller itself uses for a button (Xbox letters, PlayStation
    /// shapes, ...), falling back to generic letters.
    func symbol(for action: PadAction) -> String {
        let pad = controller?.extendedGamepad
        let button: GCControllerElement? = switch action {
        case .a: pad?.buttonA
        case .b: pad?.buttonB
        case .x: pad?.buttonX
        case .y: pad?.buttonY
        case .leftShoulder: pad?.leftShoulder
        case .rightShoulder: pad?.rightShoulder
        case .menu: pad?.buttonMenu
        case .up, .down, .left, .right: pad?.dpad
        }
        if let name = button?.sfSymbolsName { return name }
        return switch action {
        case .a: "a.circle"
        case .b: "b.circle"
        case .x: "x.circle"
        case .y: "y.circle"
        case .leftShoulder: "l1.rectangle.roundedbottom"
        case .rightShoulder: "r1.rectangle.roundedbottom"
        case .menu: "line.3.horizontal.circle"
        case .up, .down, .left, .right: "dpad"
        }
    }
}

/// CADisplayLink retains its target; this keeps it from retaining `ControllerInput`.
@MainActor
private final class DisplayLinkTarget: NSObject {
    let body: @MainActor () -> Void
    init(_ body: @escaping @MainActor () -> Void) { self.body = body }
    @objc func tick() { body() }
}
