// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import AVFoundation
import CShioriKrkr
import GameController
import os
import SwiftUI
import UIKit

/// Which KiriKiri engine plays a game while both exist (Phase 23): AetherKrkr ("Standard",
/// the full edition's default) or Shiori's own, krkrsdl3-based one ("Shiori (Beta)"). Per game,
/// chosen on the game page and kept in iCloud Keychain with the other per-game choices; the
/// launch flag `-ShioriKrkrEngine shiori` (or `aether`) overrides every game.
enum KiriKiriEngineChoice: String, CaseIterable, Identifiable {
    case aether
    case shiori

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aether: "Standard"
        case .shiori: "Shiori (Beta)"
        }
    }

    @MainActor
    static func engine(for appID: UInt32) -> KiriKiriEngineChoice {
        if let forced = UserDefaults.standard.string(forKey: "ShioriKrkrEngine").flatMap(KiriKiriEngineChoice.init(rawValue:)) {
            return forced
        }
        return SyncedPreferences.usesShioriKrkr(appID: appID) ? .shiori : .aether
    }

    @MainActor
    static func set(_ engine: KiriKiriEngineChoice, for appID: UInt32) {
        SyncedPreferences.setShioriKrkr(engine == .shiori, appID: appID)
    }
}

/// ShioriKrkr's side in the app: loads the framework, prepares the game folder and starts it.
@MainActor
enum ShioriKrkrRuntime {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static let log = Logger(subsystem: "com.owencramer.vnhub", category: "ShioriKrkr")
    private static var api: UnsafePointer<shiorikrkr_api_t>?

    static func load() throws -> UnsafePointer<shiorikrkr_api_t> {
        if let api { return api }
        let path = Bundle.main.privateFrameworksPath.map { "\($0)/ShioriKrkr.framework/ShioriKrkr" } ?? ""
        var error = [CChar](repeating: 0, count: 512)
        guard let loaded = shiorikrkr_load(path, &error, UInt32(error.count)) else {
            log.error("Couldn't load ShioriKrkr: \(String(cString: error), privacy: .public)")
            throw Failure(errorDescription: "Shiori's KiriKiri engine couldn't load.")
        }
        api = loaded
        return loaded
    }

    /// The folder the engine opens: `base/` with `patch/` over it (LayeredGameRoot), its
    /// `savedata/` linked to the game's `saves/`, and Shiori's bundled Japanese font as the
    /// fallback `default.ttf` krkrsdl3 looks for. Rebuilt each launch.
    static func prepareRoot(gameFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let runner = URL.cachesDirectory.appendingPathComponent("ShioriKrkr/\(gameFolder.lastPathComponent)", isDirectory: true)
        let root = runner.appendingPathComponent("game", isDirectory: true)
        try? fileManager.removeItem(at: root)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let patch = gameFolder.appendingPathComponent("patch", isDirectory: true)
        try LayeredGameRoot.overlay(base: gameFolder.appendingPathComponent("base", isDirectory: true),
                                    patch: fileManager.fileExists(atPath: patch.path) ? patch : nil,
                                    into: root, skipping: ["savedata", "default.ttf"])
        let saves = gameFolder.appendingPathComponent("saves", isDirectory: true)
        try? fileManager.createDirectory(at: saves, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("savedata"), withDestinationURL: saves)
        if let font = Bundle.main.url(forResource: "BIZUDGothic-Regular", withExtension: "ttf", subdirectory: "SiglusFonts") {
            try? fileManager.createSymbolicLink(at: root.appendingPathComponent("default.ttf"), withDestinationURL: font)
        }
        return root
    }

