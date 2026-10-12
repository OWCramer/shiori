import AVFoundation
import CryptoKit
import CSiglus
import GameController
import SwiftUI
import UIKit

/// Plays a Siglus game on siglus_rs (MPL-2.0, linked as ShioriSiglus.framework). The engine
/// draws with wgpu into this view's Metal layer; the view steps it from a 60 Hz display link
/// and turns touches into the mouse input Siglus games expect.
final class SiglusGameViewController: UIViewController {
    private let gameFolder: URL
    private let onExit: () -> Void
    /// Lifts the launch cover; called once, after the engine's first steps.
    private var onFirstFrame: (() -> Void)?
    private var handle: UnsafeMutableRawPointer?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var steps = 0
    private var leaving = false
    private var failed = false

    private var drawableSize: (width: UInt32, height: UInt32) = (0, 0)
    private var scale: Double = 0
    private var logicalSize = CGSize(width: 1280, height: 720)
    /// Where the game sits in the view, in points (letterboxed).
    private var gameRect = CGRect.zero
    /// The touch currently driving the pointer (Siglus has one mouse).
    private var pointerTouch: UITouch?
    /// Steps since the pointer went down, and a release held back until the engine has seen the
    /// press: the gestures hold a tap's touches until they fail, so its down and up can arrive
    /// together, and the engine reads the button once a step.
    private var stepsSincePress = 0
    private var heldRelease: (phase: Int32, point: CGPoint)?
    /// A right button pressed this step, released after the next one (the engine reads the
    /// button once a step, so a press and release in one step is no click).
    private var rightButtonDown = false
    #if DEBUG
    /// `-ShioriSiglusTaps "seconds:x,y ..."`: clicks in the game's logical pixels at times since
    /// the engine started (`seconds:rclick` for a right-click, `seconds:wheel±n` for wheel steps),
    /// for unattended simulator runs.
    private lazy var scriptedTaps: [(at: Double, x: Double, y: Double, right: Bool, wheel: Int32)] =
        (UserDefaults.standard.string(forKey: "ShioriSiglusTaps") ?? "").split(separator: " ").compactMap { item in
            let parts = item.split(separator: ":")
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            if parts[1] == "rclick" { return (at, 0, 0, true, 0) }
            if parts[1].hasPrefix("wheel"), let steps = Int32(parts[1].dropFirst(5)) { return (at, 0, 0, false, steps) }
            let xy = parts[1].split(separator: ",").compactMap { Double($0) }
            return xy.count == 2 ? (at, xy[0], xy[1], false, 0) : nil
        }
    private var engineStart: CFTimeInterval = 0
    private var scriptedRelease: (x: Double, y: Double)?
    #endif

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void = {}, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onFirstFrame = onFirstFrame
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private var metalLayer: CAMetalLayer { view.layer as! CAMetalLayer }

