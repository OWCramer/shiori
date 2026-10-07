import ArtemisKit
import AVFoundation
import SwiftUI
import UIKit

/// Plays an Artemis game with ArtemisKit: the stage mirrored into Core Animation layers,
/// letterboxed to the screen, taps in stage coordinates. Unlike Ren'Py this runs in our own
/// code, so leaving returns to the library instead of closing the app.
final class ArtemisGameViewController: UIViewController, ArtemisMediaDelegate, UIGestureRecognizerDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var player: ArtemisPlayer?
    private let stageLayer = CALayer()
    private let messageLayer = CALayer()
    private var layers: [String: CALayer] = [:]
    private var images: [String: ObjectIdentifier] = [:]
    private var messageRevisions: [String: Int] = [:]
    private var messageSublayers: [String: CALayer] = [:]
    private var revealCounts: [String: Int] = [:]
    private var lastPresentation = -1
    private var lastTweenRevision = -1
    private var reportedFailure = false
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var videoLayer: AVPlayerLayer?
    private var videoFinished: (() -> Void)?
    private var videoObserver: NSObjectProtocol?
    let audio = ArtemisAudio()

    init(gameFolder: URL, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stageLayer.masksToBounds = true
        stageLayer.backgroundColor = UIColor.black.cgColor
        stageLayer.anchorPoint = .zero
        messageLayer.anchorPoint = .zero
        view.layer.addSublayer(stageLayer)
        stageLayer.addSublayer(messageLayer)

        // Gestures from the game's own mobile controls: tap reads on, two-finger tap opens
        // the system menu (right-click), swipe left backs out or hides the text, swipe right
        // skips, holding for a second toggles auto mode. A two-finger hold leaves the game.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        let menu = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        menu.numberOfTouchesRequired = 2
        view.addGestureRecognizer(menu)
        tap.require(toFail: menu)
        let back = UISwipeGestureRecognizer(target: self, action: #selector(swipedBack(_:)))
        back.direction = .left
        view.addGestureRecognizer(back)
        let skip = UISwipeGestureRecognizer(target: self, action: #selector(swipedSkip(_:)))
        skip.direction = .right
        view.addGestureRecognizer(skip)
        // Drags (sliders) only start on layers that take them, so swipes still work.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.delegate = self
        view.addGestureRecognizer(drag)
        back.require(toFail: drag)
        skip.require(toFail: drag)
        let auto = UILongPressGestureRecognizer(target: self, action: #selector(heldForAuto(_:)))
        auto.minimumPressDuration = 1
        view.addGestureRecognizer(auto)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)

        do {
            let base = gameFolder.appendingPathComponent("base", isDirectory: true)
            let patch = gameFolder.appendingPathComponent("patch", isDirectory: true)
            let player = try ArtemisPlayer(gameRoot: base, patchRoot: patch)
            player.media = self
            player.savePath = gameFolder.appendingPathComponent("saves", isDirectory: true)
            player.onLog = { message in
                if !message.hasPrefix("debug:") && !message.hasPrefix("lua:") { NSLog("Artemis: %@", message) }
            }
            self.player = player
            stageLayer.bounds = CGRect(x: 0, y: 0, width: player.stage.width, height: player.stage.height)
            messageLayer.frame = stageLayer.bounds
            try player.start()
        } catch {
            NSLog("Artemis: couldn't start: %@", String(describing: error))
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.saveGlobals() }
        }
        startTime = CACurrentMediaTime()
        #if DEBUG
        // `-VNHubArtemisTaps "25:1135,151;30:640,300"`: taps at stage points, seconds from start.
        for step in (UserDefaults.standard.string(forKey: "VNHubArtemisTaps") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            let xy = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
            guard parts.count == 2, let delay = Double(parts[0]), xy.count == 2 else { continue }
            let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    NSLog("Artemis: scripted tap %.0f,%.0f", xy[0], xy[1])
                    self?.player?.tap(at: CGPoint(x: xy[0], y: xy[1]))
                }
            }
            RunLoop.main.add(timer, forMode: .common)
        }
        #endif
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        frame()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestOrientations(.landscape)
    }

    private func requestOrientations(_ mask: UIInterfaceOrientationMask) {
        guard let scene = view.window?.windowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let player else { return }
        // Letterbox: fit the stage, centred.
        let size = view.bounds.size
        let scale = min(size.width / player.stage.width, size.height / player.stage.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        stageLayer.position = CGPoint(x: (size.width - player.stage.width * scale) / 2,
                                      y: (size.height - player.stage.height * scale) / 2)
        videoLayer?.frame = view.bounds
        CATransaction.commit()
        messageRevisions.removeAll() // redraw text at the new scale
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
    }

    // MARK: Frames

    @objc private func frame() {
        guard let player else { return }
        player.update(time: (CACurrentMediaTime() - startTime) * 1000)
        audio.tick()
        if player.interpreter.state == .finished {
            leave()
            return
        }
        if let failure = player.failure, presentedViewController == nil, !reportedFailure {
            reportedFailure = true
            let alert = UIAlertController(title: "The game hit a script error", message: failure, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
            present(alert, animated: true)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if player.stage.presentationCount != lastPresentation {
            lastPresentation = player.stage.presentationCount
            if let transition = player.stage.lastTransition, transition.duration > 0 {
                if transition.type == "2", let rule = transition.rule, let ruleImage = player.stage.image(rule),
                   let mask = ArtemisRuleTransition(rule: ruleImage, vague: transition.vague) {
                    startRuleTransition(mask, duration: transition.duration / 1000, player: player)
                } else {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = transition.duration / 1000
                    stageLayer.add(fade, forKey: "artemis.trans")
                }
            }
            sync(player.stage.root, into: stageLayer, full: true)
        } else if player.stage.tweenRevision != lastTweenRevision {
            // Tweens animate the visible screen, including layers no flip has shown yet.
            sync(player.stage.root, into: stageLayer, full: false)
        }
        lastTweenRevision = player.stage.tweenRevision
        syncMessages(player)
        stepRuleTransition()
        CATransaction.commit()
    }

    // MARK: Rule transitions

    private var ruleOverlay: CALayer?
    private var ruleMask: ArtemisRuleTransition?
    private var ruleStart: CFTimeInterval = 0
    private var ruleDuration: CFTimeInterval = 0

    /// Freezes the outgoing frame on top, to be dissolved through the rule mask while the
    /// new frame shows underneath.
    private func startRuleTransition(_ mask: ArtemisRuleTransition, duration: CFTimeInterval, player: ArtemisPlayer) {
        ruleOverlay?.removeFromSuperlayer()
        let size = CGSize(width: player.stage.width, height: player.stage.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let snapshot = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for layer in stageLayer.sublayers ?? [] where layer !== messageLayer && layer !== ruleOverlay {
                context.cgContext.saveGState()
                layer.render(in: context.cgContext)
                context.cgContext.restoreGState()
            }
        }
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: size)
        overlay.contents = snapshot.cgImage
        let maskLayer = CALayer()
        maskLayer.frame = overlay.bounds
        overlay.mask = maskLayer
        stageLayer.insertSublayer(overlay, below: messageLayer)
        ruleOverlay = overlay
        ruleMask = mask
        ruleStart = CACurrentMediaTime()
        ruleDuration = max(0.01, duration)
        stepRuleTransition()
    }

    private func stepRuleTransition() {
        guard let overlay = ruleOverlay, let mask = ruleMask else { return }
        let progress = (CACurrentMediaTime() - ruleStart) / ruleDuration
        var transitionWaitEnded = true
        if case .time = player?.wait { transitionWaitEnded = false }
        // Done, skipped by a tap (the trans wait ended early), or skip mode.
        if progress >= 1 || transitionWaitEnded || player?.skipMode == true {
            overlay.removeFromSuperlayer()
            ruleOverlay = nil
            ruleMask = nil
            return
        }
        overlay.mask?.contents = mask.oldFrameMask(progress: progress)
        // Keep it above layers synced since, under the text.
        if overlay.superlayer != nil, stageLayer.sublayers?.last(where: { $0 !== messageLayer }) !== overlay {
            stageLayer.insertSublayer(overlay, below: messageLayer)
        }
    }

    /// Mirrors `node`'s children into `parent`'s sublayers (message text stays on top).
    private func sync(_ node: ArtemisLayer, into parent: CALayer, full: Bool) {
        var keep: [CALayer] = []
        for child in node.children {
            let caLayer = layers[child.id] ?? {
                let layer = CALayer()
                layer.anchorPoint = .zero
                layers[child.id] = layer
                return layer
            }()
            apply(child, to: caLayer)
            if let image = child.image {
                if images[child.id] != ObjectIdentifier(image) {
                    caLayer.contents = image
                    images[child.id] = ObjectIdentifier(image)
                }
            } else if images[child.id] != nil {
                caLayer.contents = nil
                images[child.id] = nil
            }
            if let color = child.color {
                caLayer.backgroundColor = CGColor(red: Double((color >> 16) & 0xFF) / 255, green: Double((color >> 8) & 0xFF) / 255,
                                                  blue: Double(color & 0xFF) / 255, alpha: Double((color >> 24) & 0xFF) / 255)
            } else {
                caLayer.backgroundColor = nil
            }
            sync(child, into: caLayer, full: full)
            keep.append(caLayer)
        }
        // Order and prune.
        let current = parent.sublayers ?? []
        for layer in current where layer !== messageLayer && layer !== ruleOverlay && !keep.contains(where: { $0 === layer }) && layer !== videoLayer {
            layer.removeFromSuperlayer()
            if let key = layers.first(where: { $0.value === layer })?.key { forget(key) }
        }
        for (index, layer) in keep.enumerated() where (parent.sublayers?.firstIndex(of: layer)) != index {
            parent.insertSublayer(layer, at: UInt32(index))
        }
        if parent === stageLayer { stageLayer.addSublayer(messageLayer) }
    }

    private func forget(_ id: String) {
        for key in layers.keys where key == id || key.hasPrefix(id + ".") {
            layers[key] = nil
            images[key] = nil
        }
    }

    private func apply(_ layer: ArtemisLayer, to caLayer: CALayer) {
        caLayer.bounds = CGRect(x: 0, y: 0, width: layer.width, height: layer.height)
        caLayer.anchorPoint = .zero
        caLayer.position = .zero
        caLayer.setAffineTransform(layer.transform)
        caLayer.opacity = Float(layer.alpha / 255)
        caLayer.isHidden = !layer.visible
    }

    private func syncMessages(_ player: ArtemisPlayer) {
        let scale = Double(stageLayer.affineTransform().a) * Double(view.window?.screen.scale ?? 2)
        for (id, layer) in player.messages.layers where messageRevisions[id] != layer.revision {
            messageRevisions[id] = layer.revision
            let sublayer = messageSublayers[id] ?? {
                let sublayer = CALayer()
                sublayer.frame = messageLayer.bounds
                messageLayer.addSublayer(sublayer)
                messageSublayers[id] = sublayer
                return sublayer
            }()
            sublayer.contents = layer.text.isEmpty || layer.pageHidden ? nil
                : player.textRenderer.image(for: layer, stageWidth: player.stage.width, stageHeight: player.stage.height, scale: scale)
            revealCounts[id] = -1
        }
        // Typewriter: reveal the drawn text through a mask that grows over its glyphs.
        for (id, layer) in player.messages.layers {
            guard let sublayer = messageSublayers[id] else { continue }
            let count = Int(layer.revealed)
            guard revealCounts[id] != count || (count >= layer.text.count && sublayer.mask != nil) else { continue }
            revealCounts[id] = count
            if count >= layer.text.count {
                sublayer.mask = nil
                continue
            }
            let mask = (sublayer.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame = sublayer.bounds
            let path = CGMutablePath()
            for rect in player.textRenderer.revealRects(for: layer, count: count) { path.addRect(rect) }
            mask.path = path
            sublayer.mask = mask
        }
        // Text shows only while its window does (hidden with the message layers' parent, 80).
        messageLayer.isHidden = player.stage.layer("80").map { !$0.visible } ?? false
    }

    // MARK: Input

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if let videoFinished {
            stopVideo()
            videoFinished()
            return
        }
        let point = recognizer.location(in: view)
        let stagePoint = stageLayer.convert(point, from: view.layer)
        player?.tap(at: stagePoint)
    }

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Leave the game?", message: "Progress since your last save is lost.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    private func stagePoint(_ recognizer: UIGestureRecognizer) -> CGPoint {
        stageLayer.convert(recognizer.location(in: view), from: view.layer)
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is UIPanGestureRecognizer, let player else { return true }
        let point = stagePoint(recognizer)
        return player.wait == .stop
            && (player.stage.eventTarget(at: point, type: "dragin") ?? player.stage.eventTarget(at: point, type: "drag")) != nil
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let point = stagePoint(recognizer)
        switch recognizer.state {
        case .began: player?.drag(.began, at: point)
        case .changed: player?.drag(.moved, at: point)
        case .ended, .cancelled, .failed: player?.drag(.ended, at: point)
        default: break
        }
    }

    @objc private func rightClick(_ recognizer: UITapGestureRecognizer) {
        player?.rightClick()
    }

    @objc private func swipedBack(_ recognizer: UISwipeGestureRecognizer) {
        guard let player else { return }
        // In a menu (waiting on buttons) back out like a right-click; while reading, hide.
        if player.wait == .stop { player.rightClick() } else { player.toggleHide() }
    }

    @objc private func swipedSkip(_ recognizer: UISwipeGestureRecognizer) {
        guard let player else { return }
        player.setSkipMode(!player.skipMode)
    }

    @objc private func heldForAuto(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let player else { return }
        player.setAutoMode(!player.autoMode)
    }

    func presentDialog(title: String, message: String, cancellable: Bool, textField: Bool,
                       answer: @escaping (Bool, String?) -> Void) {
        let alert = UIAlertController(title: title.isEmpty ? nil : title, message: message, preferredStyle: .alert)
        if textField { alert.addTextField() }
        if cancellable {
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in answer(false, nil) })
        }
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            answer(true, alert?.textFields?.first?.text)
        })
        present(alert, animated: true)
    }

    private func leave() {
        player?.saveGlobals()
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        requestOrientations(.all)
        onExit()
    }

    // MARK: ArtemisMediaDelegate

    func soundTag(_ tag: ArtemisTag, data: (String) -> Data?) {
        audio.handle(tag, data: data)
    }

    func isSoundPlaying(_ id: String) -> Bool {
        audio.isPlaying(id)
    }

    func playVideo(_ data: Data, fileExtension: String, finished: @escaping () -> Void) -> Bool {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("artemis-video.\(fileExtension.isEmpty ? "mp4" : fileExtension)")
        guard (try? data.write(to: url)) != nil else { return false }
        let item = AVPlayerItem(url: url)
        let avPlayer = AVPlayer(playerItem: item)
        let layer = AVPlayerLayer(player: avPlayer)
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(layer)
        videoLayer = layer
        videoFinished = finished
        videoObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let finished = self.videoFinished else { return }
                self.stopVideo()
                finished()
            }
        }
        avPlayer.play()
        return true
    }

    private func stopVideo() {
        videoLayer?.player?.pause()
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
        videoFinished = nil
        if let videoObserver { NotificationCenter.default.removeObserver(videoObserver) }
        videoObserver = nil
    }
}

/// SwiftUI wrapper for presenting a game full screen.
struct ArtemisGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> ArtemisGameViewController {
        ArtemisGameViewController(gameFolder: gameFolder, onExit: onExit)
    }

    func updateUIViewController(_ controller: ArtemisGameViewController, context: Context) {}
}
