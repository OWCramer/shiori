import ArtemisKit
import AVFoundation
import SwiftUI
import UIKit

/// Plays an Artemis game with ArtemisKit: the stage mirrored into Core Animation layers,
/// letterboxed to the screen, taps in stage coordinates. Unlike Ren'Py this runs in our own
/// code, so leaving returns to the library instead of closing the app.
final class ArtemisGameViewController: UIViewController, ArtemisMediaDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var player: ArtemisPlayer?
    private let stageLayer = CALayer()
    private let messageLayer = CALayer()
    private var layers: [String: CALayer] = [:]
    private var images: [String: ObjectIdentifier] = [:]
    private var messageRevisions: [String: Int] = [:]
    private var messageSublayers: [String: CALayer] = [:]
    private var lastPresentation = -1
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)

        do {
            let base = gameFolder.appendingPathComponent("base", isDirectory: true)
            let patch = gameFolder.appendingPathComponent("patch", isDirectory: true)
            let player = try ArtemisPlayer(gameRoot: base, patchRoot: patch)
            player.media = self
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
        if player.failure != nil || player.interpreter.state == .finished {
            leave()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if player.stage.presentationCount != lastPresentation {
            lastPresentation = player.stage.presentationCount
            if let transition = player.stage.lastTransition, transition.duration > 0 {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = transition.duration / 1000
                stageLayer.add(fade, forKey: "artemis.trans")
            }
            sync(player.stage.root, into: stageLayer, full: true)
        } else if !player.stage.tweens.isEmpty {
            for tween in player.stage.tweens {
                if let layer = player.stage.layer(tween.layer), let caLayer = layers[layer.id] { apply(layer, to: caLayer) }
            }
        }
        syncMessages(player)
        CATransaction.commit()
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
        for layer in current where layer !== messageLayer && !keep.contains(where: { $0 === layer }) && layer !== videoLayer {
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
            sublayer.contents = layer.text.isEmpty ? nil
                : player.textRenderer.image(for: layer, stageWidth: player.stage.width, stageHeight: player.stage.height, scale: scale)
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

    private func leave() {
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
