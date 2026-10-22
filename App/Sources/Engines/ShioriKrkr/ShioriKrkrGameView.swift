// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import AVFoundation
import CKiriKit
import GameController
import Metal
import os
import KiriKit
import SwiftUI
import UIKit

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
    /// fallback `default.ttf` the engine looks for. Rebuilt each launch.
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

    /// The app ID in a library folder's name ("<app ID>-<name>"), 0 when it has none.
    static func folderAppID(_ folder: URL) -> UInt32 {
        folder.lastPathComponent.split(separator: "-").first.flatMap { UInt32($0) } ?? 0
    }

    /// What Shiori says when the engine can't open a game yet.
    static let unsupportedTitle = "This Game Doesn't Run on Shiori Yet"
    static let unsupportedMessage = "Its archives are encrypted in a way Shiori can't open."

    /// Whether the engine can open the game (its archives' encryption); checked before
    /// starting so the player sees Shiori's message rather than the game's decoy error.
    static func canOpen(gameFolder: URL, appID: UInt32) -> Bool {
        let scheme = URL.cachesDirectory.appendingPathComponent("KiriKiri/\(gameFolder.lastPathComponent)/scheme.shcx")
        let hasScheme = FileManager.default.fileExists(atPath: scheme.path) || GARbroDatabase.title(appID: appID) != nil
        return blocked(gameFolder: gameFolder, appID: appID, hasScheme: hasScheme) == false
    }

    private static func blocked(gameFolder: URL, appID: UInt32?, hasScheme: Bool) -> Bool {
        switch KiriKiriArchiveCheck.shioriEngineBlocker(base: gameFolder.appendingPathComponent("base", isDirectory: true),
                                                        hasScheme: hasScheme) {
        case nil: return false
        case .hx:
            // Hx titles whose index keys GARbro's database has (GARbroDatabase.hxPlayable).
            let id = appID.flatMap { $0 == 0 ? nil : $0 } ?? folderAppID(gameFolder)
            return !GARbroDatabase.hxPlayable(appID: id)
        // NEKO WORKs archives (neko, eliF) open with the key read from the archives themselves.
        case .nekoWorks: return false
        case .cxWithoutScheme: return true
        }
    }

    /// The engine's log for the current game, `logs/shiori-engine.log` in the game's folder (so
    /// it can be shared from the Files app when something goes wrong on a device); replaced
    /// each launch.
    nonisolated(unsafe) static var engineLog: FileHandle?

    /// Shiori's E-mote player for the engine (NEKOPARA's characters); the engine copies it.
    static var emoteTable = KrkrEmoteHost.makeTable()

    private static func openEngineLog(gameFolder: URL) {
        try? engineLog?.close()
        let folder = gameFolder.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("shiori-engine.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        engineLog = try? FileHandle(forWritingTo: file)
        let device = UIDevice.current
        engineLog?.write(Data("Shiori \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")), \(device.model) \(device.systemName) \(device.systemVersion)\n".utf8))
        for folder in ["base", "patch"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: gameFolder.appendingPathComponent(folder).path))?.sorted() ?? []
            engineLog?.write(Data("\(folder)/: \(names.joined(separator: ", "))\n".utf8))
        }
    }

    static func start(gameFolder: URL, messages: ShioriKrkrGameViewController) throws -> UnsafePointer<shiorikrkr_api_t> {
        openEngineLog(gameFolder: gameFolder)
        let scheme = URL.cachesDirectory.appendingPathComponent("KiriKiri/\(gameFolder.lastPathComponent)/scheme.shcx")
        if blocked(gameFolder: gameFolder, appID: nil, hasScheme: FileManager.default.fileExists(atPath: scheme.path)) {
            throw Failure(errorDescription: unsupportedMessage)
        }
        let api = try load()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let root = try prepareRoot(gameFolder: gameFolder)
        // GARbroDatabase.prepare put the game's CxDec scheme here before launch, if it has one.
        let schemePath = FileManager.default.fileExists(atPath: scheme.path) ? scheme.path : nil
        let exe = exeName(in: root)
        let options: [String] = []
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
                            ShioriKrkrRuntime.engineLog?.write(Data((text + "\n").utf8))
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
                        return withUnsafePointer(to: &ShioriKrkrRuntime.emoteTable) { emote in
                            config.emote = emote
                            return api.pointee.start(&config)
                        }
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

/// Plays a KiriKiri game on ShioriKrkr. The engine composes each frame on the GPU with
/// Metal and hands over the texture; Shiori presents it (ShioriKrkrPresenter), MetalFX-upscaled
/// where the setting is on. A tap is a click, two fingers tap for the right button, hold to
/// leave, swipe down for the backlog, right to skip and up for auto.
final class ShioriKrkrGameViewController: UIViewController {
    /// Settings › Engines: KiriKiri frames (1280×720 in most games) are enlarged to the screen
    /// with MetalFX instead of the Catmull-Rom shader. Read when a game starts.
    static var upscalingEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "kirikiriMetalFXUpscaling") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "kirikiriMetalFXUpscaling") }
    }

    private let gameFolder: URL
    private var onFirstFrame: (() -> Void)?
    private let onExit: () -> Void
    private var api: UnsafePointer<shiorikrkr_api_t>?
    private var presenter: ShioriKrkrPresenter?
    private var displayLink: CADisplayLink?
    private var ticking = false
    private var leaving = false
    private var lastSerial: UInt64 = 0
    #if DEBUG
    /// `-ShioriKrkrEval "<seconds>|<TJS>;;<seconds>|<TJS>"`: TJS run that many seconds after the
    /// game starts (testing movies and scenes in the simulator).
    private lazy var debugEvals: [(at: CFTimeInterval, tjs: String)] = (UserDefaults.standard.string(forKey: "ShioriKrkrEval") ?? "")
        .components(separatedBy: ";;").compactMap { item in
            let parts = item.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let at = Double(parts[0]) else { return nil }
            return (at, String(parts[1]))
        }
    private var startedAt: CFTimeInterval = 0
    private var leaveScheduled = false
    #endif
    private var frameSize: CGSize = .zero
    private weak var pointerTouch: UITouch?
    private var pointerButton = Int32(SHIORIKRKR_BUTTON_LEFT)
    /// Fingers on the view and the ids the game knows them by (touch events, beside the pointer).
    private var fingerIDs: [ObjectIdentifier: Int32] = [:]
    private var nextFingerID: Int32 = 1
    private var padReader = GamePadReader()
    /// Keys the controller holds down in the game (let go when an alert takes the controller).
    private var padKeys: Set<Int32> = []
    private var keyDownAt: [Int32: CFTimeInterval] = [:]
    private var skipLatched = false
    /// Laptop mode's Backlog opened the game's backlog with the wheel; the next press closes it.
    fileprivate var laptopOpenedBacklog = false
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
        let presenter = ShioriKrkrPresenter(upscaling: Self.upscalingEnabled)
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
        LaptopPad.shared.game = self
        let pointer = UIPointerInteraction(delegate: self)
        view.addInteraction(pointer)
        pointerInteraction = pointer
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000
        cursorLayer.contentsGravity = .resize
        view.layer.addSublayer(cursorLayer)
        #endif
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
        // While still in front: the game writes its system data (settings, read text); the
        // background save syncs it.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSystemData(reason: "leaving the screen") }
        }
        #if DEBUG
        // `-ShioriKiriKiriInput "20:skip;30:auto;40:pageup"`: the
        // shared gestures (`skip`, `auto`, `backlog`, `menu`, `tap`) and keys (`pageup`,
        // `enter`) at seconds from launch.
        for step in (UserDefaults.standard.string(forKey: "ShioriKiriKiriInput") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let name = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                ShioriKrkrRuntime.log.notice("Debug input \(name, privacy: .public)")
                switch name {
                case "skip": self.swipedSkip()
                case "auto": self.swipedAuto()
                case "backlog", "pageup": self.wheelUp()
                case "menu": self.rightClickMiddle()
                case "enter":
                    self.press(0x0D, down: true)
                    self.press(0x0D, down: false)
                case "tap": self.releaseSkipLatch()
                // The audio session's notifications, as a route change (a controller taking the
                // sound and giving it back), a call or Siri, and a media-services reset post them.
                case "route":
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
                        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
                case "routeback":
                    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
                        AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
                case "interrupt":
                    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
                case "resume":
                    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: nil, userInfo: [
                        AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
                case "mediareset":
                    NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
                default: break
                }
            }
        }
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        becomeFirstResponder()
        #endif
        OrientationLock.set(.landscape, in: view.window?.windowScene)
        // Start once the scene has turned to landscape.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startIfNeeded() }
    }

    private func startIfNeeded() {
        guard api == nil, !leaving else { return }
        // The game opens on its title: no emergency bookmark for it to load by itself.
        if let line = KiriKiriSaves.prepareForStart(gameFolder: gameFolder) {
            ShioriKrkrRuntime.log.notice("\(line, privacy: .public)")
        }
        do {
            api = try ShioriKrkrRuntime.start(gameFolder: gameFolder, messages: self)
        } catch {
            fail(error.localizedDescription)
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        // A steady 60 (KiriKiri's own rate): a range down to 30 let ProMotion run the game at 40.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        // A message box waits in a nested run loop inside the engine, where this keeps firing:
        // don't enter the engine twice.
        guard let api, !leaving, !ticking else { return }
        ticking = true
        defer { ticking = false }
        let tickStart = CACurrentMediaTime()
        defer { noteTick(CACurrentMediaTime() - tickStart) }
        if api.pointee.tick() == 0 {
            leave()
            return
        }
        #if DEBUG
        if startedAt == 0 { startedAt = CACurrentMediaTime() }
        // `-ShioriKrkrLeaveAfter <seconds>`: leaves as the two-finger hold's Leave does.
        let leaveAfter = UserDefaults.standard.double(forKey: "ShioriKrkrLeaveAfter")
        if leaveAfter > 0, CACurrentMediaTime() - startedAt >= leaveAfter, !leaveScheduled {
            leaveScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.saveSystemData(reason: "leaving the game")
                self?.leave()
            }
        }
        while let next = debugEvals.first, CACurrentMediaTime() - startedAt >= next.at {
            debugEvals.removeFirst()
            var buffer = [CChar](repeating: 0, count: 1024)
            let status = api.pointee.eval(next.tjs, &buffer, UInt32(buffer.count))
            ShioriKrkrRuntime.log.notice("Debug eval [\(status)] \(String(cString: buffer), privacy: .public)")
        }
        #endif
        var frame = shiorikrkr_frame_t()
        if api.pointee.frame(&frame) != 0, frame.pixels != nil || frame.texture != nil {
            frameSize = CGSize(width: Int(frame.width), height: Int(frame.height))
            let isNew = frame.serial != lastSerial
            lastSerial = frame.serial
            if let texture = frame.texture {
                let event = frame.event.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? MTLSharedEvent }
                presenter?.present(texture: Unmanaged<AnyObject>.fromOpaque(texture).takeUnretainedValue() as! MTLTexture,
                                   event: event ?? nil, value: frame.event_value, width: Int(frame.width),
                                   height: Int(frame.height), changed: isNew)
            } else if let pixels = frame.pixels {
                presenter?.present(pixels: pixels, width: Int(frame.width), height: Int(frame.height),
                                   pitch: Int(frame.pitch), changed: isNew)
            }
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

    // MARK: Frame statistics

    private var statsStart: CFTimeInterval = 0
    private var statsTicks = 0
    private var statsTickTime: CFTimeInterval = 0, statsTickWorst: CFTimeInterval = 0, statsSlow = 0
    private var statsLastTick: CFTimeInterval = 0, statsGapWorst: CFTimeInterval = 0

    /// Every 10 seconds, a line in the engine's log (logs/shiori-engine.log): how long the
    /// engine's ticks took, how often the display link came, and what the presenter showed.
    private func noteTick(_ took: CFTimeInterval) {
        let now = CACurrentMediaTime()
        if statsStart == 0 { statsStart = now }
        if statsLastTick > 0 { statsGapWorst = max(statsGapWorst, now - statsLastTick) }
        statsLastTick = now
        statsTicks += 1
        statsTickTime += took
        statsTickWorst = max(statsTickWorst, took)
        if took > 1.0 / 60 { statsSlow += 1 }
        let span = now - statsStart
        guard span >= 10, let presenter else { return }
        let shown = presenter.takeStatistics()
        let line = String(format: "Shiori frames (%.0f s): %d ticks (%.1f/s), engine %.2f ms avg, %.1f ms worst, %d over 16.7 ms; "
                          + "longest gap %.1f ms; shown %.1f/s (%.1f/s new), presenter drawable wait %.2f ms/frame (off the engine thread), %d frames replaced before shown",
                          span, statsTicks, Double(statsTicks) / span, statsTickTime * 1000 / Double(max(statsTicks, 1)),
                          statsTickWorst * 1000, statsSlow, statsGapWorst * 1000, Double(shown.shown) / span,
                          Double(shown.new) / span, shown.drawableWait * 1000 / Double(max(shown.shown, 1)), shown.skipped)
        ShioriKrkrRuntime.engineLog?.write(Data((line + "\n").utf8))
        ShioriKrkrRuntime.log.notice("\(line, privacy: .public)")
        statsStart = now
        statsTicks = 0
        statsSlow = 0
        statsTickTime = 0
        statsTickWorst = 0
        statsGapWorst = 0
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

    /// A point in the view as a fraction of the game's frame (where the presenter draws it).
    private func normalized(_ point: CGPoint) -> (Float, Float) {
        let rect = gameRect
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        return (Float(min(max((point.x - rect.minX) / rect.width, 0), 1)),
                Float(min(max((point.y - rect.minY) / rect.height, 0), 1)))
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

    /// Each finger as a touch for games that turned touch on (as Windows sends a touchscreen's
    /// fingers to KiriKiri, beside the mouse events): phase 0 down, 1 moved, 2 up.
    private func sendFingers(_ touches: Set<UITouch>, phase: Int32) {
        guard let api else { return }
        for touch in touches {
            #if os(iOS)
            if touch.isPointer { continue }
            #endif
            let key = ObjectIdentifier(touch)
            let id: Int32
            if let known = fingerIDs[key] {
                id = known
            } else {
                guard phase == 0 else { continue }
                id = nextFingerID
                nextFingerID = nextFingerID % 1000 + 1
                fingerIDs[key] = id
            }
            if phase == 2 { fingerIDs[key] = nil }
            let (x, y) = normalized(touch.location(in: view))
            api.pointee.touch(phase, x, y, id)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A tap that lets go of the skip latch is the app's, not the game's (no finger, no click).
        if skipLatched {
            releaseSkipLatch()
            return
        }
        sendFingers(touches, phase: 0)
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
        sendFingers(touches, phase: 1)
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointer(Int32(SHIORIKRKR_POINTER_MOVED), touch.location(in: view))
        #if os(iOS)
        if touch.isPointer { pointerLocation = touch.location(in: view) }
        #endif
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendFingers(touches, phase: 2)
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        pointer(Int32(SHIORIKRKR_POINTER_UP), touch.location(in: view), button: pointerButton)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendFingers(touches, phase: 2)
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

    /// Auto as the PC game's menu turns it on: the main window's Auto menu item (KAG's
    /// autoModeMenuItem, or the first item whose caption says "自動", "オート" or "auto"), which
    /// works whether the game shows its menu bar or not and runs the game's own handler. Games
    /// without one fall back to KAG's enterAutoMode / cancelAutoMode.
    private func toggleAuto() {
        let result = evaluate(Self.autoTJS)
        ShioriKrkrRuntime.log.notice("Auto: \(result ?? "not run", privacy: .public)")
        if result == "none" { GameNotice.show("This game turns Auto on with its own button.", in: view) }
    }

    private static let autoTJS = """
        (function() {
            if (typeof global.kag != "Object" || !isvalid kag) return "none";
            var match = function(item) {
                var caption = ("" + item.caption).toLowerCase();
                return caption.indexOf("自動") >= 0 || caption.indexOf("オート") >= 0 || caption.indexOf("auto") >= 0;
            };
            var found = void;
            if (typeof kag.autoModeMenuItem == "Object" && kag.autoModeMenuItem !== null && isvalid kag.autoModeMenuItem) {
                found = kag.autoModeMenuItem;
            } else {
                var stack = [];
                try {
                    var top = kag.menu.children;
                    for (var i = top.count - 1; i >= 0; i--) stack.add(top[i]);
                } catch (e) {}
                while (stack.count > 0 && found === void) {
                    var item = stack[stack.count - 1];
                    stack.count = stack.count - 1;
                    if (match(item)) { found = item; break; }
                    var children = item.children;
                    for (var j = children.count - 1; j >= 0; j--) stack.add(children[j]);
                }
            }
            if (found !== void) {
                if (!found.enabled) return "disabled";
                found.fireClick();
                return "menu";
            }
            if (typeof kag.enterAutoMode != "Object") return "none";
            if (kag.autoMode) { kag.cancelAutoMode(); return "off"; }
            kag.enterAutoMode();
            return "on";
        })()
        """

    /// The wheel turned up at the middle of the game (the backlog).
    private func wheelUp() {
        cancelPointer()
        let (x, y) = normalized(CGPoint(x: gameRect.midX, y: gameRect.midY))
        api?.pointee.wheel(1, x, y)
    }

    /// A right click at the middle of the game (the menu, or back).
    private func rightClickMiddle() {
        cancelPointer()
        let point = CGPoint(x: gameRect.midX, y: gameRect.midY)
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
        pointer(Int32(SHIORIKRKR_POINTER_UP), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
    }

    #if os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    /// A hardware keyboard's keys go to the game as the PC's; Page Up turns the wheel (the
    /// backlog).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil || $0 == .keyboardPageUp }
        for key in keys {
            // A key ends a touch's press without a click.
            cancelPointer()
            if key == .keyboardPageUp { wheelUp() }
            if let code = key.windowsVirtualKey { press(code, down: true) }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { $0.windowsVirtualKey != nil }
        for key in keys {
            guard let code = key.windowsVirtualKey else { continue }
            cancelPointer()
            press(code, down: false)
        }
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
        guard pointerTouch == nil, recognizer.state == .began || recognizer.state == .changed else { return }
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
            releasePadKeys()
            for (button, down) in padReader.read(pad) where down {
                if button == .a {
                    alert.dismiss(animated: true) { [weak self] in
                        self?.saveSystemData(reason: "leaving the game")
                        self?.leave()
                    }
                } else if button == .b {
                    alert.dismiss(animated: true)
                }
            }
            return
        }
        guard api != nil, presentedViewController == nil else {
            // A game's message box (or another alert) has the controller: let go of what the
            // controller held in the game, and ignore buttons until they come back up.
            releasePadKeys()
            padReader.absorb(pad)
            return
        }
        for (button, down) in padReader.read(pad) {
            // A button ends a touch's press without a click.
            if down { cancelPointer() }
            switch button {
            case .up: padKey(0x26, down: down) // VK_UP
            case .down: padKey(0x28, down: down) // VK_DOWN
            case .left: padKey(0x25, down: down) // VK_LEFT
            case .right: padKey(0x27, down: down) // VK_RIGHT
            case .a: padKey(0x0D, down: down) // VK_RETURN
            case .rb: padKey(0x11, down: down) // VK_CONTROL: skip while held (R1 or R2)
            case .menu: padKey(0x1B, down: down) // VK_ESCAPE
            case .b where down: rightClickMiddle()
            case .y where down, .lb where down: wheelUp()
            case .x where down: toggleAuto()
            case .options where down:
                // Nothing stays held in the game behind the question.
                releasePadKeys()
                presentLeaveQuestion()
            default:
                break
            }
        }
    }

    /// A key the controller presses or lets go (held arrows repeat: presses with no release).
    private func padKey(_ code: Int32, down: Bool) {
        if down { padKeys.insert(code) } else if padKeys.remove(code) == nil { return }
        press(code, down: down)
    }

    private func releasePadKeys() {
        for code in padKeys { press(code, down: false) }
        padKeys.removeAll()
    }

    // MARK: Leaving

    @objc private func askToLeave(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }
        cancelPointer()
        presentLeaveQuestion()
    }

    private func presentLeaveQuestion() {
        guard presentedViewController == nil else { return }
        // Only the game's own saves are kept.
        let lost = "Progress since your last save is lost."
        let message = GCController.current?.extendedGamepad != nil ? lost + " Ⓐ Leave, Ⓑ Keep Playing." : lost
        let alert = UIAlertController(title: "Leave the game?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in
            self?.saveSystemData(reason: "leaving the game")
            self?.leave()
        })
        leaveAlert = alert
        present(alert, animated: true)
    }

    private func fail(_ message: String) {
        let title = message == ShioriKrkrRuntime.unsupportedMessage ? ShioriKrkrRuntime.unsupportedTitle : "This Game Couldn't Start"
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
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

    // MARK: System data

    /// Runs TJS in the game between ticks; nil if it can't now or threw.
    private func evaluate(_ tjs: String, capacity: Int = 4096) -> String? {
        guard let api, !ticking, !leaving else { return nil }
        var buffer = [CChar](repeating: 0, count: capacity)
        let status = api.pointee.eval(tjs, &buffer, UInt32(buffer.count))
        guard status == 0 else {
            ShioriKrkrRuntime.log.error("TJS didn't run (\(status)): \(String(cString: buffer), privacy: .public)")
            return nil
        }
        return String(cString: buffer)
    }

    /// Writes KAG's system data (settings, read text) as the app leaves the screen or the
    /// player leaves the game. No bookmark: the player's place is only in the game's own saves.
    private func saveSystemData(reason: String) {
        guard let result = evaluate(KiriKiriSaves.systemDataTJS) else { return }
        ShioriKrkrRuntime.log.notice("System data: \(result, privacy: .public), \(reason, privacy: .public)")
    }
}

#if os(iOS)
extension ShioriKrkrGameViewController: UIPointerInteractionDelegate {
    /// The iPad's pointer hides while the game draws its own cursor in its place (or the game
    /// hid the cursor), as the PC build replaces Windows's.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard pointerHovering, cursorKind != 0 else { return nil }
        return .hidden()
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

#if os(iOS)
/// Laptop mode's trackpad and controls, as the PC's mouse and the shared gestures.
extension ShioriKrkrGameViewController: LaptopInput {
    /// The game's own cursor follows, as it does for a trackpad.
    func laptopPointer(at point: CGPoint) -> Bool {
        guard pointerTouch == nil else { return false }
        setHovering(true)
        pointerLocation = point
        pointer(Int32(SHIORIKRKR_POINTER_MOVED), point)
        syncCursor()
        layoutCursor()
        return cursorKind == 1
    }

    func laptopClick(at point: CGPoint) {
        cancelPointer()
        if skipLatched {
            releaseSkipLatch()
            return
        }
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), point)
        pointer(Int32(SHIORIKRKR_POINTER_UP), point)
    }

    func laptopSecondaryClick(at point: CGPoint) {
        cancelPointer()
        releaseSkipLatch()
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
        pointer(Int32(SHIORIKRKR_POINTER_UP), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
    }

    func laptopScroll(_ steps: Int, at point: CGPoint) {
        cancelPointer()
        let (x, y) = normalized(point)
        api?.pointee.wheel(Float(steps), x, y)
    }

    func laptopSkip() { swipedSkip() }
    func laptopAuto() { swipedAuto() }

    /// KAG's history layer when it's open closes; otherwise the wheel opens the game's backlog
    /// (its own or KAG's), and the next press closes it with the right button, as on the PC.
    func laptopBacklog() {
        cancelPointer()
        if evaluate(Self.closeHistoryTJS) == "closed" {
            laptopOpenedBacklog = false
            return
        }
        if laptopOpenedBacklog {
            laptopOpenedBacklog = false
            rightClickMiddle()
        } else {
            laptopOpenedBacklog = true
            wheelUp()
        }
    }

    private static let closeHistoryTJS = """
        (function() {
            if (typeof global.kag != "Object" || !isvalid kag) return "none";
            if (typeof kag.historyShowing != "undefined" && kag.historyShowing && typeof kag.hideHistory == "Object") {
                kag.hideHistory();
                return "closed";
            }
            return "shut";
        })()
        """

    /// The PC build's menu bar (KAG's `kag.menu`), which games keep even when they hide the bar:
    /// one line per visible item, depth first, as `path<TAB>depth<TAB>caption<TAB>enabled<TAB>checked`.
    func laptopMenuItems() -> [LaptopMenuItem]? {
        guard let listing = evaluate(Self.menuTJS, capacity: 65536), !listing.isEmpty else { return nil }
        var roots: [LaptopMenuItem] = []
        var stack: [LaptopMenuItem] = []
        var depths: [Int] = []
        var skipping: Int?
        func pop() {
            let item = stack.removeLast()
            depths.removeLast()
            if stack.isEmpty { roots.append(item) } else { stack[stack.count - 1].children.append(item) }
        }
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 5, let depth = Int(fields[1]) else { continue }
            while let last = depths.last, last >= depth { pop() }
            let path = fields[0].split(separator: "/").compactMap { Int($0) }
            // A single character on the bar itself ("x", "+") is a glyph button on the PC's
            // menu bar, not a command anyone could choose by name.
            let title = Self.menuTitle(String(fields[2]))
            if depth == 0, title.count <= 1 { skipping = depth; continue }
            if let skip = skipping, depth > skip { continue }
            skipping = nil
            stack.append(LaptopMenuItem(id: path, title: title,
                                        enabled: fields[3] == "1", checked: fields[4] == "1"))
            depths.append(depth)
        }
        while !stack.isEmpty { pop() }
        return roots.isEmpty ? nil : roots
    }

    func laptopChoose(_ item: LaptopMenuItem) {
        let path = item.id.map(String.init).joined(separator: ",")
        let result = evaluate("""
            (function() {
                var item = kag.menu, path = [\(path)];
                for (var i = 0; i < path.count; i++) item = item.children[path[i]];
                if (!item.enabled) return "disabled";
                item.fireClick();
                return "clicked";
            })()
            """)
        ShioriKrkrRuntime.log.notice("Menu \(item.title, privacy: .public): \(result ?? "not run", privacy: .public)")
    }

    /// A Windows menu caption without its access key: "セーブ(&S)" → "セーブ", "&Load" → "Load".
    private static func menuTitle(_ caption: String) -> String {
        var title = caption.replacingOccurrences(of: #"\(&.\)"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "&&", with: "\u{1}").replacingOccurrences(of: "&", with: "")
        return title.replacingOccurrences(of: "\u{1}", with: "&").trimmingCharacters(in: .whitespaces)
    }

    /// Depth first without recursion (TJS's anonymous functions don't close over locals).
    private static let menuTJS = """
        (function() {
            if (typeof global.kag != "Object" || !isvalid kag) return "";
            var out = [], items = [], paths = [], depths = [];
            try {
                var top = kag.menu.children;
                for (var i = top.count - 1; i >= 0; i--) { items.add(top[i]); paths.add("" + i); depths.add(0); }
            } catch (e) { return ""; }
            while (items.count > 0) {
                var n = items.count - 1;
                var item = items[n], path = paths[n], depth = depths[n];
                items.count = n; paths.count = n; depths.count = n;
                var caption = "" + item.caption;
                var visible = true;
                try { visible = item.visible; } catch (e) {}
                if (caption == "-" || caption == "" || !visible) continue;
                out.add(path + "\\t" + depth + "\\t" + caption + "\\t" + (item.enabled ? 1 : 0) + "\\t" + (item.checked ? 1 : 0));
                var children = item.children;
                for (var j = children.count - 1; j >= 0; j--) { items.add(children[j]); paths.add(path + "/" + j); depths.add(depth + 1); }
            }
            return out.join("\\n");
        })()
        """

    func laptopLeave() {
        guard presentedViewController == nil else { return }
        cancelPointer()
        presentLeaveQuestion()
    }
}
#endif