    /// The PC executable's name (System.exeName); never opened.
    static func exeName(in root: URL) -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.lowercased().hasSuffix(".exe") }
            .first { !["unins", "steam", "setup", "config"].contains(where: $0.lowercased().contains) } ?? "game.exe"
    }

    static func start(gameFolder: URL, messages: ShioriKrkrGameViewController) throws -> UnsafePointer<shiorikrkr_api_t> {
        let api = try load()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let root = try prepareRoot(gameFolder: gameFolder)
        // GARbroDatabase.prepare put the game's CxDec scheme here before launch, if it has one.
        let scheme = URL.cachesDirectory.appendingPathComponent("KiriKiri/\(gameFolder.lastPathComponent)/scheme.shcx")
        let schemePath = FileManager.default.fileExists(atPath: scheme.path) ? scheme.path : nil
        let exe = exeName(in: root)
        let options = ["-render=software"]
        let context = Unmanaged.passUnretained(messages).toOpaque()
        let status: Int32 = root.path.withCString { rootPointer in
            exe.withCString { exePointer in
                withOptionalCString(schemePath) { schemePointer in
                    let cOptions = options.map { strdup($0) }
                    defer { cOptions.forEach { free($0) } }
                    var pointers = cOptions.map { UnsafePointer<CChar>($0) }
                    return pointers.withUnsafeMutableBufferPointer { buffer in
                        var config = shiorikrkr_config_t()
                        config.struct_size = UInt32(MemoryLayout<shiorikrkr_config_t>.size)
                        config.game_root = rootPointer
                        config.exe_name = exePointer
                        config.cx_scheme_path = schemePointer
                        config.arguments = UnsafePointer(buffer.baseAddress)
                        config.argument_count = UInt32(buffer.count)
                        config.log = { _, line in
                            guard let line else { return }
                            let text = String(cString: line)
                            ShioriKrkrRuntime.log.notice("\(text, privacy: .public)")
                        }
                        config.message = { context, text, caption, buttons, count in
                            guard let context else { return 0 }
                            let names = (0 ..< Int(count)).map { buttons?[$0].map { String(cString: $0) } ?? "OK" }
                            let message = text.map { String(cString: $0) } ?? ""
                            let title = caption.map { String(cString: $0) } ?? ""
                            return MainActor.assumeIsolated {
                                let controller = Unmanaged<ShioriKrkrGameViewController>.fromOpaque(context).takeUnretainedValue()
                                return controller.ask(message, title: title, buttons: names)
                            }
                        }
                        config.message_context = context
                        config.host_presents = 1
                        return api.pointee.start(&config)
                    }
                }
            }
        }
        guard status == Int32(SHIORIKRKR_OK) else {
            throw Failure(errorDescription: "The game couldn't start (\(status)).")
        }
        log.notice("Started \(gameFolder.lastPathComponent, privacy: .public) on ShioriKrkr")
        return api
    }

    private static func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }
}