    override func loadView() {
        view = SiglusMetalView()
        view.backgroundColor = .black
        view.isOpaque = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Two-finger tap is a right-click (Siglus's menu / hide text); swiping down with two
        // fingers is the wheel (the backlog); a two-finger hold leaves the game. They hold
        // touches back until they fail, so a gesture never also reaches the game as a click.
        let menu = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        menu.numberOfTouchesRequired = 2
        menu.delaysTouchesBegan = true
        view.addGestureRecognizer(menu)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(scrollBack))
        history.direction = .down
        history.numberOfTouchesRequired = 2
        history.delaysTouchesBegan = true
        view.addGestureRecognizer(history)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        leave.delaysTouchesBegan = true
        view.addGestureRecognizer(leave)
        // The shared two-finger swipes (spec, Touch): right skips (Ctrl held down until the next
        // touch), up is auto, which Siglus games keep on their own window button.
        view.addSwipe(.right, fingers: 2, target: self, action: #selector(swipedSkip)).delaysTouchesBegan = true
        view.addSwipe(.up, fingers: 2, target: self, action: #selector(swipedAuto)).delaysTouchesBegan = true
        #if os(iOS)
        // Fingers only, so a trackpad's clicks aren't held back; the trackpad plays like the
        // PC's mouse: hover moves it, a secondary click is the right button, scrolling turns
        // the wheel.
        for gesture in [menu, history, leave] as [UIGestureRecognizer] { gesture.fingersOnly() }
        view.addHover(target: self, action: #selector(hovered(_:)))
        view.addScroll(target: self, action: #selector(scrolled(_:)))
        let pointer = UIPointerInteraction(delegate: self)
        view.addInteraction(pointer)
        pointerInteraction = pointer
        #endif

        // The pad drives the game through its keyboard and mouse (see `pad(_:)`).
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
        // While still in front (the save's thumbnail is read from the GPU), the place goes
        // into the game's own save slots; the background save then syncs it.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePlace(reason: "leaving the screen") }
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    #if os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    /// A hardware keyboard's keys go to the engine as the PC's (Escape, Enter, Space, arrows,
    /// Ctrl); Page Up turns the wheel up (the backlog).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil || $0 == .keyboardPageUp }
        for key in keys {
            if key == .keyboardPageUp { padPress(.wheelUp, down: true) }
            if let code = key.windowsVirtualKey { padPress(.key(code), down: true) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil }
        for key in keys { if let code = key.windowsVirtualKey { padPress(.key(code), down: false) } }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        // Keys from a hardware keyboard come here, not to UIKit (Escape would close the cover).
        becomeFirstResponder()
        #endif
        requestOrientations(.landscape)
        startIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let screenScale = Double(view.window?.screen.scale ?? UIScreen.main.scale)
        view.contentScaleFactor = screenScale
        metalLayer.contentsScale = screenScale
        let width = UInt32(max(1, (size.width * screenScale).rounded()))
        let height = UInt32(max(1, (size.height * screenScale).rounded()))
        metalLayer.drawableSize = CGSize(width: Int(width), height: Int(height))
        guard width != drawableSize.width || height != drawableSize.height || screenScale != scale else { return }
        drawableSize = (width, height)
        scale = screenScale
        applyViewport()
    }

    /// Letterboxes the game's logical size into the view and tells the engine.
    private func applyViewport() {
        let width = Double(drawableSize.width), height = Double(drawableSize.height)
        guard width > 0, height > 0 else { return }
        let fit = min(width / logicalSize.width, height / logicalSize.height)
        let viewportWidth = max(1, min(width, (logicalSize.width * fit).rounded()))
        let viewportHeight = max(1, min(height, (logicalSize.height * fit).rounded()))
        let x = ((width - viewportWidth) / 2).rounded(.down)
        let y = ((height - viewportHeight) / 2).rounded(.down)
        gameRect = CGRect(x: x / scale, y: y / scale, width: viewportWidth / scale, height: viewportHeight / scale)
        guard let handle else { return }
        siglus_ios_resize_viewport(handle, drawableSize.width, drawableSize.height,
                                   UInt32(x), UInt32(y), UInt32(viewportWidth), UInt32(viewportHeight))
    }

    // MARK: Engine

    private func startIfNeeded() {
        guard handle == nil, !leaving, !failed, drawableSize.width > 0 else { return }
        let root: URL
        do {
            root = try SiglusRuntime.prepareRoot(gameFolder: gameFolder)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let viewPointer = Unmanaged.passUnretained(view).toOpaque()
        handle = root.path.withCString { path in
            siglus_ios_create(viewPointer, drawableSize.width, drawableSize.height, scale, path)
        }
        guard let handle else {
            fail("The Siglus engine couldn't start this game.")
            return
        }
        var width: UInt32 = 1280, height: UInt32 = 720
        siglus_ios_logical_size(handle, &width, &height)
        logicalSize = CGSize(width: Int(max(1, width)), height: Int(max(1, height)))
        applyViewport()
        siglus_ios_set_native_messagebox_callback(handle, siglusMessagebox, Unmanaged.passUnretained(self).toOpaque())
        SiglusRuntime.log.notice("Started \(self.gameFolder.lastPathComponent, privacy: .public) at \(width)x\(height)")

        // The game asks for a steady 60: with a wider range, iOS settles a 120 Hz iPhone at 48.
        let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard let handle, !leaving else { return }
        let interval = lastTimestamp.map { link.timestamp - $0 } ?? link.duration
        lastTimestamp = link.timestamp
        let elapsed = UInt32((min(max(interval, 0), 0.2) * 1000).rounded())
        let status = siglus_ios_step(handle, elapsed)
        if status == 1 {
            leave() // the game quit (its own Exit)
            return
        }
        guard status == 0 else {
            fail("The game stopped (\(status)).")
            return
        }
        steps += 1
        #if os(iOS)
        if enginePointerMode != pointerHovering {
            enginePointerMode = pointerHovering
            siglus_ios_set_pointer_mode(handle, pointerHovering ? 1 : 0)
            PointerLog.write("siglus pointer mode \(pointerHovering), game cursor \(siglus_ios_has_custom_cursor(handle))")
        }
        if pointerHovering {
            let shown = siglus_ios_has_custom_cursor(handle) != 0
            if shown != gameCursorShown {
                gameCursorShown = shown
                pointerInteraction?.invalidate()
            }
        }
        #endif
        stepsSincePress += 1
        #if DEBUG
        runScriptedTaps(handle)
        #endif
        if let release = heldRelease {
            heldRelease = nil
            send(phase: release.phase, at: release.point)
        }
        if rightButtonDown {
            rightButtonDown = false
            siglus_ios_mouse_button(handle, 1, 0)
        }
        if steps == 3, let lift = onFirstFrame {
            onFirstFrame = nil
            lift()
        }
    }

    #if DEBUG
    private func runScriptedTaps(_ handle: UnsafeMutableRawPointer) {
        if engineStart == 0 { engineStart = CACurrentMediaTime() }
        if let release = scriptedRelease {
            scriptedRelease = nil
            siglus_ios_touch(handle, 2, release.x, release.y)
        }
        let elapsed = CACurrentMediaTime() - engineStart
        guard let next = scriptedTaps.first, elapsed >= next.at else { return }
        scriptedTaps.removeFirst()
        if next.right {
            pressRightButton(handle)
        } else if next.wheel != 0 {
            siglus_ios_mouse_wheel(handle, next.wheel)
        } else {
            siglus_ios_touch(handle, 0, next.x, next.y)
            scriptedRelease = (next.x, next.y)
        }
    }
    #endif

    // MARK: Touch

    private func pressRightButton(_ handle: UnsafeMutableRawPointer) {
        guard !rightButtonDown else { return }
        siglus_ios_mouse_button(handle, 1, 1)
        rightButtonDown = true
    }

    private func send(phase: Int32, at point: CGPoint) {
        guard let handle, gameRect.width > 0 else { return }
        // View points to the game's logical coordinates.
        let x = min(max((point.x - gameRect.minX) / gameRect.width, 0), 1) * logicalSize.width
        let y = min(max((point.y - gameRect.minY) / gameRect.height, 0), 1) * logicalSize.height
        siglus_ios_touch(handle, phase, x, y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A touch ends a skip the swipe started (as letting go of Ctrl does).
        if skipLatched {
            releaseSkipLatch()
            return
        }
        guard pointerTouch == nil, let touch = touches.first, (event?.allTouches?.count ?? 1) == 1 else { return }
        #if os(iOS)
        // A trackpad's click turns pointer mode on too (hover may not have come first).
        pointerHovering = touch.isPointer
        PointerLog.write("siglus touch \(touch.type.rawValue) buttons \(event?.buttonMask.rawValue ?? 0)")
        if touch.isPointer, event?.buttonMask.contains(.secondary) == true, let handle {
            send(phase: 1, at: touch.location(in: view))
            pressRightButton(handle)
            return
        }
        #endif
        pointerTouch = touch
        stepsSincePress = 0
        send(phase: 0, at: touch.location(in: view))
    }

    private func release(_ phase: Int32, at point: CGPoint) {
        if stepsSincePress == 0 {
            heldRelease = (phase, point)
        } else {
            send(phase: phase, at: point)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        send(phase: 1, at: touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        release(2, at: touch.location(in: view))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        release(3, at: touch.location(in: view))
    }

    @objc private func rightClick(_ recognizer: UITapGestureRecognizer) {
        releaseSkipLatch()
        guard let handle else { return }
        send(phase: 1, at: recognizer.location(in: view))
        pressRightButton(handle)
    }

    #if os(iOS)
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .began { PointerLog.write("siglus hover began") }
        guard pointerTouch == nil, recognizer.state == .began || recognizer.state == .changed else { return }
        pointerHovering = true
        send(phase: 1, at: recognizer.location(in: view))
    }

    private var scrollSent: CGFloat = 0

    /// One wheel step per 30 points of two-finger scrolling (positive is up, the backlog).
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        guard let handle else { return }
        if recognizer.state == .began { scrollSent = 0 }
        guard recognizer.state == .changed else { return }
        let travel = recognizer.translation(in: view).y - scrollSent
        let steps = (travel / 30).rounded(.towardZero)
        guard steps != 0 else { return }
        scrollSent += steps * 30
        send(phase: 1, at: recognizer.location(in: view))
        siglus_ios_mouse_wheel(handle, Int32(steps))
    }
    #endif

    /// A trackpad or mouse hovered since the last finger: the game's own cursor shows, in
    /// place of the iPad pointer when the game has one.
    private var pointerHovering = false {
        didSet { if pointerHovering != oldValue { pointerInteraction?.invalidate() } }
    }
    /// What the engine was last told (each step syncs it: the pointer can arrive while the
    /// engine is still starting, before there's an engine to tell).
    private var enginePointerMode = false
    private var pointerInteraction: UIPointerInteraction?
    /// Whether the game drew its own cursor at the last check (it can change per scene).
    private var gameCursorShown = false

    // MARK: Skip and auto

    /// Ctrl held down by a two-finger swipe right: Siglus skips while it's down, until the
    /// next touch lets it go.
    private var skipLatched = false

    @objc private func swipedSkip() {
        guard let handle else { return }
        if skipLatched {
            releaseSkipLatch()
            return
        }
        skipLatched = true
        SiglusRuntime.log.notice("Skip: Ctrl held by the swipe")
        siglus_ios_key(handle, 0x11, 1)
        GameNotice.show("Skipping. Tap to stop.", in: view)
    }

    private func releaseSkipLatch() {
        guard skipLatched else { return }
        skipLatched = false
        if let handle { siglus_ios_key(handle, 0x11, 0) }
    }

    /// Siglus has no key for auto mode (siglus_rs takes it from the game's own syscom calls):
    /// the game's window button turns it on.
    @objc private func swipedAuto() {
        GameNotice.show("Use the AUTO button on the message window.", in: view)
    }

    @objc private func scrollBack(_ recognizer: UISwipeGestureRecognizer) {
        guard let handle else { return }
        send(phase: 1, at: recognizer.location(in: view))
        siglus_ios_mouse_wheel(handle, 1)
    }

    // MARK: Controller

    /// What Siglus games answer to on a PC keyboard and mouse: Enter reads on and presses the
    /// focused button, the arrow keys move between buttons, a right-click opens the menu or
    /// goes back, the wheel opens the backlog, Ctrl held skips, Escape cancels.
    private enum PadKey: Hashable {
        case key(Int32)
        case rightClick
        case wheelUp
        case auto
    }

    private var padHeld: Set<PadKey> = []
    private var padRepeatAt: [PadKey: CFTimeInterval] = [:]
    private var leaveAlert: UIAlertController?
    private var padOptionsDown = false

    private func pad(_ pad: GCExtendedGamepad) {
        // Options asks to leave; on that question A leaves and B keeps playing.
        let options = pad.buttonOptions?.isPressed ?? false
        defer { padOptionsDown = options }
        if let alert = leaveAlert, presentedViewController === alert {
            if pad.buttonA.isPressed, !padHeld.contains(.key(0x0D)) {
                alert.dismiss(animated: true) { [weak self] in
                    self?.savePlace(reason: "leaving the game")
                    self?.leave()
                }
            } else if pad.buttonB.isPressed, !padHeld.contains(.rightClick) {
                alert.dismiss(animated: true)
            }
            padHeld = pad.buttonA.isPressed ? [.key(0x0D)] : pad.buttonB.isPressed ? [.rightClick] : []
            return
        }
        guard handle != nil, presentedViewController == nil else { return }
        if options, !padOptionsDown {
            releasePadKeys()
            presentLeaveQuestion()
            return
        }
        let stick = pad.leftThumbstick
        let threshold: Float = 0.55
        let pressed: [PadKey: Bool] = [
            .key(0x26): pad.dpad.up.isPressed || stick.yAxis.value > threshold, // VK_UP
            .key(0x28): pad.dpad.down.isPressed || stick.yAxis.value < -threshold, // VK_DOWN
            .key(0x25): pad.dpad.left.isPressed || stick.xAxis.value < -threshold, // VK_LEFT
            .key(0x27): pad.dpad.right.isPressed || stick.xAxis.value > threshold, // VK_RIGHT
            .key(0x0D): pad.buttonA.isPressed, // VK_RETURN
            .key(0x11): pad.rightShoulder.isPressed || pad.rightTrigger.isPressed, // VK_CONTROL: skip while held
            .key(0x1B): pad.buttonMenu.isPressed, // VK_ESCAPE
            .rightClick: pad.buttonB.isPressed,
            .wheelUp: pad.buttonY.isPressed || pad.leftShoulder.isPressed,
            .auto: pad.buttonX.isPressed,
        ]
        let now = CACurrentMediaTime()
        for (key, isDown) in pressed {
            let wasDown = padHeld.contains(key)
            if isDown, !wasDown {
                padHeld.insert(key)
                padRepeatAt[key] = now + 0.35
                padPress(key, down: true)
            } else if isDown, case .key(let code) = key, (0x25...0x28).contains(code), let at = padRepeatAt[key], now >= at {
                // Held arrows repeat, as a keyboard's do.
                padRepeatAt[key] = now + 0.11
                padPress(key, down: true)
            } else if !isDown, wasDown {
                padHeld.remove(key)
                padRepeatAt[key] = nil
                padPress(key, down: false)
            }
        }
    }

    private func releasePadKeys() {
        for key in padHeld { padPress(key, down: false) }
        padHeld.removeAll()
        padRepeatAt.removeAll()
    }

    private func padPress(_ key: PadKey, down: Bool) {
        guard let handle else { return }
        switch key {
        case .key(let code):
            siglus_ios_key(handle, code, down ? 1 : 0)
        case .rightClick:
            guard down else { return }
            pressRightButton(handle)
        case .wheelUp:
            guard down else { return }
            siglus_ios_mouse_wheel(handle, 1)
        case .auto:
            if down { swipedAuto() }
        }
    }

    // MARK: Messages from the game

    /// A Windows message box the game raised (its own "Quit?" and the like).
    fileprivate func showMessagebox(requestID: UInt64, kind: Int32, title: String, message: String) {
        guard let handle else { return }
        let answer = { (value: Int64) in { (_: UIAlertAction) in siglus_ios_submit_messagebox_result(handle, requestID, value) } }
        let alert = UIAlertController(title: title.isEmpty ? nil : title, message: message, preferredStyle: .alert)
        switch kind {
        case 1: // OK / Cancel
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: answer(0)))
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: answer(1)))
        case 2: // Yes / No
            alert.addAction(UIAlertAction(title: "Yes", style: .default, handler: answer(0)))
            alert.addAction(UIAlertAction(title: "No", style: .cancel, handler: answer(1)))
        case 3: // Yes / No / Cancel
            alert.addAction(UIAlertAction(title: "Yes", style: .default, handler: answer(0)))
            alert.addAction(UIAlertAction(title: "No", style: .default, handler: answer(1)))
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: answer(2)))
        default:
            alert.addAction(UIAlertAction(title: "OK", style: .default, handler: answer(0)))
        }
        if presentedViewController != nil {
            dismiss(animated: false) { [weak self] in self?.present(alert, animated: true) }
        } else {
            present(alert, animated: true)
        }
    }

    // MARK: Leaving

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil else { return }
        presentLeaveQuestion()
    }

