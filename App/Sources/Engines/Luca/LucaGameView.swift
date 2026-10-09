import LucaKit
import SwiftUI
import UIKit

/// Plays a Luca System game (Summer Pockets REFLECTION BLUE) with LucaKit. The scripts tell
/// the stage what to show; the screens the PC game draws in its executable (title, menu,
/// save and load, backlog) are Shiori's own, dressed in the game's art where it has some.
final class LucaGameViewController: UIViewController {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var onFirstFrame: (() -> Void)?
    private var game: LucaGame?
    private var player: LucaPlayer?
    private let audio = LucaAudio()
    private var displayLink: CADisplayLink?
    private var leaving = false

    // Stage: 1920×1080 game space, letterboxed.
    private let stageSize = CGSize(width: 1920, height: 1080)
    private let stageLayer = CALayer()
    private let pictureLayer = CALayer()
    private var pictures: [Int: CALayer] = [:]
    private var pictureImages: [Int: Int] = [:]
    private var images: [Int: CGImage] = [:]
    private var imageOrder: [Int] = []
    /// Pictures being decoded off the main thread, and the ones done, waiting to be taken.
    private let prefetchQueue = DispatchQueue(label: "luca.prefetch", qos: .userInitiated)
    private var prefetching = Set<Int>()
    private let prefetched = LucaPrefetched()
    private var framesSincePrefetch = 0
    private var lastDraw = -1

    // Text window
    private let windowRect = CGRect(x: 0, y: 735, width: 1920, height: 345)
    private let windowLayer = CALayer()
    private let faceLayer = CALayer()
    private let overlay = UIView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private var shownMessage: LucaMessage?
    private var lastHadFace = false
    private var faceRects: [Int: CGRect] = [:]
    private var revealed = 0
    private var revealTarget = 0
    private var choiceStack: UIStackView?
    /// The island map behind the day's map choice.
    private var mapBackdrop: UIImageView?
    private var shownChoices: [String]?
    private var titleView: UIView?
    private var textHidden = false
    /// Auto reads on a moment after each line (and its voice) finishes; Skip races to the
    /// next choice. A tap stops either.
    private enum ReadMode { case normal, auto, skip }
    private var readMode = ReadMode.normal
    private var lineDoneAt: CFTimeInterval?
    #if DEBUG
    /// `-VNHubLucaAuto N`: reads on through N lines by itself (first choice picked), and
    /// `-VNHubLucaNewGame YES` starts a new game from the title, for unattended runs.
    private var autoLines = UserDefaults.standard.integer(forKey: "VNHubLucaAuto")
    #endif

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void = {}, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onFirstFrame = onFirstFrame
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    private var saves: URL { gameFolder.appendingPathComponent("saves", isDirectory: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stageLayer.anchorPoint = .zero
        stageLayer.bounds = CGRect(origin: .zero, size: stageSize)
        stageLayer.masksToBounds = true
        stageLayer.backgroundColor = UIColor.black.cgColor
        pictureLayer.frame = stageLayer.bounds
        stageLayer.addSublayer(pictureLayer)
        windowLayer.frame = windowRect
        stageLayer.addSublayer(windowLayer)
        faceLayer.frame = windowRect
        faceLayer.masksToBounds = true
        // The face sits in the window's left end and fades out towards the text.
        let faceFade = CAGradientLayer()
        faceFade.frame = faceLayer.bounds
        faceFade.startPoint = CGPoint(x: 0, y: 0.5)
        faceFade.endPoint = CGPoint(x: 1, y: 0.5)
        faceFade.colors = [UIColor.white.cgColor, UIColor.white.cgColor, UIColor.clear.cgColor]
        faceFade.locations = [0, 0.17, 0.23]
        faceLayer.mask = faceFade
        stageLayer.addSublayer(faceLayer)
        view.layer.addSublayer(stageLayer)

        overlay.isUserInteractionEnabled = true
        view.addSubview(overlay)
        for label in [nameLabel, textLabel] {
            label.textColor = .white
            label.numberOfLines = 0
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.8
            label.layer.shadowRadius = 2
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            overlay.addSubview(label)
        }
        nameLabel.textColor = UIColor(red: 0.62, green: 0.84, blue: 1, alpha: 1)

        // Tap reads on; two-finger tap opens the menu; swipe down shows the backlog; a
        // two-finger hold leaves.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        view.addGestureRecognizer(tap)
        let menu = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        menu.numberOfTouchesRequired = 2
        view.addGestureRecognizer(menu)
        tap.require(toFail: menu)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(showBacklog))
        history.direction = .down
        view.addGestureRecognizer(history)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)