/// Plays a KiriKiri game on ShioriKrkr. The engine composes each frame in software; Shiori
/// presents it with its own Metal (ShioriKrkrPresenter), MetalFX-upscaled where the setting is
/// on. Touch, trackpad, keyboard and controller follow the Standard engine's view: a tap is a
/// click, two fingers tap for the right button, hold to leave, swipe down for the backlog,
/// right to skip and up for auto.
final class ShioriKrkrGameViewController: UIViewController {
    private let gameFolder: URL
    private var onFirstFrame: (() -> Void)?
    private let onExit: () -> Void
    private var api: UnsafePointer<shiorikrkr_api_t>?
    private var presenter: ShioriKrkrPresenter?
    private var displayLink: CADisplayLink?
    private var ticking = false
    private var leaving = false
    private var lastSerial: UInt64 = 0
    private var frameSize: CGSize = .zero
    private weak var pointerTouch: UITouch?
    private var pointerButton = Int32(SHIORIKRKR_BUTTON_LEFT)
    private var padReader = GamePadReader()
    private var keyDownAt: [Int32: CFTimeInterval] = [:]
    private var skipLatched = false
    private var leaveAlert: UIAlertController?
    #if os(iOS)
    private var pointerHovering = false
    private var pointerLocation: CGPoint?
    private let cursorLayer = CALayer()
    private var cursorSerial: UInt32 = 0
    private var cursorKind: Int32 = 0
    private var cursorImageSize = CGSize.zero
    private var cursorHotspot = CGPoint.zero
    private var pointerInteraction: UIPointerInteraction?
    private var scrollSent: CGFloat = 0
    #endif

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void, onExit: @escaping () -> Void) {
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

    override func loadView() {
        let presenter = ShioriKrkrPresenter(upscaling: KiriKiriGameViewController.upscalingEnabled)
        self.presenter = presenter
        view = presenter.view
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let menu = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        menu.numberOfTouchesRequired = 2
        menu.cancelsTouchesInView = false
        view.addGestureRecognizer(menu)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        leave.cancelsTouchesInView = false
        view.addGestureRecognizer(leave)
        #if os(iOS)
        let history = view.addSwipe(.down, fingers: 2, target: self, action: #selector(scrollBack(_:)))
        history.cancelsTouchesInView = false
        view.addSwipe(.right, fingers: 2, target: self, action: #selector(swipedSkip)).cancelsTouchesInView = false
        view.addSwipe(.up, fingers: 2, target: self, action: #selector(swipedAuto)).cancelsTouchesInView = false
        view.addHover(target: self, action: #selector(hovered(_:)))
        view.addScroll(target: self, action: #selector(scrolled(_:)))
        let pointer = UIPointerInteraction(delegate: self)
        view.addInteraction(pointer)
        pointerInteraction = pointer
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000
        cursorLayer.contentsGravity = .resize
        view.layer.addSublayer(cursorLayer)
        #endif
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
        // While still in front: the game keeps its place and system data (the background save
        // syncs them).
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.savePlace(reason: "leaving the screen") }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        becomeFirstResponder()
        #endif
        OrientationLock.set(.landscape, in: view.window?.windowScene)
        // Start once the scene has turned, so SDL's (hidden) window is made landscape: the
        // pointer's coordinates are mapped through it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startIfNeeded() }
    }

    private func startIfNeeded() {
        guard api == nil, !leaving else { return }
        do {
            api = try ShioriKrkrRuntime.start(gameFolder: gameFolder, messages: self)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        // A message box waits in a nested run loop inside the engine, where this keeps firing:
        // don't enter the engine twice.
        guard let api, !leaving, !ticking else { return }
        ticking = true
        defer { ticking = false }
        if api.pointee.tick() == 0 {
            leave()
            return
        }
        var frame = shiorikrkr_frame_t()
        if api.pointee.frame(&frame) != 0, let pixels = frame.pixels {
            frameSize = CGSize(width: Int(frame.width), height: Int(frame.height))
            let isNew = frame.serial != lastSerial
            lastSerial = frame.serial
            presenter?.present(pixels: pixels, width: Int(frame.width), height: Int(frame.height),
                               pitch: Int(frame.pitch), changed: isNew)
            // The cover lifts on the first frame with something on it (the game's first
            // frames are black while its title loads).
            if frame.blank == 0, let lift = onFirstFrame {
                onFirstFrame = nil
                lift()
            }
        }
        #if os(iOS)
        syncCursor()
        layoutCursor()
        #endif
    }

    // MARK: Messages

    /// A message box the game shows, as an alert; the engine waits for the answer.
    func ask(_ message: String, title: String, buttons: [String]) -> Int32 {
        final class Answer { var index: Int32? }
        let answer = Answer()
        let alert = UIAlertController(title: title.isEmpty ? nil : title, message: message, preferredStyle: .alert)
        for (index, name) in buttons.enumerated() {
            alert.addAction(UIAlertAction(title: name, style: .default) { _ in answer.index = Int32(index) })
        }
        var top: UIViewController = self
        while let presented = top.presentedViewController { top = presented }
        guard top.viewIfLoaded?.window != nil else { return 0 }
        top.present(alert, animated: true)
        while answer.index == nil, !leaving {
            _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        return answer.index ?? -1
    }

    // MARK: Input

    /// Where the game sits in the view (aspect-fitted, as the presenter draws it).
    private var gameRect: CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return view.bounds }
        return AVMakeRect(aspectRatio: frameSize, insideRect: view.bounds)
    }

    /// krkrsdl3 maps its window's coordinates onto the game letterboxed the same way, so a
    /// point in the view goes over as a fraction of the view.
    private func normalized(_ point: CGPoint) -> (Float, Float) {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        return (Float(min(max(point.x / bounds.width, 0), 1)), Float(min(max(point.y / bounds.height, 0), 1)))
    }

    private func pointer(_ phase: Int32, _ point: CGPoint, button: Int32 = Int32(SHIORIKRKR_BUTTON_LEFT)) {
        guard let api else { return }
        let (x, y) = normalized(point)
        api.pointee.pointer(phase, x, y, button)
    }

    private func sendKey(_ code: Int32, down: Bool) {
        api?.pointee.key(code, down ? 1 : 0)
    }

    /// KAG reads a key's state when its press arrives, so a press is held for at least 0.1 s.
    private func press(_ code: Int32, down: Bool) {
        let now = CACurrentMediaTime()
        if down {
            keyDownAt[code] = now
        } else if let at = keyDownAt[code], now - at < 0.1 {
            keyDownAt[code] = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + (0.1 - (now - at))) { [weak self] in
                self?.sendKey(code, down: false)
            }
            return
        }
        sendKey(code, down: down)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if skipLatched {
            releaseSkipLatch()
            return
        }
        guard pointerTouch == nil, event?.allTouches?.count ?? 1 == 1, let touch = touches.first else { return }
        pointerTouch = touch
        pointerButton = Int32(SHIORIKRKR_BUTTON_LEFT)
        #if os(iOS)
        if touch.isPointer, let mask = event?.buttonMask {
            if mask.contains(.secondary) {
                pointerButton = Int32(SHIORIKRKR_BUTTON_RIGHT)
            } else if mask.contains(.button(3)) {
                pointerButton = Int32(SHIORIKRKR_BUTTON_MIDDLE)
            }
        }
        setHovering(touch.isPointer)
        if touch.isPointer { pointerLocation = touch.location(in: view) }
        #endif
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), touch.location(in: view), button: pointerButton)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointer(Int32(SHIORIKRKR_POINTER_MOVED), touch.location(in: view))
        #if os(iOS)
        if touch.isPointer { pointerLocation = touch.location(in: view) }
        #endif
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        pointer(Int32(SHIORIKRKR_POINTER_UP), touch.location(in: view), button: pointerButton)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A gesture took the touch over: release without clicking.
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        cancelPointer()
    }

    /// A second finger arrived: the first touch wasn't a click.
    private func cancelPointer() {
        guard let touch = pointerTouch else { return }
        pointerTouch = nil
        pointer(Int32(SHIORIKRKR_POINTER_CANCEL), touch.location(in: view), button: pointerButton)
    }

    @objc private func rightClick(_ gesture: UITapGestureRecognizer) {
        cancelPointer()
        releaseSkipLatch()
        let point = gesture.location(in: view)
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
        pointer(Int32(SHIORIKRKR_POINTER_UP), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
    }

    @objc private func scrollBack(_ gesture: UISwipeGestureRecognizer) {
        cancelPointer()
        let (x, y) = normalized(gesture.location(in: view))
        api?.pointee.wheel(1, x, y)
    }

    /// Ctrl held down by a two-finger swipe right: KAG skips while it's down, until the next
    /// touch lets it go.
    @objc private func swipedSkip() {
        cancelPointer()
        if skipLatched {
            releaseSkipLatch()
            return
        }
        skipLatched = true
        sendKey(0x11, down: true)
        GameNotice.show("Skipping. Tap to stop.", in: view)
    }

    private func releaseSkipLatch() {
        guard skipLatched else { return }
        skipLatched = false
        sendKey(0x11, down: false)
    }

    @objc private func swipedAuto() {
        cancelPointer()
        toggleAuto()
    }

    /// KAG's own auto mode (MainWindow's enterAutoMode / cancelAutoMode).
    private func toggleAuto() {
        let result = evaluate("""
            (typeof global.kag == "Object" && typeof kag.enterAutoMode == "Object") \
            ? (kag.autoMode ? (kag.cancelAutoMode(), "off") : (kag.enterAutoMode(), "on")) : "none"
            """)
        if result == "none" { GameNotice.show("This game turns Auto on with its own button.", in: view) }
    }

    #if os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    /// A hardware keyboard's keys go to the game as the PC's; Page Up turns the wheel (the
    /// backlog).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil || $0 == .keyboardPageUp }
        for key in keys {
            if key == .keyboardPageUp {
                let (x, y) = normalized(CGPoint(x: gameRect.midX, y: gameRect.midY))
                api?.pointee.wheel(1, x, y)
            }
            if let code = key.windowsVirtualKey { press(code, down: true) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil }
        for key in keys { if let code = key.windowsVirtualKey { press(code, down: false) } }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != pointerHovering else { return }
        pointerHovering = hovering
        pointerInteraction?.invalidate()
        if !hovering { cursorLayer.isHidden = true }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        if recognizer.state == .ended || recognizer.state == .cancelled {
            pointerLocation = nil
            cursorLayer.isHidden = true
            return
        }
        guard pointerTouch == nil else { return }
        setHovering(true)
        pointerLocation = recognizer.location(in: view)
        pointer(Int32(SHIORIKRKR_POINTER_MOVED), recognizer.location(in: view))
    }

    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { scrollSent = 0 }
        guard recognizer.state == .changed else { return }
        let travel = recognizer.translation(in: view).y - scrollSent
        let steps = (travel / 30).rounded(.towardZero)
        guard steps != 0 else { return }
        scrollSent += steps * 30
        let (x, y) = normalized(recognizer.location(in: view))
        api?.pointee.wheel(Float(steps), x, y)
    }

    // MARK: Game cursor

    /// Picks up the cursor the game set (a .cur/.ani file, decoded by the engine).
    private func syncCursor() {
        guard pointerHovering, let api else { return }
        var pixels: UnsafePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0, hotX: Int32 = 0, hotY: Int32 = 0, kind: Int32 = 0
        let serial = api.pointee.cursor(&pixels, &width, &height, &hotX, &hotY, &kind)
        guard serial != cursorSerial else { return }
        cursorSerial = serial
        if kind == 1, let pixels, width > 0, height > 0,
           let provider = CGDataProvider(data: Data(bytes: pixels, count: Int(width * height * 4)) as CFData),
           let image = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        {
            cursorLayer.contents = image
            cursorImageSize = CGSize(width: Int(width), height: Int(height))
            cursorHotspot = CGPoint(x: Int(hotX), y: Int(hotY))
        } else if kind == 1 {
            kind = 0
        }
        if kind != cursorKind {
            cursorKind = kind
            pointerInteraction?.invalidate()
        }
    }

    /// The game's cursor at the pointer, at the size the game draws it.
    private func layoutCursor() {
        guard let location = pointerLocation, pointerHovering, cursorKind == 1,
              frameSize.width > 0, cursorImageSize.width > 0
        else {
            cursorLayer.isHidden = true
            return
        }
        let scale = gameRect.width / frameSize.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = CGRect(x: location.x - cursorHotspot.x * scale, y: location.y - cursorHotspot.y * scale,
                                   width: cursorImageSize.width * scale, height: cursorImageSize.height * scale)
        cursorLayer.isHidden = false
        CATransaction.commit()
    }
    #endif

    // MARK: Controller

    /// What KAG games answer to on a PC: Enter reads on and presses the focused button, the
    /// arrows move between buttons, a right click opens the menu, the wheel the backlog, Ctrl
    /// held skips, Escape cancels.
    private func pad(_ pad: GCExtendedGamepad) {
        if let alert = leaveAlert, presentedViewController === alert {
            for (button, down) in padReader.read(pad) where down {
                if button == .a {
                    alert.dismiss(animated: true) { [weak self] in
                        self?.savePlace(reason: "leaving the game")
                        self?.leave()
                    }
                } else if button == .b {
                    alert.dismiss(animated: true)
                }
            }
            return
        }
        guard api != nil, presentedViewController == nil else {
            padReader.absorb(pad)
            return
        }
        for (button, down) in padReader.read(pad) {
            switch button {
            case .up: press(0x26, down: down)
            case .down: press(0x28, down: down)
            case .left: press(0x25, down: down)
            case .right: press(0x27, down: down)
            case .a: press(0x0D, down: down)
            case .rb: press(0x11, down: down)
            case .menu: press(0x1B, down: down)
            case .b where down:
                let point = CGPoint(x: gameRect.midX, y: gameRect.midY)
                pointer(Int32(SHIORIKRKR_POINTER_DOWN), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
                pointer(Int32(SHIORIKRKR_POINTER_UP), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
            case .y where down, .lb where down:
                let (x, y) = normalized(CGPoint(x: gameRect.midX, y: gameRect.midY))
                api?.pointee.wheel(1, x, y)
            case .x where down:
                toggleAuto()
            case .options where down:
                presentLeaveQuestion()
            default:
                break
            }
        }
    }

    // MARK: Leaving

    @objc private func askToLeave(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }
        cancelPointer()
        presentLeaveQuestion()
    }

    private func presentLeaveQuestion() {
        guard presentedViewController == nil else { return }
        let kept = evaluate(Self.canKeepPlaceTJS) == "1" ? "Your place is kept." : "Progress since your last save is lost."
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
        let alert = UIAlertController(title: "This game couldn't start", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        displayLink?.invalidate()
        displayLink = nil
        releaseSkipLatch()
        api?.pointee.stop()
        ControllerInput.gameReceiver = nil
        OrientationLock.set(.all, in: view.window?.windowScene)
        onExit()
    }

    // MARK: Keeping the place

    /// Runs TJS in the game between ticks; nil if it can't now or threw.
    private func evaluate(_ tjs: String) -> String? {
        guard let api, !ticking, !leaving else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let status = api.pointee.eval(tjs, &buffer, UInt32(buffer.count))
        guard status == 0 else {
            ShioriKrkrRuntime.log.error("TJS didn't run (\(status)): \(String(cString: buffer), privacy: .public)")
            return nil
        }
        return String(cString: buffer)
    }

    /// Whether the game can keep its place now: KAG games with NEKO WORKs' emergency resume,
    /// in the story, where the game allows a bookmark.
    private static let canKeepPlaceTJS = """
        (typeof global.kag == "Object" && typeof global.checkEmergencySaveData == "Object" \
        && typeof global.inGameState == "Object" && typeof kag.getBookMarkFileNameBySystem == "Object" \
        && inGameState(kag) && (typeof kag.canStore != "Object" || kag.canStore())) ? 1 : 0
        """

    /// Keeps the game's place in its own format as the app leaves the screen or the player
    /// leaves the game, as the Standard engine's view does: the game's "emergency" resume
    /// bookmark where it has one (written beside it, then renamed into place), and KAG's
    /// system data (settings, read text, the bookmark index) in every KAG game.
    private func savePlace(reason: String) {
        let tjs = """
            (function() {
                if (typeof global.kag != "Object" || !isvalid kag) return "none";
                var result = "system";
                if (\(Self.canKeepPlaceTJS)) {
                    var temp = kag.getBookMarkFileNameBySystem("emergency-shiori");
                    var file = kag.getBookMarkFileNameBySystem("emergency");
                    result = kag.saveBookMarkToFile(temp) ? "kept\\t" + Storages.getLocalName(temp) + "\\t" + Storages.getLocalName(file) : "failed";
                } else if (typeof global.checkEmergencySaveData == "Object" && typeof kag.getBookMarkFileNameBySystem == "Object") {
                    result = "outside\\t" + Storages.getLocalName(kag.getBookMarkFileNameBySystem("emergency"));
                }
                if (typeof kag.saveSystemVariables == "Object") kag.saveSystemVariables();
                return result;
            })()
            """
        guard let result = evaluate(tjs) else { return }
        let parts = result.components(separatedBy: "\t")
        switch parts.first {
        case "kept" where parts.count == 3:
            if Darwin.rename(parts[1], parts[2]) == 0 {
                ShioriKrkrRuntime.log.notice("Kept the place and system data, \(reason, privacy: .public)")
            } else {
                ShioriKrkrRuntime.log.error("Couldn't move the resume bookmark into place (\(errno)), \(reason, privacy: .public)")
            }
        case "outside" where parts.count == 2:
            let size = (try? FileManager.default.attributesOfItem(atPath: parts[1]))?[.size] as? Int ?? 0
            if size > 64 { _ = evaluate(#"[].save(kag.getBookMarkFileNameBySystem("emergency"))"#) }
            ShioriKrkrRuntime.log.notice("Wrote the system data (outside the story), \(reason, privacy: .public)")
        default:
            ShioriKrkrRuntime.log.notice("Wrote the system data (\(result, privacy: .public)), \(reason, privacy: .public)")
        }
    }
}

#if os(iOS)
extension ShioriKrkrGameViewController: UIPointerInteractionDelegate {
    /// The iPad's pointer hides while the game draws its own cursor.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        cursorKind == 0 ? nil : .hidden()
    }
}
#endif

/// SwiftUI wrapper for presenting a KiriKiri game on ShioriKrkr full screen.
struct ShioriKrkrGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> ShioriKrkrGameViewController {
        ShioriKrkrGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: ShioriKrkrGameViewController, context: Context) {}
}
