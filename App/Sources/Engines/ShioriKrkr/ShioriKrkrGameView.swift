// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import AVFoundation
import CShioriKrkr
import os
import SwiftUI
import UIKit

/// Which KiriKiri engine plays a game while both exist (Phase 23): AetherKrkr (the full
/// edition's default) or Shiori's own, krkrsdl3-based one. Per game, in UserDefaults; the
/// launch flag `-ShioriKrkrEngine shiori` (or `aether`) overrides every game.
enum KiriKiriEngineChoice: String {
    case aether
    case shiori

    static func engine(for appID: UInt32) -> KiriKiriEngineChoice {
        let defaults = UserDefaults.standard
        if let forced = defaults.string(forKey: "ShioriKrkrEngine").flatMap(KiriKiriEngineChoice.init(rawValue:)) {
            return forced
        }
        return defaults.string(forKey: key(appID)).flatMap(KiriKiriEngineChoice.init(rawValue:)) ?? .aether
    }

    static func set(_ engine: KiriKiriEngineChoice, for appID: UInt32) {
        UserDefaults.standard.set(engine.rawValue, forKey: key(appID))
    }

    private static func key(_ appID: UInt32) -> String { "kirikiriEngine.\(appID)" }
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

    static func start(gameFolder: URL) throws -> UnsafePointer<shiorikrkr_api_t> {
        let api = try load()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let root = try prepareRoot(gameFolder: gameFolder)
        // GARbroDatabase.prepare put the game's CxDec scheme here before launch, if it has one.
        let scheme = URL.cachesDirectory.appendingPathComponent("KiriKiri/\(gameFolder.lastPathComponent)/scheme.shcx")
        let schemePath = FileManager.default.fileExists(atPath: scheme.path) ? scheme.path : nil
        let exe = exeName(in: root)
        let options = ["-render=software"]
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

/// Plays a KiriKiri game on ShioriKrkr. The engine draws into its own SDL view, placed in this
/// controller's view; touches stay with Shiori: a tap is a click, a two-finger tap the right
/// button (KiriKiri's menu / hide text), a two-finger hold leaves.
final class ShioriKrkrGameViewController: UIViewController {
    private let gameFolder: URL
    private var onFirstFrame: (() -> Void)?
    private let onExit: () -> Void
    private var api: UnsafePointer<shiorikrkr_api_t>?
    private var displayLink: CADisplayLink?
    private var engineView: UIView?
    private var ticking = false
    private var frames = 0
    private var leaving = false
    private weak var pointerTouch: UITouch?

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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        let menu = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        menu.numberOfTouchesRequired = 2
        menu.cancelsTouchesInView = false
        view.addGestureRecognizer(menu)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        leave.cancelsTouchesInView = false
        view.addGestureRecognizer(leave)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        OrientationLock.set(.landscape, in: view.window?.windowScene)
        // Start once the scene has turned, so SDL's window is made landscape.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startIfNeeded() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        engineView?.frame = view.bounds
    }

    private func startIfNeeded() {
        guard api == nil, !leaving else { return }
        do {
            api = try ShioriKrkrRuntime.start(gameFolder: gameFolder)
        } catch {
            fail(error.localizedDescription)
            return
        }
        if let pointer = api?.pointee.take_view(), let engine = Unmanaged<UIView>.fromOpaque(pointer).takeUnretainedValue() as UIView? {
            engine.removeFromSuperview()
            engine.isUserInteractionEnabled = false
            engine.frame = view.bounds
            engine.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(engine, at: 0)
            engineView = engine
        }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        guard let api, !leaving, !ticking else { return }
        ticking = true
        defer { ticking = false }
        if api.pointee.tick() == 0 {
            leave()
            return
        }
        frames += 1
        // The engine draws its first frames black while the title loads; lift the cover once
        // it has had a moment (milestone 2's Metal presenter can tell a real first frame).
        if frames == 45, let lift = onFirstFrame {
            onFirstFrame = nil
            lift()
        }
    }

    // MARK: Input

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

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerTouch == nil, event?.allTouches?.count ?? 1 == 1, let touch = touches.first else { return }
        pointerTouch = touch
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), touch.location(in: view))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointer(Int32(SHIORIKRKR_POINTER_MOVED), touch.location(in: view))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = pointerTouch, touches.contains(touch) else { return }
        pointerTouch = nil
        pointer(Int32(SHIORIKRKR_POINTER_UP), touch.location(in: view))
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    @objc private func rightClick(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        pointer(Int32(SHIORIKRKR_POINTER_DOWN), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
        pointer(Int32(SHIORIKRKR_POINTER_UP), point, button: Int32(SHIORIKRKR_BUTTON_RIGHT))
    }

    @objc private func askToLeave(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Leave the game?", message: "Unsaved progress is lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    // MARK: Leaving

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
        api?.pointee.stop()
        engineView?.removeFromSuperview()
        engineView = nil
        OrientationLock.set(.all, in: view.window?.windowScene)
        onExit()
    }
}

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
