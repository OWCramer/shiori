import LucaKit
import Metal
import SwiftUI
import UIKit
import WebKit

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
    private var renderer: LucaRenderer?
    private var windowMask: MTLTexture?
    /// Pictures on screen now (texture ids), kept when the texture cache trims.
    private var onScreen = Set<Int>()
    /// Pictures being decoded and uploaded off the main thread.
    private let prefetchQueue = DispatchQueue(label: "luca.prefetch", qos: .userInitiated)
    private var prefetching = Set<Int>()
    private let prefetched = LucaPrefetched()
    private var framesSincePrefetch = 0
    private var lastDraw = -1
    private var transitionRunning = false

    // Text window
    private let windowRect = CGRect(x: 0, y: 735, width: 1920, height: 345)
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
        // The stage draws with Metal (LucaRenderer); text, choices and menus sit over it.
        renderer = LucaRenderer()
        if let renderer { view.layer.addSublayer(renderer.layer) }

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
            // MWIN0 is the window's shape in white; the engine tints it.
            windowMask = renderer?.textures.texture(Self.windowImageID, game: game)
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
        if let renderer {
            renderer.layer.frame = frame
            let screen = view.window?.screen.scale ?? UIScreen.main.scale
            renderer.layer.contentsScale = screen
            renderer.layer.drawableSize = CGSize(width: frame.width * screen, height: frame.height * screen)
        }
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
        for notice in player.notices { show(notice) }
        player.notices.removeAll()
        if let movie = player.movie, movieView == nil { play(movie: movie, player: player) }
        if player.finished {
            if let failure = player.failure { NSLog("Luca: stopped: %@", failure) }
            autosave()
            showTitle()
            return
        }
        if player.drawGeneration != lastDraw {
            lastDraw = player.drawGeneration
            if let transition = player.transition, transition.frames > 0 {
                renderer?.beginFade(frames: transition.frames)
                transitionRunning = true
            }
        } else if transitionRunning, player.transition == nil {
            // Finished, or a tap cut it short.
            renderer?.endFade()
            transitionRunning = false
        }
        drawStage(player)
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

    private func drawStage(_ player: LucaPlayer) {
        guard let renderer else { return }
        var items: [(layer: LucaLayer, texture: MTLTexture, rect: CGRect)] = []
        var shown = Set<Int>()
        for layer in player.sortedLayers {
            guard let image = player.game.image(layer.imageID), let texture = texture(layer.imageID) else { continue }
            shown.insert(layer.imageID)
            let w = Double(image.width) * layer.scale, h = Double(image.height) * layer.scale
            let (x, y) = layer.origin(width: w, height: h, offsetX: Double(image.offsetX), offsetY: Double(image.offsetY))
            items.append((layer, texture, CGRect(x: x, y: y, width: w, height: h)))
        }
        var face: (texture: MTLTexture, rect: CGRect)?
        if let layer = player.windowFace, let image = player.game.image(layer.imageID), let texture = texture(layer.imageID) {
            shown.insert(layer.imageID)
            // The face (its expression patch's rectangle) centred in the window's left end.
            let w = Double(image.width), h = Double(image.height)
            if faceRects[layer.imageID] == nil {
                faceRects[layer.imageID] = player.game.faceRect(layer.imageID).map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? CGRect(x: w / 2 - 90, y: h * 0.12, width: 180, height: 150)
            }
            let r = faceRects[layer.imageID]!
            face = (texture, CGRect(x: 215 - r.midX, y: windowRect.minY + 215 - r.midY, width: w, height: h))
        }
        onScreen = shown
        let windowShown = player.windowVisible && !textHidden && titleView == nil
        let window = LucaRenderer.Window(visible: windowShown, mask: windowMask,
                                         tint: SIMD4(0.04, 0.1, 0.22, 0.78), rect: windowRect,
                                         face: windowShown && player.message != nil ? face : nil)
        renderer.draw(layers: items, shake: player.shake, window: window, effects: LucaEffects(sepia: player.effects.sepia))
    }

    /// Every quarter second, decodes and uploads what the script will show next.
    private func prefetch(_ player: LucaPlayer) {
        framesSincePrefetch += 1
        guard framesSincePrefetch >= 15, let game, let cache = renderer?.textures else { return }
        framesSincePrefetch = 0
        prefetching.subtract(prefetched.drainDone())
        for id in player.upcomingImages() where cache.cached(id) == nil && !prefetching.contains(id) && prefetching.count < 4 {
            prefetching.insert(id)
            let store = prefetched
            let keep = onScreen
            prefetchQueue.async {
                if let image = game.image(id), let texture = cache.make(image) { cache.store(id, texture, keep: keep) }
                store.finished(id)
            }
        }
    }

    private func texture(_ id: Int) -> MTLTexture? {
        guard let game, let cache = renderer?.textures else { return nil }
        return cache.texture(id, game: game, keep: onScreen)
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

    // MARK: Movies

    private var movieView: WKWebView?
    private var movieHandler: LucaMovieHandler?

    /// Plays `files/movie/<name>.webm` (the English cut, `<name>_en`, when there is one).
    /// The movies are VP9 WebM, which AVFoundation doesn't play and WebKit does. A tap skips.
    private func play(movie name: String, player: LucaPlayer) {
        let folder = gameFolder.appendingPathComponent("base/files/movie", isDirectory: true)
        let candidates = ["\(name)_en.webm", "\(name).webm"]
        // Ends at most once (the page can report ended, error, a tap and the watchdog).
        movieEnded = false
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) else {
            NSLog("Luca: no movie %@", name)
            player.movieFinished()
            return
        }
        audio.handle(.stopMusic(fadeFrames: 0), game: player.game)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let handler = LucaMovieHandler { [weak self] in self?.endMovie() }
        config.userContentController.add(handler, name: "movie")
        let web = WKWebView(frame: view.bounds, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}video{width:100%;height:100%;object-fit:contain}</style>
        </head><body><video id="v" src="\(file)" autoplay playsinline></video><script>
        const v=document.getElementById('v'), done=()=>webkit.messageHandlers.movie.postMessage('end');
        v.addEventListener('ended',done); v.addEventListener('error',done);
        document.body.addEventListener('click',done);
        // A device that can't decode VP9 (the simulator) never starts: carry on without it.
        setTimeout(()=>{ if (v.currentTime < 0.1) done(); }, 5000);
        </script></body></html>
        """
        try? FileManager.default.createDirectory(at: moviePage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? html.write(to: moviePage, atomically: true, encoding: .utf8)
        // The page sits beside the movies' folder link so the video loads as a sibling file.
        let link = moviePage.deletingLastPathComponent().appendingPathComponent(file)
        try? FileManager.default.removeItem(at: link)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.appendingPathComponent(file))
        web.loadFileURL(moviePage, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        view.addSubview(web)
        movieView = web
        movieHandler = handler
    }

    private var moviePage: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LucaMovie/movie.html")
    }

    private var movieEnded = false

    private func endMovie() {
        guard !movieEnded else { return }
        movieEnded = true
        movieView?.configuration.userContentController.removeScriptMessageHandler(forName: "movie")
        movieView?.removeFromSuperview()
        movieView = nil
        movieHandler = nil
        player?.movieFinished()
    }

    // MARK: Notices

    /// The day's date large in the middle, or an "Acquired" card at the top, fading out.
    private func show(_ notice: LucaNotice) {
        let label = PaddedLabel()
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = .zero
        switch notice {
        case .date(let day):
            label.text = day
            label.font = UIFont.systemFont(ofSize: 44, weight: .light).withDesign(.serif)
            label.sizeToFit()
            label.center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.height * 0.4)
        case .acquired(let text):
            label.text = text
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.backgroundColor = UIColor(red: 0.05, green: 0.16, blue: 0.34, alpha: 0.85)
            label.layer.cornerRadius = 14
            label.clipsToBounds = true
            label.numberOfLines = 2
            let size = label.sizeThatFits(CGSize(width: overlay.bounds.width * 0.7, height: 100))
            label.bounds = CGRect(origin: .zero, size: size)
            label.center = CGPoint(x: overlay.bounds.midX, y: 20 + size.height / 2)
        }
        label.alpha = 0
        overlay.addSubview(label)
        UIView.animate(withDuration: 0.4) { label.alpha = 1 }
        UIView.animate(withDuration: 0.6, delay: 2.4, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
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
            if player.choiceDetails.indices.contains(index), let detail = player.choiceDetails[index] {
                config.subtitle = detail
                config.titleAlignment = .center
            }
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
        guard let image = renderer?.snapshot(width: 384, height: 216) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
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

/// Receives the movie page's "ended" message.
private final class LucaMovieHandler: NSObject, WKScriptMessageHandler {
    let onEnd: () -> Void
    init(onEnd: @escaping () -> Void) { self.onEnd = onEnd }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        onEnd()
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: backgroundColor == nil ? rect : rect.insetBy(dx: 16, dy: 8))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return backgroundColor == nil ? fit : CGSize(width: fit.width + 32, height: fit.height + 16)
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

/// Which prefetched pictures have finished (uploaded or failed).
final class LucaPrefetched: @unchecked Sendable {
    private let lock = NSLock()
    private var done = Set<Int>()

    func finished(_ id: Int) {
        lock.lock()
        done.insert(id)
        lock.unlock()
    }

    /// Ids finished since last asked (decoded or not).
    func drainDone() -> Set<Int> {
        lock.lock()
        defer { done.removeAll(); lock.unlock() }
        return done
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