        do {
            let game = try LucaGame(root: gameFolder.appendingPathComponent("base", isDirectory: true),
                                    patch: gameFolder.appendingPathComponent("patch", isDirectory: true))
            self.game = game
            if let window = game.image(Self.windowImageID).flatMap(Self.cgImage) {
                // MWIN0 is the window's shape in white; the engine tints it.
                let mask = CALayer()
                mask.frame = windowLayer.bounds
                mask.contents = window
                windowLayer.mask = mask
            }
            windowLayer.backgroundColor = UIColor(red: 0.04, green: 0.1, blue: 0.22, alpha: 0.78).cgColor
            try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            showTitle()
        } catch {
            NSLog("Luca: couldn't open the game: %@", String(describing: error))
            let alert = UIAlertController(title: "This game can't start", message: String(describing: error), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Leave", style: .default) { [weak self] _ in self?.leave() })
            DispatchQueue.main.async { self.present(alert, animated: true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        let scale = min(size.width / stageSize.width, size.height / stageSize.height)
        let frame = CGRect(x: (size.width - stageSize.width * scale) / 2, y: (size.height - stageSize.height * scale) / 2,
                           width: stageSize.width * scale, height: stageSize.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stageLayer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        stageLayer.position = frame.origin
        CATransaction.commit()
        overlay.frame = frame
        titleView?.frame = overlay.bounds
        layoutText()
        layoutChoices()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
    }

    // MARK: Frames

    @objc private func frame() {
        defer {
            if let lift = onFirstFrame {
                onFirstFrame = nil
                lift()
            }
        }
        audio.tick()
        guard let player, let game, titleView == nil else { return }
        prefetch(player)
        player.tick()
        for sound in player.sounds { audio.handle(sound, game: game) }
        player.sounds.removeAll()
        if player.finished {
            if let failure = player.failure { NSLog("Luca: stopped: %@", failure) }
            autosave()
            showTitle()
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if player.drawGeneration != lastDraw {
            lastDraw = player.drawGeneration
            if let transition = player.transition, transition.frames > 0 {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = Double(transition.frames) / 60
                pictureLayer.add(fade, forKey: "luca.draw")
                faceLayer.add(fade, forKey: "luca.draw")
            }
        } else if player.transition == nil {
            // A tap finished the transition early.
            if pictureLayer.animation(forKey: "luca.draw") != nil, !player.isWaitingForClick { }
        }
        syncPictures(player)
        let shake = player.shake
        pictureLayer.setAffineTransform(CGAffineTransform(translationX: shake.x, y: shake.y))
        CATransaction.commit()
        syncText(player)
        syncChoices(player)
        advanceByMode(player)
        #if DEBUG
        if autoLines > 0, player.transition == nil {
            if player.choices != nil {
                player.choose(0)
            } else if player.isWaitingForClick {
                autoLines -= 1
                revealed = revealTarget
                renderText()
                player.click()
                if autoLines == 0 { NSLog("Luca: auto run done at %@@%d", player.currentScript, player.currentPosition) }
            }
        }
        #endif
    }

    private func syncPictures(_ player: LucaPlayer) {
        var seen = Set<Int>()
        var wanted = player.sortedLayers
        if let face = player.windowFace { wanted.append(face) }
        for layer in wanted {
            seen.insert(layer.number)
            let isFace = layer.kind == 7
            let parent = isFace ? faceLayer : pictureLayer
            let ca: CALayer
            if let existing = pictures[layer.number], existing.superlayer === parent {
                ca = existing
            } else {
                pictures[layer.number]?.removeFromSuperlayer()
                ca = CALayer()
                ca.anchorPoint = .zero
                parent.addSublayer(ca)
                pictures[layer.number] = ca
                pictureImages[layer.number] = nil
            }
            guard let image = player.game.image(layer.imageID) else { ca.isHidden = true; continue }
            if pictureImages[layer.number] != layer.imageID {
                ca.contents = cgImage(layer.imageID, image)
                pictureImages[layer.number] = layer.imageID
            }
            ca.isHidden = false
            let w = Double(image.width) * layer.scale, h = Double(image.height) * layer.scale
            var (x, y) = layer.origin(width: w, height: h, offsetX: Double(image.offsetX), offsetY: Double(image.offsetY))
            if isFace {
                // Window coordinates: the face (its expression patch's rectangle) centred in
                // the window's left end.
                if faceRects[layer.imageID] == nil {
                    faceRects[layer.imageID] = player.game.faceRect(layer.imageID).map {
                        CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                    } ?? CGRect(x: w / 2 - 90, y: h * 0.12, width: 180, height: 150)
                }
                let face = faceRects[layer.imageID]!
                x = 215 - face.midX
                y = 215 - face.midY
            }
            ca.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            ca.position = CGPoint(x: x, y: y)
            ca.opacity = Float(layer.alpha)
            ca.zPosition = CGFloat(layer.order)
            ca.compositingFilter = layer.blend == 1 ? "addBlendMode" : (layer.blend == 2 ? "screenBlendMode" : nil)
        }
        for (number, ca) in pictures where !seen.contains(number) {
            ca.removeFromSuperlayer()
            pictures.removeValue(forKey: number)
            pictureImages.removeValue(forKey: number)
        }
        faceLayer.isHidden = !player.windowVisible || textHidden || player.message == nil
    }

    /// Every quarter second, decodes what the script will show next on a background queue.
    private func prefetch(_ player: LucaPlayer) {
        framesSincePrefetch += 1
        guard framesSincePrefetch >= 15, let game else { return }
        framesSincePrefetch = 0
        prefetching.subtract(prefetched.drainDone())
        for id in player.upcomingImages() where images[id] == nil && !prefetching.contains(id) && prefetching.count < 4 {
            prefetching.insert(id)
            let store = prefetched
            prefetchQueue.async {
                let cg = game.image(id).flatMap(LucaGameViewController.cgImage)
                store.put(id, cg)
            }
        }
    }

    private func cgImage(_ id: Int, _ image: CZImage) -> CGImage? {
        if let cached = images[id] { return cached }
        if let ready = prefetched.take(id) {
            prefetching.remove(id)
            remember(id, ready)
            return ready
        }
        guard let cg = Self.cgImage(image) else { return nil }
        remember(id, cg)
        return cg
    }

    /// Keeps a picture for the layers, the most recent up to about 300 MB.
    private func remember(_ id: Int, _ image: CGImage) {
        images[id] = image
        imageOrder.removeAll { $0 == id }
        imageOrder.append(id)
        func size(_ id: Int) -> Int { images[id].map { $0.bytesPerRow * $0.height } ?? 0 }
        var bytes = imageOrder.reduce(0) { $0 + size($1) }
        guard bytes > 300 << 20 else { return }
        let onScreen = Set(pictureImages.values)
        // Oldest first; pictures on screen and the newest stay.
        for old in imageOrder.dropLast() where bytes > 300 << 20 && !onScreen.contains(old) {
            bytes -= size(old)
            images.removeValue(forKey: old)
            imageOrder.removeAll { $0 == old }
        }
    }

    nonisolated static func cgImage(_ image: CZImage) -> CGImage? {
        // Premultiply for Core Animation.
        var pixels = image.rgba
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = UInt16(p[i + 3])
                if a < 255 {
                    p[i] = UInt8(UInt16(p[i]) * a / 255)
                    p[i + 1] = UInt8(UInt16(p[i + 1]) * a / 255)
                    p[i + 2] = UInt8(UInt16(p[i + 2]) * a / 255)
                }
                i += 4
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Text

    private var stageScale: CGFloat { overlay.bounds.width / stageSize.width }

    private func syncText(_ player: LucaPlayer) {
        let visible = player.windowVisible && !textHidden && player.message != nil
        windowLayer.isHidden = !(player.windowVisible && !textHidden)
        nameLabel.isHidden = !visible
        textLabel.isHidden = !visible
        if (player.windowFace != nil) != lastHadFace {
            lastHadFace = player.windowFace != nil
            layoutText()
        }
        if player.message != shownMessage {
            shownMessage = player.message
            revealed = 0
            revealTarget = shownMessage?.text.count ?? 0
            nameLabel.text = shownMessage?.speaker
            layoutText()
        }
        if revealed < revealTarget {
            revealed = min(revealTarget, revealed + 2)
            renderText()
        }
    }

    private func renderText() {
        guard let message = shownMessage else { textLabel.attributedText = nil; return }
        let font = UIFont.systemFont(ofSize: 44 * stageScale, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 10 * stageScale
        let text = NSMutableAttributedString(string: message.text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .paragraphStyle: paragraph,
        ])
        let shown = message.text.index(message.text.startIndex, offsetBy: min(revealed, message.text.count))
        let hidden = NSRange(shown..<message.text.endIndex, in: message.text)
        text.addAttribute(.foregroundColor, value: UIColor.clear, range: hidden)
        textLabel.attributedText = text
        // Top-aligned: as tall as the whole line needs (hidden letters included, so the text
        // doesn't move as it types).
        let needed = text.boundingRect(with: CGSize(width: textLabel.bounds.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height
        textLabel.frame.size.height = ceil(needed)
    }

    private func layoutText() {
        let s = stageScale
        guard s > 0 else { return }
        let hasFace = player?.windowFace != nil
        let left: CGFloat = hasFace ? 460 : 300
        nameLabel.font = UIFont.systemFont(ofSize: 40 * s, weight: .bold)
        nameLabel.frame = CGRect(x: left * s, y: (windowRect.minY + 112) * s, width: 1100 * s, height: 52 * s)
        textLabel.frame = CGRect(x: left * s, y: (windowRect.minY + 170) * s, width: (1920 - left - 180) * s, height: 160 * s)
        renderText()
    }

    private var typing: Bool { revealed < revealTarget }

    private func advanceByMode(_ player: LucaPlayer) {
        switch readMode {
        case .normal:
            return
        case .skip:
            if player.choices != nil {
                readMode = .normal
            } else if player.isWaitingForClick {
                revealed = revealTarget
                renderText()
                player.finishAnimations()
                player.click()
            } else {
                player.finishAnimations()
            }
        case .auto:
            guard player.isWaitingForClick, !typing, player.transition == nil, !audio.isVoicePlaying else {
                lineDoneAt = nil
                return
            }
            let now = CACurrentMediaTime()
            if let done = lineDoneAt {
                if now - done > 1.2 + Double(shownMessage?.text.count ?? 0) * 0.01 {
                    lineDoneAt = nil
                    player.click()
                }
            } else {
                lineDoneAt = now
            }
        }
    }

    // MARK: Choices

    private func syncChoices(_ player: LucaPlayer) {
        guard player.choices != shownChoices else { return }
        shownChoices = player.choices
        choiceStack?.removeFromSuperview()
        choiceStack = nil
        mapBackdrop?.removeFromSuperview()
        mapBackdrop = nil
        guard let choices = player.choices else { return }
        if player.choicePrompt != nil, let map = player.game.image(Self.mapImageID).flatMap(Self.cgImage) {
            let backdrop = UIImageView(image: UIImage(cgImage: map))
            backdrop.contentMode = .scaleAspectFill
            backdrop.clipsToBounds = true
            backdrop.alpha = 0.85
            backdrop.frame = overlay.bounds
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.insertSubview(backdrop, at: 0)
            mapBackdrop = backdrop
        }
        let stack = UIStackView()
        stack.axis = .vertical
        // Long lists (the map can offer nine places) sit tighter to fit a phone in landscape.
        let compact = choices.count > 5
        stack.spacing = compact ? 6 : 14
        if let prompt = player.choicePrompt {
            let label = UILabel()
            label.text = prompt
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
            stack.addArrangedSubview(label)
        }
        for (index, choice) in choices.enumerated() {
            var config = UIButton.Configuration.filled()
            config.title = choice
            config.baseBackgroundColor = UIColor(red: 0.05, green: 0.16, blue: 0.34, alpha: 0.88)
            config.baseForegroundColor = .white
            config.cornerStyle = .capsule
            config.contentInsets = NSDirectionalEdgeInsets(top: compact ? 5 : 12, leading: 28, bottom: compact ? 5 : 12, trailing: 28)
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in
                self?.player?.choose(index)
            })
            stack.addArrangedSubview(button)
        }
        overlay.addSubview(stack)
        choiceStack = stack
        layoutChoices()
    }

    private func layoutChoices() {
        guard let stack = choiceStack else { return }
        let width = min(overlay.bounds.width * 0.7, 640)
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        let y = min(max(10, overlay.bounds.height * 0.42 - size.height / 2), overlay.bounds.height - size.height - 10)
        stack.frame = CGRect(x: (overlay.bounds.width - width) / 2, y: max(10, y), width: width, height: size.height)
        mapBackdrop?.frame = overlay.bounds
    }

    // MARK: Input

    @objc private func tapped() {
        guard titleView == nil, presentedViewController == nil, let player else { return }
        if readMode != .normal {
            readMode = .normal
            return
        }
        if textHidden {
            textHidden = false
            return
        }
        guard player.choices == nil else { return }
        if typing {
            revealed = revealTarget
            renderText()
            return
        }
        player.click()
    }

    @objc private func showMenu() {
        guard titleView == nil, presentedViewController == nil, player != nil else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.presentSlots(saving: true) })
        sheet.addAction(UIAlertAction(title: "Load", style: .default) { [weak self] _ in self?.presentSlots(saving: false) })
        sheet.addAction(UIAlertAction(title: "Backlog", style: .default) { [weak self] _ in self?.showBacklog() })
        sheet.addAction(UIAlertAction(title: readMode == .auto ? "Stop Auto" : "Auto", style: .default) { [weak self] _ in
            guard let self else { return }
            self.readMode = self.readMode == .auto ? .normal : .auto
        })
        sheet.addAction(UIAlertAction(title: "Skip to Next Choice", style: .default) { [weak self] _ in self?.readMode = .skip })
        sheet.addAction(UIAlertAction(title: "Hide Text", style: .default) { [weak self] _ in self?.textHidden = true })
        sheet.addAction(UIAlertAction(title: "Title Screen", style: .default) { [weak self] _ in
            self?.autosave()
            self?.showTitle()
        })
        sheet.addAction(UIAlertAction(title: "Leave Game", style: .destructive) { [weak self] _ in self?.leave() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(sheet, animated: true)
    }

    @objc private func showBacklog() {
        guard titleView == nil, presentedViewController == nil, let player else { return }
        let backlog = UIHostingController(rootView: LucaBacklogView(lines: player.backlog) { [weak self] in
            self?.dismiss(animated: true)
        })
        backlog.modalPresentationStyle = .overFullScreen
        backlog.view.backgroundColor = .clear
        present(backlog, animated: true)
    }

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Leave the game?", message: "Your place is kept for Continue.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        autosave()
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .all)) { _ in }
        onExit()
    }

    // MARK: Title

    private func showTitle() {
        guard let game else { return }
        player = nil
        audio.handle(.stopVoice, game: game)
        audio.handle(.stopEffect(channel: -1, fadeFrames: 0), game: game)
        audio.handle(.music(id: Self.titleMusicID, fadeFrames: 60), game: game)
        titleView?.removeFromSuperview()
        let title = UIHostingController(rootView: LucaTitleView(
            background: game.image(Self.titleBackgroundID).flatMap(Self.cgImage),
            logo: game.image(Self.titleLogoID).flatMap(Self.cgImage),
            canContinue: LucaSaves.latest(in: saves) != nil,
            onNewGame: { [weak self] in self?.start(state: nil) },
            onContinue: { [weak self] in
                guard let self, let latest = LucaSaves.latest(in: self.saves) else { return }
                self.start(state: latest.state)
            },
            onLoad: { [weak self] in self?.presentSlots(saving: false) },
            onLeave: { [weak self] in self?.leave() }))
        addChild(title)
        title.view.backgroundColor = .black
        title.view.frame = overlay.bounds
        overlay.addSubview(title.view)
        title.didMove(toParent: self)
        titleView = title.view
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "VNHubLucaNewGame") {
            UserDefaults.standard.removeObject(forKey: "VNHubLucaNewGame")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start(state: nil) }
        }
        #endif
        // Hide the stage under the title.
        for ca in pictures.values { ca.removeFromSuperlayer() }
        pictures.removeAll()
        pictureImages.removeAll()
        windowLayer.isHidden = true
        nameLabel.isHidden = true
        textLabel.isHidden = true
        choiceStack?.removeFromSuperview()
        choiceStack = nil
        shownChoices = nil
    }

    private func start(state: LucaPlayer.State?) {
        guard let game else { return }
        do {
            let player = try LucaPlayer(game: game)
            if let state { try player.restore(state) }
            self.player = player
            audio.handle(.stopMusic(fadeFrames: 30), game: game)
            lastDraw = -1
            shownMessage = nil
            textHidden = false
            if let titleView {
                children.first { $0.view === titleView }?.removeFromParent()
                titleView.removeFromSuperview()
                self.titleView = nil
            }
        } catch {
            NSLog("Luca: couldn't start: %@", String(describing: error))
        }
    }

    // MARK: Saves

    private func autosave() {
        guard let player, !player.finished else { return }
        try? LucaSaves.write(player.saveState(), slot: 0, thumbnail: thumbnail(), in: saves)
    }

    private func thumbnail() -> Data? {
        let size = CGSize(width: 384, height: 216)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.scaleBy(x: size.width / stageSize.width, y: size.height / stageSize.height)
            pictureLayer.render(in: context.cgContext)
        }
        return image.jpegData(compressionQuality: 0.7)
    }

