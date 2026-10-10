import ArtemisKit
import AVFoundation
import GameController
import Metal
import SwiftUI
import UIKit

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// Plays an Artemis game with ArtemisKit: the stage drawn with Metal (`ArtemisMetalRenderer`),
/// letterboxed to the screen, taps in stage coordinates. Unlike Ren'Py this runs in our own
/// code, so leaving returns to the library instead of closing the app.
final class ArtemisGameViewController: UIViewController, ArtemisMediaDelegate, UIGestureRecognizerDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    /// Lifts the launch cover; called once, after the first frame the display link draws.
    private var onFirstFrame: (() -> Void)?
    private var player: ArtemisPlayer?
    /// The letterboxed stage, in stage pixels (taps convert through it); the Metal layer fills it.
    private let stageLayer = CALayer()
    private let metalLayer = CAMetalLayer()
    private let renderer = ArtemisMetalRenderer()
    /// The rendered stage without the text above it, kept between frames: the screen only
    /// changes at a flip, a tween or a video frame, and text types over it every frame.
    private var stageTexture: MTLTexture?
    /// The outgoing frame while a transition dissolves it.
    private var oldTexture: MTLTexture?
    private var transition: (start: CFTimeInterval, duration: CFTimeInterval, rule: CGImage?, vague: Double)?
    private var lastTextState = ""
    private var needsStage = true
    private var lastPresentation = -1
    private var lastTweenRevision = -1
    private var reportedFailure = false
    private var displayLink: CADisplayLink?
    private var startTime: CFTimeInterval = 0
    private var videoLayer: AVPlayerLayer?
    private var videoFinished: (() -> Void)?
    private var videoObserver: NSObjectProtocol?
    private var videoStatusObserver: NSKeyValueObservation?
    /// A movie AVFoundation can't play (MPEG-1, Theora), decoded by ArtemisKit.
    private var softwareVideo: ArtemisVideo?
    private var softwareVideoLayer: CALayer?
    private var softwareVideoStart: CFTimeInterval = 0
    private var lastVideoRevision = -1
    let audio = ArtemisAudio()

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void = {}, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onFirstFrame = onFirstFrame
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(tvOS)
    private var pointer: RemotePointer?

    @objc private func playPausePressed(_ recognizer: UITapGestureRecognizer) {
        if backlogView != nil { return }
        guard let player else { return }
        player.setAutoMode(!player.autoMode)
    }

    @objc private func playPauseHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        if backlogView != nil { closeBacklog() } else { presentBacklog() }
    }
    #else
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stageLayer.masksToBounds = true
        stageLayer.backgroundColor = UIColor.black.cgColor
        stageLayer.anchorPoint = .zero
        view.layer.addSublayer(stageLayer)
        metalLayer.device = renderer?.device
        metalLayer.pixelFormat = ArtemisMetalRenderer.pixelFormat
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.anchorPoint = .zero
        stageLayer.addSublayer(metalLayer)

        // Gestures from the game's own mobile controls: tap reads on, two-finger tap opens
        // the system menu (right-click), swipe left backs out or hides the text, swipe right
        // skips, holding for a second toggles auto mode. A two-finger hold leaves the game.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        #if os(tvOS)
        // The Siri Remote: the touch surface moves a pointer and a click lands at it; Menu is
        // the right-click (held, it leaves the game); Play/Pause toggles auto (held, the
        // backlog).
        pointer = RemotePointer(in: view)
        let menuHold = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        menuHold.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuHold.minimumPressDuration = 0.8
        view.addGestureRecognizer(menuHold)
        let menuPress = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        menuPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuPress.require(toFail: menuHold)
        view.addGestureRecognizer(menuPress)
        let playHold = UILongPressGestureRecognizer(target: self, action: #selector(playPauseHeld(_:)))
        playHold.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        playHold.minimumPressDuration = 0.8
        view.addGestureRecognizer(playHold)
        let playPress = UITapGestureRecognizer(target: self, action: #selector(playPausePressed(_:)))
        playPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        playPress.require(toFail: playHold)
        view.addGestureRecognizer(playPress)
        #else
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
        let history = UISwipeGestureRecognizer(target: self, action: #selector(showBacklog(_:)))
        history.direction = .down
        view.addGestureRecognizer(history)
        // Drags (sliders) only start on layers that take them, so swipes still work.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.delegate = self
        view.addGestureRecognizer(drag)
        back.require(toFail: drag)
        history.require(toFail: drag)
        skip.require(toFail: drag)
        let auto = UILongPressGestureRecognizer(target: self, action: #selector(heldForAuto(_:)))
        auto.minimumPressDuration = 1
        view.addGestureRecognizer(auto)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)
        #endif

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
            #if DEBUG
            // `-ShioriArtemisTrace YES` logs every wait the script stops at.
            player.traceWaits = UserDefaults.standard.bool(forKey: "ShioriArtemisTrace")
            #endif
            // The game's master volumes (0...1000), followed live (config sliders).
            audio.masterVolume = { @MainActor [weak player] id in
                guard let player else { return 1 }
                let names = id.map { ["s.sevol", "s.segain.\($0)"] } ?? ["s.bgmvol"]
                return names.reduce(Float(1)) { volume, name in
                    volume * Float(player.interpreter.value(of: name).flatMap(Double.init) ?? 1000) / 1000
                }
            }
            stageLayer.bounds = CGRect(x: 0, y: 0, width: player.stage.width, height: player.stage.height)
            metalLayer.frame = stageLayer.bounds
            try player.start()
        } catch {
            NSLog("Artemis: couldn't start: %@", String(describing: error))
        }
        // Artemis games have no controller support (the engine reads keyboard, mouse and
        // touch only): keep the pad away from the launcher and say so when it's used.
        ControllerInput.unsupportedGame = { [weak self] in self?.showControllerNotice() }
        if GCController.current?.extendedGamepad != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.showControllerNotice() }
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.player?.saveGlobals() }
        }
        startTime = CACurrentMediaTime()
        #if DEBUG
        // `-ShioriArtemisTaps "25:1135,151;30:640,300"`: taps at stage points, seconds from start.
        for step in (UserDefaults.standard.string(forKey: "ShioriArtemisTaps") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            if parts.count == 2, parts[1] == "B", let delay = Double(parts[0]) {
                let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.presentBacklog() }
                }
                RunLoop.main.add(timer, forMode: .common)
                continue
            }
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
        #if os(iOS)
        requestOrientations(.landscape)
        #endif
    }

    #if os(iOS)
    private func requestOrientations(_ mask: UIInterfaceOrientationMask) {
        OrientationLock.set(mask, in: view.window?.windowScene)
    }
    #endif

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
        softwareVideoLayer?.frame = view.bounds
        CATransaction.commit()
        // Draw at the screen's pixels: textures and text at the new size.
        let pixels = scale * (view.window?.screen.scale ?? 2)
        let width = Int((player.stage.width * pixels).rounded()), height = Int((player.stage.height * pixels).rounded())
        if metalLayer.drawableSize != CGSize(width: width, height: height) || stageTexture == nil {
            metalLayer.drawableSize = CGSize(width: width, height: height)
            stageTexture = renderer?.makeTarget(width: width, height: height)
            oldTexture = renderer?.makeTarget(width: width, height: height)
            needsStage = true
            lastTextState = ""
        }
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
        defer {
            if let lift = onFirstFrame {
                onFirstFrame = nil
                lift()
            }
        }
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
        if player.stage.presentationCount != lastPresentation {
            lastPresentation = player.stage.presentationCount
            if let last = player.stage.lastTransition, last.duration > 0, !player.skipMode {
                // Keep the outgoing frame to dissolve: plainly, or through a rule image.
                let rule = last.type == "2" ? last.rule.flatMap { player.stage.image($0) } : nil
                transition = (CACurrentMediaTime(), max(0.01, last.duration / 1000), rule, last.vague)
                if let renderer, let stageTexture, let oldTexture, let buffer = renderer.queue.makeCommandBuffer() {
                    renderer.copy(stageTexture, to: oldTexture, commandBuffer: buffer)
                    buffer.commit()
                }
            }
            needsStage = true
        } else if player.stage.tweenRevision != lastTweenRevision || player.stage.videoRevision != lastVideoRevision
                    || player.stage.shadersActive {
            // Tweens, video layers and animated shaders change the visible screen, including
            // layers no flip has shown yet.
            needsStage = true
        }
        lastTweenRevision = player.stage.tweenRevision
        lastVideoRevision = player.stage.videoRevision
        stepSoftwareVideo()
        draw(player)
    }

    // MARK: Drawing

    /// Renders the frame when something on screen changed: the stage (when it did) into its
    /// texture, then on the drawable the stage, a transition's outgoing frame, and the text.
    private func draw(_ player: ArtemisPlayer) {
        guard let renderer, let stageTexture, let oldTexture else { return }
        let pixels = Double(stageTexture.width) / player.stage.width
        let texts = player.metalTexts(scale: pixels)
        // Text in the tree (layered) redraws the stage; the rest only the top.
        let textState = texts.map { "\($0.id):\(ObjectIdentifier($0.image).hashValue):\($0.reveal?.count ?? -1):\($0.reveal?.last.map { "\($0)" } ?? "")" }
            .joined(separator: "|") + "|\(player.messageTextVisible)"
        let layeredState = texts.filter(\.layered).map { "\($0.id):\(ObjectIdentifier($0.image).hashValue):\($0.reveal?.last.map { "\($0)" } ?? "")" }.joined()
        if layeredState != lastLayeredState {
            lastLayeredState = layeredState
            needsStage = true
        }
        var progress: Double?
        if let transition {
            let value = (CACurrentMediaTime() - transition.start) / transition.duration
            var waitEnded = true
            if case .time = player.wait { waitEnded = false }
            // Done, cut short by a tap (the trans wait ended early), or skip mode.
            if value >= 1 || waitEnded || player.skipMode {
                self.transition = nil
            } else {
                progress = value
            }
        }
        let transitionEnded = transitionJustEnded(progress)
        guard needsStage || textState != lastTextState || progress != nil || transitionEnded else { return }
        lastTextState = textState
        guard let drawable = metalLayer.nextDrawable(), let buffer = renderer.queue.makeCommandBuffer() else { return }
        if player.traceWaits, needsStage {
            NSLog("Artemis: draw stage %dx%d into %dx%d, %d top layers, transition %@", Int(player.stage.width), Int(player.stage.height),
                  drawable.texture.width, drawable.texture.height, player.stage.root.children.count, progress.map { "\($0)" } ?? "none")
        }
        #if DEBUG
        if player.traceWaits, needsStage, let target = renderer.makeTarget(width: stageTexture.width, height: stageTexture.height, readable: true),
           let dump = renderer.queue.makeCommandBuffer() {
            // `-ShioriArtemisTrace YES`: the latest stage as rendered, in tmp/artemis-stage.png.
            renderer.render(stage: player.stage, texts: texts, textsVisible: false, into: target, commandBuffer: dump)
            dump.commit()
            dump.waitUntilCompleted()
            if let image = ArtemisMetalRenderer.image(from: target) {
                try? UIImage(cgImage: image).pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("artemis-stage.png"))
            }
        }
        #endif
        if needsStage {
            needsStage = false
            renderer.prefetch(player.stage.animeFrameImages)
            renderer.render(stage: player.stage, texts: texts, textsVisible: false, into: stageTexture, commandBuffer: buffer)
        }
        renderer.draw(stageTexture, into: drawable.texture, commandBuffer: buffer)
        if let progress, let transition {
            renderer.dissolve(old: oldTexture, over: drawable.texture, progress: progress, rule: transition.rule,
                              vague: transition.vague, commandBuffer: buffer)
        }
        if player.messageTextVisible {
            renderer.renderTexts(texts, stageSize: CGSize(width: player.stage.width, height: player.stage.height),
                                 into: drawable.texture, commandBuffer: buffer)
        }
        buffer.present(drawable)
        buffer.commit()
    }
    private var lastLayeredState = ""
    private var hadTransition = false

    /// One more frame once a transition ends, to clear its last step.
    private func transitionJustEnded(_ progress: Double?) -> Bool {
        defer { hadTransition = progress != nil }
        return hadTransition && progress == nil
    }

    // MARK: Input

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        if backlogView != nil { return }
        if let videoFinished {
            stopVideo()
            videoFinished()
            return
        }
        #if os(tvOS)
        let point = pointer?.location ?? recognizer.location(in: view)
        #else
        let point = recognizer.location(in: view)
        #endif
        let stagePoint = stageLayer.convert(point, from: view.layer)
        if player?.traceWaits == true { NSLog("Artemis: tap at stage %.0f,%.0f", stagePoint.x, stagePoint.y) }
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
        return player.canDrag(at: stagePoint(recognizer))
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        let point = stagePoint(recognizer)
        switch recognizer.state {
        case .began:
            player?.touch(0, at: point)
            player?.drag(.began, at: point)
        case .changed:
            player?.touch(0, at: point)
            player?.drag(.moved, at: point)
        case .ended, .cancelled, .failed:
            player?.drag(.ended, at: point)
            player?.touch(0, at: nil)
        default: break
        }
    }

    // MARK: Controller notice

    private var controllerNotice: UIView?

    /// "No controller support" in a pill at the top, for a few seconds.
    private func showControllerNotice() {
        guard controllerNotice == nil else { return }
        let label = UILabel()
        label.text = "This game doesn't support controllers. Use touch to play."
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.textAlignment = .center
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: Self.noticeBlur))
        pill.layer.cornerRadius = 18
        pill.clipsToBounds = true
        pill.contentView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -9),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        pill.alpha = 0
        controllerNotice = pill
        UIView.animate(withDuration: 0.25) { pill.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 3, options: []) { pill.alpha = 0 } completion: { [weak self] _ in
            pill.removeFromSuperview()
            self?.controllerNotice = nil
        }
    }

    // MARK: Backlog

    private var backlogView: UIView?

    /// Swipe down: the pages read so far, newest at the bottom. A tap closes it.
    @objc private func showBacklog(_ recognizer: UISwipeGestureRecognizer) {
        presentBacklog()
    }

    private func presentBacklog() {
        guard backlogView == nil, let player else { return }
        // The game's own backlog when it has one (bound to the wheel or arrow keys).
        if player.requestBacklog() { return }
        guard !player.backlog.isEmpty else { return }
        let container = UIView(frame: view.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        let text = UITextView(frame: container.bounds.insetBy(dx: max(24, view.safeAreaInsets.left), dy: 20))
        text.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        text.backgroundColor = .clear
        #if os(iOS)
        text.isEditable = false
        #endif
        text.isSelectable = false
        let body = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 18
        for page in player.backlog {
            if let speaker = page.speaker {
                body.append(NSAttributedString(string: speaker + "\n", attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold),
                    .foregroundColor: UIColor.systemTeal, .paragraphStyle: NSParagraphStyle.default,
                ]))
            }
            // A page's line breaks are layout, not paragraphs.
            let flowing = page.text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            body.append(NSAttributedString(string: flowing + "\n", attributes: [
                .font: UIFont.preferredFont(forTextStyle: .body),
                .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
            ]))
        }
        text.attributedText = body
        container.addSubview(text)
        let close = UITapGestureRecognizer(target: self, action: #selector(closeBacklog))
        container.addGestureRecognizer(close)
        container.alpha = 0
        view.addSubview(container)
        backlogView = container
        text.layoutIfNeeded()
        text.scrollRangeToVisible(NSRange(location: max(0, body.length - 1), length: 1))
        UIView.animate(withDuration: 0.2) { container.alpha = 1 }
    }

    @objc private func closeBacklog() {
        guard let backlog = backlogView else { return }
        backlogView = nil
        UIView.animate(withDuration: 0.2, animations: { backlog.alpha = 0 }) { _ in backlog.removeFromSuperview() }
    }

    @objc private func rightClick(_ recognizer: UITapGestureRecognizer) {
        if backlogView != nil { return }
        player?.rightClick()
    }

    @objc private func swipedBack(_ recognizer: UISwipeGestureRecognizer) {
        if backlogView != nil { return }
        guard let player else { return }
        // In a menu (waiting on buttons) back out like a right-click; while reading, hide.
        if player.wait == .stop { player.rightClick() } else { player.toggleHide() }
    }

    @objc private func swipedSkip(_ recognizer: UISwipeGestureRecognizer) {
        if backlogView != nil { return }
        guard let player else { return }
        player.setSkipMode(!player.skipMode)
    }

    @objc private func heldForAuto(_ recognizer: UILongPressGestureRecognizer) {
        if backlogView != nil { return }
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
        ControllerInput.unsupportedGame = nil
        #if os(iOS)
        requestOrientations(.all)
        #endif
        onExit()
    }

    // MARK: ArtemisMediaDelegate

    func soundTag(_ tag: ArtemisTag, data: (String) -> Data?) {
        audio.handle(tag, data: data)
    }

    func isSoundPlaying(_ id: String) -> Bool {
        audio.isPlaying(id)
    }

    func soundInfo(_ id: String?) -> (playing: Bool, gain: Double, pan: Double)? {
        audio.info(id)
    }

    var soundChannels: [String] { audio.effectIDs }

    func openURL(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        UIApplication.shared.open(url)
    }

    #if os(tvOS)
    private static let noticeBlur = UIBlurEffect.Style.dark
    /// Apple TV has neither haptics nor a pasteboard.
    func vibrate() {}
    func copyToClipboard(_ text: String) {}
    #else
    private static let noticeBlur = UIBlurEffect.Style.systemThinMaterialDark
    func vibrate() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
    }
    #endif

    func playVideo(_ source: ArtemisVideoSource, finished: @escaping () -> Void) -> Bool {
        switch source.fileExtension {
        case "mp4", "m4v", "mov":
            return playSystemVideo(source, finished: finished)
        default:
            return playSoftwareVideo(source, finished: finished)
        }
    }

    /// MPEG-4 and friends through AVPlayer. A movie that fails to load ends at once, so the
    /// game never waits on a picture that won't come.
    private func playSystemVideo(_ source: ArtemisVideoSource, finished: @escaping () -> Void) -> Bool {
        let url: URL
        switch source {
        case let .file(file):
            url = file
        case let .data(data, ext):
            url = FileManager.default.temporaryDirectory.appendingPathComponent("artemis-video.\(ext)")
            guard (try? data.write(to: url)) != nil else { return false }
        }
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
            MainActor.assumeIsolated { self?.endVideo() }
        }
        videoStatusObserver = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSLog("[Artemis] movie failed: %@", item.error?.localizedDescription ?? "unknown")
                    self?.endVideo()
                }
            }
        }
        avPlayer.play()
        return true
    }

    /// MPEG-1 and Ogg Theora, decoded in software on the display clock, with the MP2
    /// soundtrack streamed to the audio engine.
    private func playSoftwareVideo(_ source: ArtemisVideoSource, finished: @escaping () -> Void) -> Bool {
        let video: ArtemisVideo?
        switch source {
        case let .file(url): video = ArtemisVideo(url: url)
        case let .data(data, ext): video = ArtemisVideo(data: data, fileExtension: ext)
        }
        guard let video else {
            NSLog("[Artemis] movie format not supported; skipped")
            return false
        }
        let layer = CALayer()
        layer.frame = view.bounds
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(layer)
        softwareVideo = video
        softwareVideoLayer = layer
        softwareVideoStart = CACurrentMediaTime()
        videoFinished = finished
        if video.hasAudio { audio.startStream(sampleRate: video.audioSampleRate) }
        stepSoftwareVideo()
        return true
    }

    private func stepSoftwareVideo() {
        guard let video = softwareVideo, let layer = softwareVideoLayer else { return }
        let seconds = CACurrentMediaTime() - softwareVideoStart
        if video.update(time: seconds * 1000) { layer.contents = video.image }
        // Keep half a second of sound queued ahead of the picture.
        if video.hasAudio { audio.enqueue(video.audio(upTo: seconds + 0.5)) }
        if video.isFinished { endVideo() }
    }

    private func endVideo() {
        guard let finished = videoFinished else { return }
        stopVideo()
        finished()
    }

    private func stopVideo() {
        videoLayer?.player?.pause()
        videoLayer?.removeFromSuperlayer()
        videoLayer = nil
        videoFinished = nil
        if let videoObserver { NotificationCenter.default.removeObserver(videoObserver) }
        videoObserver = nil
        videoStatusObserver = nil
        softwareVideoLayer?.removeFromSuperlayer()
        softwareVideoLayer = nil
        if softwareVideo?.hasAudio == true { audio.stopStream() }
        softwareVideo = nil
    }
}

/// SwiftUI wrapper for presenting a game full screen.
struct ArtemisGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> ArtemisGameViewController {
        ArtemisGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: ArtemisGameViewController, context: Context) {}
}
