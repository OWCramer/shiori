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
    /// Forced on with `-ShioriControllerMode` (debug) so the launcher can be tested without hardware.
    private(set) var isForced = false

    /// `-ShioriControllerMode NO` (debug) ignores controllers, e.g. the simulator's virtual one.
    private(set) var isSuppressed = false

    #if os(tvOS)
    /// On Apple TV the focus engine drives the hub with any controller; the console-style
    /// launcher (and this class's hub actions) would move focus a second time per press.
    var isActive: Bool { false }
    #else
    var isActive: Bool { isForced || (isConnected && !isSuppressed) }
    #endif

    /// Receives each press, including repeats while a direction is held.
    var handler: ((PadAction) -> Void)?

    /// Set while a game that has no controller support is on screen (Artemis games): the
    /// launcher behind it gets nothing, and a press calls this instead so the game can say so.
    static var unsupportedGame: (@MainActor () -> Void)?

    #if os(tvOS)
    /// Set while the Apple TV library is on screen: the shoulder buttons switch its tabs
    /// (-1 left, +1 right). The focus engine has no use for them.
    static var tabSwitch: (@MainActor (Int) -> Void)?
    private var shouldersHeld: Set<Int> = []
    #endif

    /// Set while an in-process game that reads the pad itself is on screen (KiriKiri): each
    /// frame's pad state goes to it, and the launcher behind it gets nothing.
    static var gameReceiver: (@MainActor (GCExtendedGamepad) -> Void)?

    private var controller: GCController?
    #if os(tvOS)
    /// The Siri Remote, read through GameController for Ren'Py games (UIKit presses are kept
    /// from them; see PressFilter).
    private var remote: GCController?
    private var remoteButtons: [Int: Bool] = [:]
    #endif
    private var displayLink: CADisplayLink?
    private var held: Set<PadAction> = []
    private var repeatAt: [PadAction: CFTimeInterval] = [:]
    private var hapticEngine: CHHapticEngine?

    private static let repeatDelay: CFTimeInterval = 0.35
    private static let repeatInterval: CFTimeInterval = 0.11
    private static let stickThreshold: Float = 0.55

    init() {
        #if DEBUG
        isForced = UserDefaults.standard.bool(forKey: "ShioriControllerMode")
        isSuppressed = UserDefaults.standard.object(forKey: "ShioriControllerMode") != nil && !isForced
        // `-ShioriPadInput "3:right;4:a"` replays pad presses (seconds from launch).
        for step in (UserDefaults.standard.string(forKey: "ShioriPadInput") ?? "").split(separator: ";") {
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
        #if os(tvOS)
        remote = GCController.controllers().first { $0.extendedGamepad == nil && $0.microGamepad != nil }
        remote?.microGamepad?.reportsAbsoluteDpadValues = false
        remote?.microGamepad?.allowsRotation = true
        #endif
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
        #if os(tvOS)
        let shouldPoll = (controller != nil || remote != nil) && !isPaused
        #else
        let shouldPoll = controller != nil && !isPaused
        #endif
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
        #if os(tvOS)
        if shiori_renpy_is_running() != 0 {
            // The system keyboard is up (a name entry): the pad types there, so the game is
            // told every button it was holding is up and hears nothing until it closes.
            if PressFilter.isEditing {
                releaseGameInput()
                return
            }
            if let pad = controller?.extendedGamepad {
                forwardToGame(pad)
            } else if let remote = remote?.microGamepad {
                forwardRemoteToGame(remote)
            }
            return
        }
        #endif
        guard let pad = controller?.extendedGamepad else { return }
        if shiori_renpy_is_running() != 0 {
            forwardToGame(pad)
            return
        }
        if let receiver = Self.gameReceiver {
            receiver(pad)
            held = []
            return
        }
        #if os(tvOS)
        // Games without pad support (Artemis, Luca) take the controller as UIKit presses on
        // Apple TV, and the hub is the focus engine's, except for the shoulder buttons,
        // which switch the library's tabs.
        held = []
        for (step, button) in [(-1, pad.leftShoulder), (1, pad.rightShoulder)] {
            if button.isPressed, !shouldersHeld.contains(step) {
                shouldersHeld.insert(step)
                Self.tabSwitch?(step)
            } else if !button.isPressed {
                shouldersHeld.remove(step)
            }
        }
        return
        #endif
        if let notify = Self.unsupportedGame {
            let anyDown = [pad.buttonA, pad.buttonB, pad.buttonX, pad.buttonY, pad.leftShoulder, pad.rightShoulder,
                           pad.buttonMenu, pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right].contains { $0.isPressed }
            if anyDown, held.isEmpty { notify() }
            held = anyDown ? [.a] : []
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
            shiori_renpy_controller_button(Int32(button), down ? 1 : 0)
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
            shiori_renpy_controller_axis(Int32(axis), Int32(value))
        }
    }

    #if os(tvOS)
    /// Tells the game every button and stick it last heard as held is released.
    private func releaseGameInput() {
        for (button, down) in gameButtons where down {
            gameButtons[button] = false
            shiori_renpy_controller_button(Int32(button), 0)
        }
        for (button, down) in remoteButtons where down {
            remoteButtons[button] = false
            shiori_renpy_controller_button(Int32(button), 0)
        }
        for (axis, value) in gameAxes where value != 0 {
            gameAxes[axis] = 0
            shiori_renpy_controller_axis(Int32(axis), 0)
        }
    }

    /// The Siri Remote as a pad for Ren'Py: a click is A (read on, select), Menu is B (the
    /// game menu), Play/Pause is Y (hide the text box), and swipes are the d-pad.
    private func forwardRemoteToGame(_ remote: GCMicroGamepad) {
        let threshold: Float = 0.5
        let buttons: [Int: Bool] = [
            0: remote.buttonA.isPressed, 1: remote.buttonMenu.isPressed, 3: remote.buttonX.isPressed,
            11: remote.dpad.yAxis.value > threshold, 12: remote.dpad.yAxis.value < -threshold,
            13: remote.dpad.xAxis.value < -threshold, 14: remote.dpad.xAxis.value > threshold,
        ]
        for (button, down) in buttons where remoteButtons[button, default: false] != down {
            remoteButtons[button] = down
            shiori_renpy_controller_button(Int32(button), down ? 1 : 0)
        }
    }
    #endif

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