    private func presentSlots(saving: Bool) {
        let thumbnail = saving ? thumbnail() : nil
        let slots = UIHostingController(rootView: LucaSlotsView(
            folder: saves, saving: saving,
            onPick: { [weak self] slot in
                guard let self else { return }
                if saving {
                    if let player = self.player {
                        try? LucaSaves.write(player.saveState(), slot: slot, thumbnail: thumbnail, in: self.saves)
                    }
                    self.dismiss(animated: true)
                } else if let save = LucaSaves.read(slot: slot, in: self.saves) {
                    self.dismiss(animated: true)
                    self.start(state: save.state)
                }
            },
            onClose: { [weak self] in self?.dismiss(animated: true) }))
        slots.modalPresentationStyle = .overFullScreen
        slots.view.backgroundColor = .clear
        present(slots, animated: true)
    }

    // MARK: Game art (REFLECTION BLUE ids)

    /// MWIN0 in PARTS.PAK: the text window's shape.
    static let windowImageID = 64_116
    /// BG999Ax20, the summer sky of the opening.
    static let titleBackgroundID = 513
    /// __SYS_RBLOGO02a in OTHCG.PAK.
    static let titleLogoID = 25_160
    /// __SYS_MAP_BG01en in OTHCG.PAK: the island map.
    static let mapImageID = 25_133
    /// BGM01 in MUSIC.PAK.
    static let titleMusicID = 100_001
}

/// Decoded pictures handed from the prefetch queue to the main thread.
final class LucaPrefetched: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [Int: CGImage] = [:]
    private var done = Set<Int>()

    func put(_ id: Int, _ image: CGImage?) {
        lock.lock()
        done.insert(id)
        guard let image else { lock.unlock(); return }
        ready[id] = image
        if ready.count > 6, let old = ready.keys.first(where: { $0 != id }) { ready.removeValue(forKey: old) }
        lock.unlock()
    }

    /// Ids finished since last asked (decoded or not).
    func drainDone() -> Set<Int> {
        lock.lock()
        defer { done.removeAll(); lock.unlock() }
        return done
    }

    func take(_ id: Int) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return ready.removeValue(forKey: id)
    }
}

struct LucaGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> LucaGameViewController {
        LucaGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: LucaGameViewController, context: Context) {}
}
