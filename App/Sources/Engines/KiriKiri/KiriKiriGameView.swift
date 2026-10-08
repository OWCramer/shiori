import CKiriKiri
import CKiriKiriMetal
import GameController
import Metal
import QuartzCore
import SwiftUI
import UIKit

/// Plays a KiriKiri game on AetherKrkr (GPL-3.0, linked as ShioriKiriKiri.framework). The
/// engine composes each frame on Shiori's Metal bridge; this view ticks it, presents the
/// frame, and turns touches into the mouse input KiriKiri games expect.
final class KiriKiriGameViewController: UIViewController {
    private let gameFolder: URL
    private let appID: UInt32
    private let onExit: () -> Void
    private var engine: engine_handle_t?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    /// Present the current frame on the next tick even if it isn't new (the layer was resized).
    private var needsPresent = true
    private var surface: (width: UInt32, height: UInt32) = (0, 0)
    /// The game's canvas size, from its frames; the surface follows it.
    private var gameSize: CGSize = .zero
    private var lastFrameSerial: UInt64 = 0
    private var leaving = false
    #if DEBUG
    private var perf = KiriKiriPerfLog()
    private lazy var automation = KiriKiriDebugAutomation()
    #endif
    /// The touch currently driving the pointer (KiriKiri has one mouse).
    private weak var pointerTouch: UITouch?

    private var metalLayer: CAMetalLayer { view.layer as! CAMetalLayer }

    init(gameFolder: URL, appID: UInt32, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.appID = appID
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func loadView() {
        view = KiriKiriMetalView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalLayer.device = shiori_krkr_metal_device().flatMap {
            Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? MTLDevice
        } ?? MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        // Two-finger tap is a right-click (KiriKiri's menu / hide text); a two-finger hold
        // leaves the game; swiping down scrolls the wheel up (the backlog).
        let menu = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        menu.numberOfTouchesRequired = 2
        menu.cancelsTouchesInView = false
        view.addGestureRecognizer(menu)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        leave.cancelsTouchesInView = false
        view.addGestureRecognizer(leave)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(scrollBack))
        history.direction = .down
        history.numberOfTouchesRequired = 2
        history.cancelsTouchesInView = false
        view.addGestureRecognizer(history)

        // The pad drives the game through its keyboard and mouse (see `pad(_:)`).
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestOrientations(.landscape)
        startIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        metalLayer.drawableSize = size
        needsPresent = true
        // Until the first frame says how big the game is, start with the screen's size.
        guard gameSize == .zero, surface == (0, 0) else { return }
        surface = (UInt32(size.width.rounded()), UInt32(size.height.rounded()))
    }