    private func presentLeaveQuestion() {
        // Honest about what leaving keeps: the place where the game could save it now.
        let kept = canSavePlace
            ? "Your place is saved to the Load screen."
            : "Progress since your last save is lost."
        let message = GCController.current?.extendedGamepad != nil ? kept + " Ⓐ Leave, Ⓑ Keep Playing." : kept
        let alert = UIAlertController(title: "Leave the game?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
            self?.savePlace(reason: "leaving the game")
            self?.leave()
        })
        leaveAlert = alert
        present(alert, animated: true)
    }

    private func fail(_ message: String) {
        failed = true
        displayLink?.invalidate()
        displayLink = nil
        SiglusRuntime.log.error("\(message, privacy: .public)")
        // Show the game's view rather than the cover behind the message.
        if let lift = onFirstFrame {
            onFirstFrame = nil
            lift()
        }
        let alert = UIAlertController(title: "The game stopped", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        displayLink?.invalidate()
        displayLink = nil
        if let handle {
            siglus_ios_set_native_messagebox_callback(handle, nil, nil)
            siglus_ios_destroy(handle)
        }
        handle = nil
        ControllerInput.gameReceiver = nil
        requestOrientations(.all)
        onExit()
    }

    // MARK: Saving the place

    /// Which of the game's save slots holds the place Shiori saved last, and that file's
    /// SHA-256: Shiori reuses the slot only while it still holds that save, so a save the
    /// player made over it is never overwritten. Kept in `saves/`, so it travels with the
    /// saves through iCloud (Steam Cloud's rules take only the game's files).
    private struct PlaceRecord: Codable {
        var slot: Int
        var sha256: String
        var saved: Date
    }

    private static let placeRecordFile = "shiori-place.json"

    private var savesFolder: URL { gameFolder.appendingPathComponent("saves", isDirectory: true) }

    private func slotFile(_ slot: Int) -> URL {
        savesFolder.appendingPathComponent(String(format: "%04d.sav", slot))
    }

    /// The slot Shiori saved the place into last, if that save is still there unchanged.
    private var ownedSlot: Int? {
        guard let data = try? Data(contentsOf: savesFolder.appendingPathComponent(Self.placeRecordFile)),
              let record = try? JSONDecoder().decode(PlaceRecord.self, from: data),
              let file = try? Data(contentsOf: slotFile(record.slot)),
              Self.sha256(file) == record.sha256 else { return nil }
        return record.slot
    }

    /// Whether the game could save its place now (it has a save point, its script allows
    /// saving, and a slot is free or Shiori's own).
    private var canSavePlace: Bool {
        guard let handle, !leaving, !failed else { return false }
        return siglus_ios_save_place(handle, Int32(ownedSlot ?? -1), 1) >= 0
    }

    /// Saves the game's place in its own format (what its SAVE writes: the save point where
    /// the message on screen began) into Shiori's slot, or the first free one, so the game's
    /// Load screen and its Continue find it and Steam Cloud carries it to the PC. Between
    /// engine steps (this runs on the main thread, as the display link does).
    private func savePlace(reason: String) {
        guard let handle, !leaving, !failed else { return }
        let slot = siglus_ios_save_place(handle, Int32(ownedSlot ?? -1), 0)
        switch slot {
        case 0...:
            if let file = try? Data(contentsOf: slotFile(Int(slot))) {
                let record = PlaceRecord(slot: Int(slot), sha256: Self.sha256(file), saved: .now)
                try? JSONEncoder().encode(record).write(to: savesFolder.appendingPathComponent(Self.placeRecordFile), options: .atomic)
            }
            SiglusRuntime.log.notice("Saved the place in slot \(slot) (\(String(format: "%04d.sav", slot), privacy: .public)), \(reason, privacy: .public)")
        case -1:
            SiglusRuntime.log.notice("No place to save, \(reason, privacy: .public) (no save point, or saving is off here)")
        case -2:
            SiglusRuntime.log.notice("No free save slot for the place, \(reason, privacy: .public)")
        default:
            SiglusRuntime.log.error("Saving the place failed (\(slot)), \(reason, privacy: .public)")
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func requestOrientations(_ mask: UIInterfaceOrientationMask) {
        OrientationLock.set(mask, in: view.window?.windowScene)
    }
}

/// Message boxes arrive from the engine's thread; the alert goes up on the main one.
private func siglusMessagebox(userData: UnsafeMutableRawPointer?, requestID: UInt64, kind: Int32,
                              title: UnsafePointer<CChar>?, message: UnsafePointer<CChar>?) {
    guard let userData else { return }
    let controller = Unmanaged<SiglusGameViewController>.fromOpaque(userData).takeUnretainedValue()
    let titleText = title.map { String(cString: $0) } ?? ""
    let messageText = message.map { String(cString: $0) } ?? ""
    DispatchQueue.main.async {
        controller.showMessagebox(requestID: requestID, kind: kind, title: titleText, message: messageText)
    }
}

/// wgpu draws into the view's Metal layer.
private final class SiglusMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

/// SwiftUI wrapper for presenting a Siglus game full screen.
struct SiglusGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> SiglusGameViewController {
        SiglusGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: SiglusGameViewController, context: Context) {}
}

#if os(iOS)
extension SiglusGameViewController: UIPointerInteractionDelegate {
    /// The iPad pointer hides while the game draws its own cursor (Gameexe #MOUSE_CURSOR),
    /// as the PC build hides Windows's.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard pointerHovering, let handle, siglus_ios_has_custom_cursor(handle) != 0 else {
            PointerLog.write("siglus pointer style: system")
            return nil
        }
        PointerLog.write("siglus pointer style: hidden (the game draws its cursor)")
        return .hidden()
    }
}
#endif
