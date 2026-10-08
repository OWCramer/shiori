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
    private let onExit: () -> Void
    private var engine: engine_handle_t?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var surface: (width: UInt32, height: UInt32) = (0, 0)
    /// The game's canvas size, from its frames; the surface follows it.
    private var gameSize: CGSize = .zero
    private var lastFrameSerial: UInt64 = 0
    private var leaving = false
    #if DEBUG
    private var tickTimes: [Double] = []
    #endif
    /// The touch currently driving the pointer (KiriKiri has one mouse).
    private weak var pointerTouch: UITouch?

    private var metalLayer: CAMetalLayer { view.layer as! CAMetalLayer }

    init(gameFolder: URL, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
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

        // KiriKiri games here take touch and mouse only; keep the pad off the launcher.
        ControllerInput.unsupportedGame = { [weak self] in self?.showControllerNotice() }
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
            engine = try KiriKiriRuntime.open(gameFolder: gameFolder, width: surface.width, height: surface.height)
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
        let elapsed = UInt32(max(1, min(100, (now - lastTick) * 1000)))
        lastTick = now
        let tickStart = CACurrentMediaTime()
        defer { recordTickTime(since: tickStart) }
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
            _ = shiori_krkr_metal_present(Unmanaged.passUnretained(metalLayer).toOpaque(), texture, newFrame)
        }
    }

    /// Debug builds: how long each frame's tick and present take, logged every 300 frames.
    private func recordTickTime(since start: CFTimeInterval) {
        #if DEBUG
        tickTimes.append((CACurrentMediaTime() - start) * 1000)
        guard tickTimes.count == 300 else { return }
        let sorted = tickTimes.sorted()
        let average = sorted.reduce(0, +) / 300
        KiriKiriRuntime.log.notice("Frame ms avg \(average, format: .fixed(precision: 1)) p50 \(sorted[150], format: .fixed(precision: 1)) p95 \(sorted[285], format: .fixed(precision: 1)) max \(sorted[299], format: .fixed(precision: 1))")
        tickTimes.removeAll(keepingCapacity: true)
        #endif
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

    // MARK: Leaving

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil else { return }
        cancelPointer()
        let alert = UIAlertController(title: "Leave the game?", message: "Progress since your last save is lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
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
        ControllerInput.unsupportedGame = nil
        requestOrientations(.all)
        onExit()
    }

    private func requestOrientations(_ mask: UIInterfaceOrientationMask) {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    private func showControllerNotice() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Touch only", message: "This game doesn't support controllers. Tap to read on; two-finger tap opens the menu; hold two fingers to leave.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private final class KiriKiriMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
}

/// SwiftUI wrapper for presenting a KiriKiri game full screen.
struct KiriKiriGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> KiriKiriGameViewController {
        KiriKiriGameViewController(gameFolder: gameFolder, onExit: onExit)
    }

    func updateUIViewController(_ controller: KiriKiriGameViewController, context: Context) {}
}