    /// Where the game sits in the view: aspect-fitted and centred, as the presenter draws it.
    private var gameRect: CGRect {
        guard gameSize.width > 0, gameSize.height > 0 else { return .zero }
        let bounds = view.bounds
        let scale = min(bounds.width / gameSize.width, bounds.height / gameSize.height)
        let size = CGSize(width: gameSize.width * scale, height: gameSize.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    // MARK: Engine

    private func startIfNeeded() {
        guard engine == nil, !leaving, surface.width > 0 else { return }
        do {
            engine = try KiriKiriRuntime.open(gameFolder: gameFolder, appID: appID, width: surface.width, height: surface.height)
        } catch {
            fail(error.localizedDescription)
            return
        }
        lastTick = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let engine, !leaving else { return }
        let now = CACurrentMediaTime()
        let interval = (now - lastTick) * 1000
        let elapsed = UInt32(max(1, min(100, interval)))
        lastTick = now
        #if DEBUG
        var presentMs = 0.0
        defer { perf.record(interval: interval, tick: (CACurrentMediaTime() - now) * 1000 - presentMs, present: presentMs, folder: gameFolder) }
        #endif
        #if DEBUG
        automation.beforeTick(engine: engine, elapsed: elapsed)
        #endif
        let result = engine_tick(engine, elapsed)
        if result != ENGINE_RESULT_OK {
            let message = engine_get_last_error(engine).map { String(cString: $0) } ?? ""
            if result == ENGINE_RESULT_INVALID_STATE {
                leave() // the game quit (its own Exit)
            } else {
                fail(message.isEmpty ? "The game stopped (\(result.rawValue))." : message)
            }
            return
        }
        KiriKiriRuntime.drainLogs(engine)
        KiriKiriRuntime.handlePlatformRequests(engine)
        var texture: UInt64 = 0, width: UInt32 = 0, height: UInt32 = 0, serial: UInt64 = 0
        if engine_get_godot_native_frame_texture(engine, &texture, &width, &height, &serial) == ENGINE_RESULT_OK,
           texture != 0 {
            if gameSize == .zero {
                // First frame: the game's own canvas. From now on the surface is the game's
                // size and frames are composed (KiriKiriRuntime.useGameSize).
                gameSize = CGSize(width: Int(width), height: Int(height))
                surface = (width, height)
                KiriKiriRuntime.useGameSize(engine, width: width, height: height)
            }
            let newFrame = serial != lastFrameSerial
            lastFrameSerial = serial
            #if DEBUG
            if newFrame { automation.frameReady(texture: texture, width: width, height: height) }
            #endif
            // Only new frames (and the first after a resize) are presented: each present waits
            // for a free drawable, which on a busy GPU held up the next tick for nothing.
            if newFrame || needsPresent {
                needsPresent = false
                #if DEBUG
                let presentStart = CACurrentMediaTime()
                defer { presentMs = (CACurrentMediaTime() - presentStart) * 1000 }
                #endif
                _ = shiori_krkr_metal_present(Unmanaged.passUnretained(metalLayer).toOpaque(), texture, newFrame)
            }
        }
    }

    // MARK: Input

    private func send(_ type: engine_input_event_type_t, at point: CGPoint, button: Int32 = 0,
                      deltaY: Double = 0, modifiers: Int32 = 0) {
        guard let engine else { return }
        let rect = gameRect
        guard rect.width > 0 else { return }
        var event = engine_input_event_t()
        event.struct_size = UInt32(MemoryLayout<engine_input_event_t>.size)
        event.type = type.rawValue
        event.timestamp_micros = UInt64(CACurrentMediaTime() * 1_000_000)
        // View points to game pixels (the surface is the game's size).
        event.x = min(max((point.x - rect.minX) / rect.width, 0), 1) * gameSize.width
        event.y = min(max((point.y - rect.minY) / rect.height, 0), 1) * gameSize.height
        event.delta_y = deltaY
        event.button = button
        event.modifiers = modifiers
        _ = engine_send_input(engine, &event)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerTouch == nil, let touch = touches.first, (event?.allTouches?.count ?? 1) == 1 else { return }
        pointerTouch = touch
        send(ENGINE_INPUT_EVENT_POINTER_MOVE, at: touch.location(in: view))
        send(ENGINE_INPUT_EVENT_POINTER_DOWN, at: touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        send(ENGINE_INPUT_EVENT_POINTER_MOVE, at: touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        send(ENGINE_INPUT_EVENT_POINTER_UP, at: touch.location(in: view))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        // A gesture took the touch over: release without clicking.
        send(ENGINE_INPUT_EVENT_POINTER_UP, at: touch.location(in: view),
             modifiers: Int32(ENGINE_INPUT_MODIFIER_POINTER_CANCEL.rawValue))
    }

    @objc private func rightClick(_ recognizer: UITapGestureRecognizer) {
        cancelPointer()
        let point = recognizer.location(in: view)
        send(ENGINE_INPUT_EVENT_POINTER_DOWN, at: point, button: 1)
        send(ENGINE_INPUT_EVENT_POINTER_UP, at: point, button: 1)
    }

    @objc private func scrollBack(_ recognizer: UISwipeGestureRecognizer) {
        cancelPointer()
        send(ENGINE_INPUT_EVENT_POINTER_SCROLL, at: recognizer.location(in: view), deltaY: 1)
    }

    /// A second finger arrived: the first touch wasn't a click.
    private func cancelPointer() {
        guard let touch = pointerTouch else { return }
        pointerTouch = nil
        send(ENGINE_INPUT_EVENT_POINTER_UP, at: touch.location(in: view),
             modifiers: Int32(ENGINE_INPUT_MODIFIER_POINTER_CANCEL.rawValue))
    }

    // MARK: Controller

    /// What KiriKiri (KAG) games answer to on a PC keyboard and mouse: Enter reads on and
    /// presses the focused button, the arrow keys move between buttons, a right-click opens
    /// the menu or goes back, the wheel opens the backlog, Ctrl held skips, Escape cancels.
    private enum PadKey: Hashable {
        case key(Int32)
        case rightClick
        case wheelUp
    }

    private var padHeld: Set<PadKey> = []
    private var padRepeatAt: [PadKey: CFTimeInterval] = [:]
    private var padDownAt: [Int32: CFTimeInterval] = [:]

    private var leaveAlert: UIAlertController?
    private var padOptionsDown = false

    private func pad(_ pad: GCExtendedGamepad) {
        // Options asks to leave; on that question A leaves and B keeps playing.
        let options = pad.buttonOptions?.isPressed ?? false
        defer { padOptionsDown = options }
        if let alert = leaveAlert, presentedViewController === alert {
            if pad.buttonA.isPressed, !padHeld.contains(.key(0x0D)) {
                alert.dismiss(animated: true) { [weak self] in self?.leave() }
            } else if pad.buttonB.isPressed, !padHeld.contains(.rightClick) {
                alert.dismiss(animated: true)
            }
            padHeld = pad.buttonA.isPressed ? [.key(0x0D)] : pad.buttonB.isPressed ? [.rightClick] : []
            return
        }
        guard engine != nil, presentedViewController == nil else { return }
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

    private func sendKey(_ code: Int32, down: Bool) {
        guard let engine else { return }
        var event = engine_input_event_t()
        event.struct_size = UInt32(MemoryLayout<engine_input_event_t>.size)
        event.type = (down ? ENGINE_INPUT_EVENT_KEY_DOWN : ENGINE_INPUT_EVENT_KEY_UP).rawValue
        event.timestamp_micros = UInt64(CACurrentMediaTime() * 1_000_000)
        event.key_code = code
        _ = engine_send_input(engine, &event)
    }

    private func releasePadKeys() {
        for key in padHeld { padPress(key, down: false) }
        padHeld.removeAll()
        padRepeatAt.removeAll()
    }

    private func padPress(_ key: PadKey, down: Bool) {
        cancelPointer()
        switch key {
        case .key(let code):
            // KAG also reads the key's state when the press arrives, so a press is held for at
            // least 0.1 s however quickly the button comes back up.
            let now = CACurrentMediaTime()
            if down {
                padDownAt[code] = now
            } else if let at = padDownAt[code], now - at < 0.1 {
                padDownAt[code] = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + (0.1 - (now - at))) { [weak self] in
                    self?.sendKey(code, down: false)
                }
                return
            }
            sendKey(code, down: down)
        case .rightClick:
            guard down else { return }
            let point = CGPoint(x: gameRect.midX, y: gameRect.midY)
            send(ENGINE_INPUT_EVENT_POINTER_DOWN, at: point, button: 1)
            send(ENGINE_INPUT_EVENT_POINTER_UP, at: point, button: 1)
        case .wheelUp:
            guard down else { return }
            send(ENGINE_INPUT_EVENT_POINTER_SCROLL, at: CGPoint(x: gameRect.midX, y: gameRect.midY), deltaY: 1)
        }
    }

    // MARK: Leaving

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil else { return }
        cancelPointer()
        presentLeaveQuestion()
    }

    private func presentLeaveQuestion() {
        let message = GCController.current?.extendedGamepad != nil
            ? "Progress since your last save is lost. Ⓐ Leave, Ⓑ Keep Playing."
            : "Progress since your last save is lost."
        let alert = UIAlertController(title: "Leave the game?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        leaveAlert = alert
        present(alert, animated: true)
    }

    private func fail(_ message: String) {
        displayLink?.invalidate()
        displayLink = nil
        NSLog("KiriKiri: %@", message)
        let alert = UIAlertController(title: "The game stopped", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        displayLink?.invalidate()
        displayLink = nil
        if let engine { KiriKiriRuntime.close(engine) }
        engine = nil
        ControllerInput.gameReceiver = nil
        requestOrientations(.all)
        onExit()
    }

    private func requestOrientations(_ mask: UIInterfaceOrientationMask) {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

private final class KiriKiriMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

/// SwiftUI wrapper for presenting a KiriKiri game full screen.
struct KiriKiriGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    let appID: UInt32
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> KiriKiriGameViewController {
        KiriKiriGameViewController(gameFolder: gameFolder, appID: appID, onExit: onExit)
    }

    func updateUIViewController(_ controller: KiriKiriGameViewController, context: Context) {}
}

#if DEBUG
/// Debug launch options for reproducing a scene on the Mac ("Designed for iPad"):
/// - `VNHubKiriKiriTaps`: "seconds:x,y ..." clicks in game pixels at engine times;
/// - `VNHubKiriKiriDumpFrames`: "fromSecond-toSecond" saves every new frame in that window
///   to Caches/KiriKiri/frames as PPM, named by engine milliseconds.
@MainActor
private final class KiriKiriDebugAutomation {
    private var clock: UInt64 = 0 // engine milliseconds
    private var taps: [(at: UInt64, x: Double, y: Double)]
    private let dumpWindow: ClosedRange<UInt64>?
    private let folder: URL

    init() {
        let defaults = UserDefaults.standard
        taps = (defaults.string(forKey: "VNHubKiriKiriTaps") ?? "").split(separator: " ").compactMap { item in
            let parts = item.split(whereSeparator: { $0 == ":" || $0 == "," }).compactMap { Double($0) }
            return parts.count == 3 ? (UInt64(parts[0] * 1000), parts[1], parts[2]) : nil
        }
        let window = (defaults.string(forKey: "VNHubKiriKiriDumpFrames") ?? "").split(separator: "-").compactMap { Double($0) }
        dumpWindow = window.count == 2 ? UInt64(window[0] * 1000)...UInt64(window[1] * 1000) : nil
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KiriKiri/frames", isDirectory: true)
        if dumpWindow != nil {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    func beforeTick(engine: engine_handle_t, elapsed: UInt32) {
        clock += UInt64(elapsed)
        while let tap = taps.first, tap.at <= clock {
            taps.removeFirst()
            var event = engine_input_event_t()
            event.struct_size = UInt32(MemoryLayout<engine_input_event_t>.size)
            event.x = tap.x
            event.y = tap.y
            for type in [ENGINE_INPUT_EVENT_POINTER_MOVE, ENGINE_INPUT_EVENT_POINTER_DOWN, ENGINE_INPUT_EVENT_POINTER_UP] {
                event.type = type.rawValue
                _ = engine_send_input(engine, &event)
            }
            KiriKiriRuntime.log.notice("Debug tap at \(tap.x),\(tap.y) (\(self.clock) ms)")
        }
    }

    func frameReady(texture: UInt64, width: UInt32, height: UInt32) {
        guard let dumpWindow, dumpWindow.contains(clock) else { return }
        let header = "P6\n\(width) \(height)\n255\n"
        var rgba = [UInt8](repeating: 0, count: Int(width * height * 4))
        guard shiori_krkr_metal_read(texture, &rgba, rgba.count, width * 4) else { return }
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + Int(width * height * 3))
        var rgb = [UInt8](repeating: 0, count: Int(width * height * 3))
        for pixel in 0..<Int(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        data.append(contentsOf: rgb)
        try? data.write(to: folder.appendingPathComponent(String(format: "f%07llu.ppm", clock)))
    }
}
#endif

#if DEBUG
/// Debug builds: frame timing every 300 ticks (interval between display-link ticks, engine tick,
/// present) and what the Metal bridge did, logged and appended to
/// Caches/KiriKiri/<game>/perf.txt so a device run can be read afterwards.
@MainActor
private struct KiriKiriPerfLog {
    private var intervals: [Double] = [], ticks: [Double] = [], presents: [Double] = []

    mutating func record(interval: Double, tick: Double, present: Double, folder: URL) {
        intervals.append(interval); ticks.append(tick); presents.append(present)
        guard ticks.count == 300 else { return }
        func line(_ name: String, _ values: [Double]) -> String {
            let sorted = values.sorted()
            let average = sorted.reduce(0, +) / Double(sorted.count)
            let slow = values.filter { $0 > 17.5 }.count
            return String(format: "%@ avg %.1f p50 %.1f p95 %.1f max %.1f >17.5ms %d", name, average,
                          sorted[sorted.count / 2], sorted[sorted.count * 95 / 100], sorted.last ?? 0, slow)
        }
        var bridge = [CChar](repeating: 0, count: 512)
        shiori_krkr_metal_stats(&bridge, bridge.count)
        let text = [line("interval", intervals), line("tick", ticks), line("present", presents), String(cString: bridge)]
            .joined(separator: " | ")
        KiriKiriRuntime.log.notice("\(text, privacy: .public)")
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KiriKiri/\(folder.lastPathComponent)/perf.txt")
        let entry = "\(Date.now.formatted(date: .omitted, time: .standard)) \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(entry.utf8)); try? handle.close()
        } else {
            try? Data(entry.utf8).write(to: url)
        }
        intervals.removeAll(keepingCapacity: true); ticks.removeAll(keepingCapacity: true)
        presents.removeAll(keepingCapacity: true)
    }
}
#endif
