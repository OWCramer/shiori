import LucaKit
import Metal
import SwiftUI
import UIKit

/// Plays a Luca System game (Summer Pockets REFLECTION BLUE) with LucaKit. The scripts tell
/// the stage what to show; the screens the PC game draws in its executable (title, menu,
/// save and load, backlog) are Shiori's own, dressed in the game's art where it has some.
final class LucaGameViewController: UIViewController, UIGestureRecognizerDelegate {
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
    /// MWIN0's shape starts 100 px down, so the window's top edge shows at y 791, as in the
    /// PC game; stretched to the bottom of the screen.
    private let windowRect = CGRect(x: 0, y: 691, width: 1920, height: 389)
    /// The window's teal, measured from the PC game.
    private var windowTint: SIMD4<Float> { SIMD4<Float>(0.0, 0.745, 0.765, settings.windowAlpha) }
    /// The speaker's name plate (mwin1920_0, white, tinted) and the flapping butterfly that
    /// says a tap reads on (__SYS_MW01_KEY00, 24 frames).
    private let namePlate = UIImageView()
    private let pageMarker = UIImageView()
    private let overlay = UIView()
    /// The speaker's name and the line, drawn in the game's own bitmap font (LucaTypeset);
    /// the line is revealed as it types through a mask.
    private let nameView = UIImageView()
    private let textView = UIImageView()
    private let textMask = CAShapeLayer()
    private var typeset: LucaTypeset?
    private var composedKey: String?
    /// Loaded font sizes by "FACE size" (nil: the game has no such size).
    private var loadedFonts: [String: (main: LucaFont, patch: LucaFont?)?] = [:]
    private var shownMessage: LucaMessage?
    private var lastHadFace = false
    private var faceRects: [Int: CGRect] = [:]
    private var revealed = 0
    private var revealTarget = 0
    private var choiceStack: UIStackView?
    /// The island map behind the day's map choice.
    private var mapBackdrop: UIImageView?
    private var shownChoices: [String]?
    private var choiceImages: [CGImage] = []
    private var titleView: UIView?
    private var bootShown = false
    private var systemMenu: LucaSystemMenu?
    private var saveScreen: LucaSaveScreen?
    private var textHidden = false
    private var optionsScreen: LucaOptionsScreen?
    private var messageLog: LucaMessageLog?
    private var settings = LucaSettings()
    private var readLog: LucaReadLog?
    /// Whether the line on screen had been read before (on any playthrough).
    private var lineWasRead = false
    private var lineHasVoice = false
    /// Lines passed since Skip was turned on.
    private var linesSkipped = 0
    private var revealCarry = 0.0
    private var windowBar: LucaWindowBar?
    /// Auto reads on a moment after each line (and its voice) finishes; Skip races to the
    /// next choice. A tap stops either.
    private enum ReadMode { case normal, auto, skip }
    private var readMode = ReadMode.normal
    private var lineDoneAt: CFTimeInterval?
    #if DEBUG
    /// `-VNHubLucaAuto N`: reads on through N lines by itself (first choice picked), and
    /// `-VNHubLucaNewGame YES` starts a new game from the title, for unattended runs;
    /// `-VNHubLucaAutoStopAtChoice YES` stops at the first choice instead.
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
        namePlate.tintColor = UIColor(red: 0, green: 0.55, blue: 0.62, alpha: 0.75)
        overlay.addSubview(namePlate)
        for view in [nameView, textView] {
            view.isUserInteractionEnabled = false
            view.layer.minificationFilter = .trilinear
            overlay.addSubview(view)
        }
        textMask.fillColor = UIColor.white.cgColor
        textView.layer.mask = textMask
        overlay.addSubview(pageMarker)

        // Tap reads on; two-finger tap opens the menu; swipe down shows the backlog; a
        // two-finger hold leaves.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let menu = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        menu.numberOfTouchesRequired = 2
        view.addGestureRecognizer(menu)
        tap.require(toFail: menu)
        // The PC game's touch controls (manual page 2): flick up for the system menu.
        let flick = UISwipeGestureRecognizer(target: self, action: #selector(showMenu))
        flick.direction = .up
        view.addGestureRecognizer(flick)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(showBacklog))
        history.direction = .down
        view.addGestureRecognizer(history)
        let skip = UISwipeGestureRecognizer(target: self, action: #selector(flickedRight))
        skip.direction = .right
        view.addGestureRecognizer(skip)
        let back = UISwipeGestureRecognizer(target: self, action: #selector(flickedLeft))
        back.direction = .left
        view.addGestureRecognizer(back)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldOnWindow(_:)))
        hold.minimumPressDuration = 0.6
        hold.delegate = self
        view.addGestureRecognizer(hold)
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
            if let plate = game.image(Self.namePlateID).flatMap(Self.cgImage) {
                namePlate.image = UIImage(cgImage: plate).withRenderingMode(.alwaysTemplate)
            }
            if let sheet = game.image(Self.pageMarkerID).flatMap(Self.cgImage) {
                let size = sheet.height
                pageMarker.animationImages = (0..<(sheet.width / size)).compactMap {
                    sheet.cropping(to: CGRect(x: $0 * size, y: 0, width: size, height: size)).map { UIImage(cgImage: $0) }
                }
                pageMarker.animationDuration = 0.8
            }
            if let buttons = game.image(Self.choiceSheetID).flatMap(Self.cgImage) {
                // Four states, 225 px each: blue, gold (highlighted), gold (pressed), grey.
                choiceImages = (0..<4).compactMap { buttons.cropping(to: CGRect(x: 0, y: $0 * 225, width: buttons.width, height: 225)) }
            }
            try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            settings = LucaSettings.load(from: saves)
            readLog = LucaReadLog(saves: saves)
            let bar = LucaWindowBar(sheet: game.imageID(named: "legacy_pt").flatMap { game.image($0) }.flatMap(Self.cgImage))
            bar.onPick = { [weak self] item in self?.windowBarPicked(item) }
            bar.isHidden = true
            overlay.addSubview(bar)
            windowBar = bar
            applySettings()
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
        OrientationLock.set(.landscape, in: view.window?.windowScene)
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
        titleView?.frame = view.bounds
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
        audio.nextVoiceLevel = Float(settings.voiceLevel(for: player.message?.speaker))
        for sound in player.sounds { audio.handle(sound, game: game) }
        player.sounds.removeAll()
        for notice in player.notices { show(notice) }
        player.notices.removeAll()
        if let name = player.movie, movie == nil, !movieLoading { play(movie: name, player: player) }
        if stepMovie() { return }
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
            if player.choices != nil, UserDefaults.standard.bool(forKey: "VNHubLucaAutoStopAtChoice") {
                autoLines = 0
            } else if player.choices != nil {
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
        var items: [LucaRenderer.Item] = []
        var shown = Set<Int>()
        /// Pictures on the stage, so effects that left it stop decoding.
        var effectsShown = Set<Int>()
        for layer in player.sortedLayers {
            effectsShown.insert(layer.imageID)
            if let effect = effectFrame(layer.imageID) {
                // An animated effect (MVT), scaled to the size it covers.
                let w = Double(effect.header.shownWidth) * layer.scale, h = Double(effect.header.shownHeight) * layer.scale
                let (x, y) = layer.origin(width: w, height: h, offsetX: 0, offsetY: 0)
                let packing = effect.header.alphaBelow ? 1 : effect.header.alphaRight ? 2 : 0
                items.append(.init(layer: layer, source: .video(effect.frame, packing: packing), rect: CGRect(x: x, y: y, width: w, height: h)))
                continue
            }
            guard let image = player.game.image(layer.imageID), let picture = texture(layer.imageID) else { continue }
            shown.insert(layer.imageID)
            if let baseID = layer.baseImageID, let base = player.game.image(baseID), let baseTexture = texture(baseID) {
                // The layer's whole picture, then the smaller one over it at its own offset.
                shown.insert(baseID)
                let bw = Double(base.width) * layer.scale, bh = Double(base.height) * layer.scale
                let (bx, by) = layer.origin(width: bw, height: bh, offsetX: 0, offsetY: 0)
                items.append(.init(layer: layer, source: .picture(baseTexture), rect: CGRect(x: bx, y: by, width: bw, height: bh)))
                items.append(.init(layer: layer, source: .picture(picture),
                                   rect: CGRect(x: bx + Double(image.offsetX) * layer.scale, y: by + Double(image.offsetY) * layer.scale,
                                                width: Double(image.width) * layer.scale, height: Double(image.height) * layer.scale)))
                continue
            }
            let w = Double(image.width) * layer.scale, h = Double(image.height) * layer.scale
            var (x, y) = layer.origin(width: w, height: h, offsetX: Double(image.offsetX), offsetY: Double(image.offsetY))
            if layer.centred, let anchor = player.game.overlayAnchor(layer.imageID) {
                // Where these pixels sit on the whole sprite, centred like the sprite.
                x = layer.x - Double(anchor.width) * layer.scale / 2 + Double(image.offsetX - anchor.x) * layer.scale
            }
            items.append(.init(layer: layer, source: .picture(picture), rect: CGRect(x: x, y: y, width: w, height: h)))
        }
        // Effects no longer on the stage stop decoding.
        for id in effects.keys where !effectsShown.contains(id) && !effectsLoading.contains(id) { effects[id] = nil }
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
        let windowShown = player.windowVisible && !textHidden && titleView == nil && systemMenu == nil && saveScreen == nil && optionsScreen == nil && messageLog == nil
        let window = LucaRenderer.Window(visible: windowShown, mask: windowMask,
                                         tint: windowTint, rect: windowRect,
                                         face: windowShown && player.message != nil ? face : nil)
        renderer.draw(layers: items, shake: player.shake, window: window, effects: LucaEffects(sepia: player.effects.sepia))
    }

    // MARK: Animated effects

    /// MVT effects on the stage (sun flares, light lines, sparkles), decoding and looping from
    /// when they first appeared.
    private var effects: [Int: (decoder: LucaVideoDecoder, header: WebM.MVTHeader, start: CFTimeInterval)] = [:]
    private var effectsLoading = Set<Int>()
    private var notEffects = Set<Int>()

    /// The frame to show now for effect `id`, starting its decoder the first time (nil while it
    /// loads, or when `id` is a picture).
    private func effectFrame(_ id: Int) -> (frame: LucaVideoDecoder.Frame, header: WebM.MVTHeader)? {
        if let effect = effects[id] {
            guard let frame = effect.decoder.frame(at: CACurrentMediaTime() - effect.start) else { return nil }
            return (frame, effect.header)
        }
        guard !notEffects.contains(id), !effectsLoading.contains(id), let game, let device = renderer?.metalDevice else { return nil }
        guard game.isMVT(id) else { notEffects.insert(id); return nil }
        effectsLoading.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let mvt = game.mvt(id)
            let decoder = mvt.flatMap { LucaVideoDecoder(webm: $0.webm, device: device, loops: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.effectsLoading.remove(id)
                guard let mvt, let decoder else {
                    NSLog("Luca: couldn't play effect %d", id)
                    self.notEffects.insert(id)
                    return
                }
                self.effects[id] = (decoder, mvt.header, CACurrentMediaTime())
            }
        }
        return nil
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
        let visible = player.windowVisible && !textHidden && player.message != nil && systemMenu == nil && saveScreen == nil && optionsScreen == nil && messageLog == nil
        // The PC game shows the name without a plate.
        namePlate.isHidden = true
        let waiting = visible && player.isWaitingForClick && !typing
        if waiting != !pageMarker.isHidden {
            pageMarker.isHidden = !waiting
            if waiting { pageMarker.startAnimating() } else { pageMarker.stopAnimating() }
        }
        nameView.isHidden = !visible
        textView.isHidden = !visible
        if let windowBar {
            windowBar.isHidden = !(visible && settings.shortcutMenu && player.choices == nil)
            windowBar.update(skip: readMode == .skip, auto: readMode == .auto, voice: lineHasVoice)
        }
        if (player.windowFace != nil) != lastHadFace {
            lastHadFace = player.windowFace != nil
            layoutText()
        }
        if player.message != shownMessage {
            shownMessage = player.message
            revealed = 0
            revealCarry = 0
            lineHasVoice = shownMessage.map { player.game.hasVoice($0.voice) } ?? false
            revealTarget = shownMessage?.text.count ?? 0
            if let key = player.messageKey, let readLog {
                lineWasRead = readLog.contains(key)
                readLog.insert(key)
            } else {
                lineWasRead = false
            }
            layoutText()
        }
        if revealed < revealTarget {
            if let speed = settings.lettersPerSecond {
                revealCarry += speed / 60
                let step = Int(revealCarry)
                revealCarry -= Double(step)
                if step > 0 {
                    revealed = min(revealTarget, revealed + step)
                    renderText()
                }
            } else {
                revealed = revealTarget
                renderText()
            }
        }
    }

    /// The window's text geometry, in the game's 1920×1080 space, measured from the PC
    /// game: glyph cells start at x 396 (474 beside a face), the name's at y 791 and the line's
    /// at y 855, lines 56 apart, wrapping at 1300 px.
    private static let textSize = 37, lineHeight = 56, textWidth = 1300
    private static let outline: (UInt8, UInt8, UInt8) = (20, 50, 60)
    private var textLeft: CGFloat { player?.windowFace != nil ? 474 : 396 }

    private func loadFont(_ face: String, _ size: Int) -> (main: LucaFont, patch: LucaFont?)? {
        let key = "\(face) \(size)"
        if let loaded = loadedFonts[key] { return loaded }
        let loaded = game?.font(face: face, size: size)
        loadedFonts[key] = loaded
        return loaded
    }

    /// The fonts for `text` in the chosen face at `size`: that size and its patch, and size 40
    /// (which has every character) when the text has one that size lacks.
    private func fonts(for text: String, size: Int = textSize) -> [LucaFont] {
        let face = settings.font
        guard let loaded = loadFont(face, size) ?? loadFont("GOTHIC1", size) else { return [] }
        var fonts = [loaded.main] + (loaded.patch.map { [$0] } ?? [])
        let missing = text.unicodeScalars.contains { scalar in
            scalar.value > 32 && scalar.value != 0x3000 && !fonts.contains { $0.glyph(scalar) != nil }
        }
        if missing, size != 40, let fallback = loadFont(face, 40)?.main { fonts.append(fallback) }
        return fonts
    }

    /// `text` in the game's font, wrapped at `width` stage pixels: the picture (in stage pixels)
    /// and its typeset.
    func gameText(_ text: String, size: Int = textSize, width: Int, fill: UIColor = .white) -> (image: UIImage, set: LucaTypeset)? {
        let set = LucaTypeset(text, fonts: fonts(for: text, size: size), width: width, lineHeight: size * 3 / 2)
        guard !set.placed.isEmpty, let image = textImage(set, fill: fill) else { return nil }
        return (image, set)
    }

    private func textImage(_ set: LucaTypeset, fill: UIColor) -> UIImage? {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        fill.getRed(&r, green: &g, blue: &b, alpha: &a)
        let pixels = set.render(fill: (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255)), outline: Self.outline, outlineWidth: 2)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: set.usedWidth, height: set.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: set.usedWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Draws the line (and name) when they or their look changed, then reveals as much of the
    /// line as has typed.
    private func renderText() {
        let s = stageScale
        guard s > 0, let message = shownMessage else {
            textView.image = nil
            nameView.image = nil
            typeset = nil
            composedKey = nil
            return
        }
        let colour = lineWasRead && settings.colourReadText
            ? LucaSettings.readTextColours[min(settings.readTextColour, LucaSettings.readTextColours.count - 1)].color : UIColor.white
        let left = textLeft
        let key = "\(message.speaker ?? "")\u{1}\(message.text)\u{1}\(settings.font)\u{1}\(colour)\u{1}\(left)\u{1}\(s)"
        if key != composedKey {
            composedKey = key
            let width = Self.textWidth - Int(left - 396)
            let set = LucaTypeset(message.text, fonts: fonts(for: message.text), width: width, lineHeight: Self.lineHeight)
            typeset = set
            textView.image = textImage(set, fill: colour)
            let top = CGFloat(855 - (Self.lineHeight - Self.textSize - 1) / 2)
            textView.frame = CGRect(x: left * s, y: top * s, width: CGFloat(set.usedWidth) * s, height: CGFloat(set.height) * s)
            textMask.frame = textView.bounds
            if let speaker = message.speaker, !speaker.isEmpty {
                let name = LucaTypeset(speaker, fonts: fonts(for: speaker), width: 900, lineHeight: Self.lineHeight)
                nameView.image = textImage(name, fill: .white)
                nameView.frame = CGRect(x: left * s, y: (top - 64) * s, width: CGFloat(name.usedWidth) * s, height: CGFloat(name.height) * s)
            } else {
                nameView.image = nil
            }
        }
        guard let typeset else { return }
        let path = CGMutablePath()
        for rect in typeset.revealed(revealed) {
            path.addRect(CGRect(x: CGFloat(rect.x) * s, y: CGFloat(rect.y) * s, width: CGFloat(rect.width) * s, height: CGFloat(rect.height) * s))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.path = path
        CATransaction.commit()
    }

    private func layoutText() {
        let s = stageScale
        guard s > 0 else { return }
        namePlate.frame = CGRect(x: (textLeft - 150) * s, y: 712 * s, width: 496 * s, height: 110 * s)
        pageMarker.frame = CGRect(x: 1640 * s, y: 996 * s, width: 72 * s, height: 72 * s)
        let bar = LucaWindowBar.frameInStage
        windowBar?.frame = CGRect(x: bar.minX * s, y: bar.minY * s, width: bar.width * s, height: bar.height * s)
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
            } else if player.isWaitingForClick, settings.skipReadOnly, !lineWasRead {
                // Skip stops at the first line not read before; said so when it couldn't
                // skip anything at all.
                readMode = .normal
                if linesSkipped == 0 {
                    show(.acquired("Skip passes lines you've already read. To skip new lines too, choose All under OPTIONS › Basic › Skip."))
                }
            } else if player.isWaitingForClick {
                linesSkipped += 1
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
                if now - done > settings.autoWait(letters: shownMessage?.text.count ?? 0) {
                    lineDoneAt = nil
                    player.click()
                }
            } else {
                lineDoneAt = now
            }
        }
    }

    // MARK: Movies

    /// A movie playing in place of the stage: VP9 through libvpx, its Vorbis soundtrack as the
    /// clock. A tap skips.
    private var movie: (decoder: LucaVideoDecoder, start: CFTimeInterval)?
    private var movieLoading = false

    /// Plays `files/movie/<name>.webm` (the English cut, `<name>_en`, when there is one).
    private func play(movie name: String, player: LucaPlayer) {
        let folder = gameFolder.appendingPathComponent("base/files/movie", isDirectory: true)
        let candidates = ["\(name)_en.webm", "\(name).webm"]
        guard let file = candidates.map({ folder.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let device = renderer?.metalDevice else {
            NSLog("Luca: no movie %@", name)
            player.movieFinished()
            return
        }
        audio.handle(.stopMusic(fadeFrames: 0), game: player.game)
        movieLoading = true
        // Parsing and the soundtrack's decode take a moment; the screen stays black meanwhile.
        DispatchQueue.global(qos: .userInitiated).async {
            let webm = try? WebM(data: Data(contentsOf: file, options: .alwaysMapped))
            let decoder = webm.flatMap { LucaVideoDecoder(webm: $0, device: device) }
            let sound = webm?.vorbisAsOgg().flatMap(LucaAudio.movieBuffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.movieLoading else { return }
                self.movieLoading = false
                guard let decoder else {
                    NSLog("Luca: couldn't play %@", file.lastPathComponent)
                    self.player?.movieFinished()
                    return
                }
                if let sound { self.audio.playMovie(sound) }
                self.movie = (decoder, CACurrentMediaTime())
            }
        }
    }

    /// Draws the movie's frame for now; true while a movie owns the screen.
    private func stepMovie() -> Bool {
        if movieLoading {
            renderer?.drawMovie(nil)
            return true
        }
        guard let movie else { return false }
        let time = audio.movieTime ?? (CACurrentMediaTime() - movie.start)
        let frame = movie.decoder.frame(at: time)
        renderer?.drawMovie(frame)
        if movie.decoder.finished || time > movie.decoder.duration + 0.5 { endMovie() }
        return true
    }

    private func endMovie() {
        movieLoading = false
        movie = nil
        audio.stopMovie()
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
        stack.spacing = compact ? 0 : 6 * stageScale
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
            let detail = player.choiceDetails.indices.contains(index) ? player.choiceDetails[index] : nil
            // The choice in the game's font; a map place's first line smaller below it.
            let lines = [gameText(choice, width: 1100)?.image,
                         detail.flatMap { $0.isEmpty ? nil : gameText($0, size: 28, width: 1100, fill: UIColor(white: 1, alpha: 0.92))?.image }]
            let banner = LucaChoiceBanner(images: choiceImages, title: choice, detail: detail, rendered: lines.compactMap { $0 },
                                          scale: stageScale, compact: compact) { [weak self] in self?.player?.choose(index) }
            stack.addArrangedSubview(banner)
        }
        overlay.addSubview(stack)
        choiceStack = stack
        layoutChoices()
    }

    private func layoutChoices() {
        guard let stack = choiceStack else { return }
        // The banners are 1680 game px wide, glow included.
        let width = choiceImages.isEmpty ? min(overlay.bounds.width * 0.7, 640) : 1680 * stageScale
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        let y = min(max(10, overlay.bounds.height * 0.42 - size.height / 2), overlay.bounds.height - size.height - 10)
        stack.frame = CGRect(x: (overlay.bounds.width - width) / 2, y: max(10, y), width: width, height: size.height)
        mapBackdrop?.frame = overlay.bounds
    }

    // MARK: Input

    /// Taps on the choice banners (and other controls) go to them, not to reading on.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func tapped() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil, let player else { return }
        if movieLoading { return }
        if let movie {
            if CACurrentMediaTime() - movie.start > 1 { endMovie() }
            return
        }
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
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil, let player, let game else { return }
        let sheet = game.imageID(named: "systemmenuen").flatMap { game.image($0) }.flatMap(Self.cgImage)
        audio.playSystem("TOGGLE", game: game)
        let menu = LucaSystemMenu(sheet: sheet) { [weak self] item in
            guard let self else { return }
            self.systemMenu?.removeFromSuperview()
            self.systemMenu = nil
            guard let item else { return }
            switch item {
            case .save: self.presentSlots(saving: true)
            case .load: self.presentSlots(saving: false)
            case .record: self.showBacklog()
            case .options: self.presentOptions()
            case .title:
                self.autosave()
                self.showTitle()
            case .quickSave:
                try? LucaSaves.write(player.saveState(), slot: LucaSaves.quickSlot, thumbnail: self.thumbnail(), in: self.saves)
                self.show(.acquired("Quick saved"))
            case .quickLoad:
                if let save = LucaSaves.read(slot: LucaSaves.quickSlot, in: self.saves) { self.start(state: save.state) }
            case .manual: self.presentManual()
            case .exit: self.leave()
            }
        }
        menu.frame = view.bounds
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(menu)
        systemMenu = menu
    }

    @objc private func showBacklog() {
        guard titleView == nil, presentedViewController == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil,
              systemMenu == nil, let player, let game else { return }
        readMode = .normal
        audio.playSystem("TOGGLE", game: game)
        let log = LucaMessageLog(game: game, lines: player.backlog, typeset: { [weak self] text, width, fill in
            guard let self else { return nil }
            let set = LucaTypeset(text, fonts: self.fonts(for: text), width: width, lineHeight: Self.lineHeight)
            guard !set.placed.isEmpty else { return nil }
            return (CGSize(width: set.usedWidth, height: set.height), { [weak self] in self?.textImage(set, fill: fill) })
        }, onVoice: { [weak self] line in
            guard let self, let game = self.game else { return }
            self.audio.replayVoice(line.voice, level: Float(self.settings.voiceLevel(for: line.speaker)), game: game)
        }, onClose: { [weak self] in
            guard let self else { return }
            if let game = self.game { self.audio.playSystem("TOGGLE", game: game) }
            self.messageLog?.removeFromSuperview()
            self.messageLog = nil
        })
        log.onReturn = { [weak self] index in
            guard let self, let player = self.player else { return }
            let serial = player.serial(ofBacklogLine: index)
            guard player.canReturn(to: serial) else {
                self.show(.acquired("That line is too far back to return to."))
                return
            }
            let alert = UIAlertController(title: "Return to this line?", message: player.backlog[index].text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Return", style: .default) { _ in
                self.messageLog?.removeFromSuperview()
                self.messageLog = nil
                self.returnTo(line: serial)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
        log.frame = view.bounds
        log.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(log)
        log.scrollToEnd()
        messageLog = log
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
        OrientationLock.set(.all, in: view.window?.windowScene)
        onExit()
    }

    // MARK: Title

    private func showTitle() {
        guard let game else { return }
        player = nil
        audio.handle(.stopVoice, game: game)
        audio.handle(.stopEffect(channel: -1, fadeFrames: 0), game: game)
        audio.handle(.stopMusic(fadeFrames: 30), game: game)
        titleView?.removeFromSuperview()
        // The boot sequence (warning and logos) plays once per launch; after that, the title.
        let title = LucaTitleScreen(game: game, boot: !bootShown, onSound: { [weak self] sound in
            guard let self, let game = self.game else { return }
            if sound == "music" {
                self.audio.handle(.music(id: Self.titleMusicID, fadeFrames: 60), game: game)
            } else {
                self.audio.playSystem(sound, game: game)
            }
        }, onAction: { [weak self] action in
            guard let self else { return }
            switch action {
            case .start: self.start(state: nil)
            case .load: self.presentSlots(saving: false)
            case .options: self.presentOptions()
            case .manual: self.presentManual()
            case .exit: self.leave()
            }
        })
        bootShown = true
        title.frame = view.bounds
        title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(title)
        titleView = title
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "VNHubLucaNewGame") {
            UserDefaults.standard.removeObject(forKey: "VNHubLucaNewGame")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start(state: nil) }
        }
        #endif
        nameView.isHidden = true
        textView.isHidden = true
        choiceStack?.removeFromSuperview()
        choiceStack = nil
        shownChoices = nil
    }

    private func start(state: LucaPlayer.State?) {
        guard let game else { return }
        do {
            let player = try LucaPlayer(game: game)
            if let state { try player.restore(state) }
            player.stopsVoiceOnClick = settings.voiceStopsOnTap
            self.player = player
            readMode = .normal
            audio.handle(.stopMusic(fadeFrames: 30), game: game)
            lastDraw = -1
            shownMessage = nil
            textHidden = false
            if let titleView {
                titleView.removeFromSuperview()
                self.titleView = nil
            }
        } catch {
            NSLog("Luca: couldn't start: %@", String(describing: error))
        }
    }

    // MARK: Manual and options

    /// The game's digital manual: its 16 English pages over manual_BG, swiped or tapped through.
    private func presentManual() {
        guard let game else { return }
        let pages = (1...16).compactMap { game.imageID(named: String(format: "en_manual%02d", $0)) }
        let pager = LucaManualViewController(game: game, pages: pages, background: game.imageID(named: "manual_BG"))
        pager.modalPresentationStyle = .overFullScreen
        present(pager, animated: true)
    }

    private func presentOptions() {
        guard let game, optionsScreen == nil, messageLog == nil else { return }
        audio.playSystem("TOGGLE", game: game)
        let screen = LucaOptionsScreen(game: game, settings: settings, onSound: { [weak self] name in
            guard let self, let game = self.game else { return }
            self.audio.playSystem(name, game: game)
        }, onChange: { [weak self] settings in
            self?.settings = settings
            self?.applySettings()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.settings.save(to: self.saves)
            self.optionsScreen?.removeFromSuperview()
            self.optionsScreen = nil
        })
        screen.onSample = { [weak self] name in
            // The character's most recent voiced line, at the level being set.
            guard let self, let game = self.game,
                  let line = self.player?.backlog.last(where: { $0.speaker == name && game.hasVoice($0.voice) }) else { return }
            self.audio.replayVoice(line.voice, level: Float(self.settings.voiceLevel(for: name)), game: game)
        }
        screen.frame = view.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen)
        optionsScreen = screen
    }

    private func applySettings() {
        audio.musicVolume = Float(settings.music)
        audio.effectVolume = Float(settings.effects)
        audio.voiceVolume = Float(settings.voice)
        audio.systemVolume = Float(settings.system)
        player?.stopsVoiceOnClick = settings.voiceStopsOnTap
        renderText()
    }

    // MARK: Shortcut menu

    private func windowBarPicked(_ item: LucaWindowBar.Item) {
        guard let game else { return }
        switch item {
        case .menu:
            showMenu()
        case .skip:
            readMode = readMode == .skip ? .normal : .skip
            linesSkipped = 0
            audio.playSystem("TOGGLE", game: game)
        case .auto:
            readMode = readMode == .auto ? .normal : .auto
            lineDoneAt = nil
            audio.playSystem("TOGGLE", game: game)
        case .voice:
            if lineHasVoice, let line = shownMessage {
                audio.replayVoice(line.voice, level: Float(settings.voiceLevel(for: line.speaker)), game: game)
            }
        }
    }

    /// Manual page 10: a flick right starts Skip; holding a finger on the window toggles Auto.
    @objc private func flickedRight() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil,
              player?.choices == nil else { return }
        windowBarPicked(.skip)
    }

    /// Manual page 10: a flick left goes back a line.
    @objc private func flickedLeft() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil,
              messageLog == nil, movie == nil, let serial = player?.previousLine else { return }
        returnTo(line: serial)
    }

    private func returnTo(line serial: Int) {
        guard let player else { return }
        do {
            try player.returnTo(line: serial)
        } catch {
            NSLog("Luca: couldn't go back: %@", String(describing: error))
            return
        }
        readMode = .normal
        lastDraw = -1
        renderer?.endFade()
        transitionRunning = false
    }

    @objc private func heldOnWindow(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, titleView == nil, presentedViewController == nil, systemMenu == nil,
              saveScreen == nil, optionsScreen == nil , messageLog == nil, player?.choices == nil else { return }
        let point = recognizer.location(in: overlay)
        guard point.y > windowRect.minY * stageScale else { return }
        windowBarPicked(.auto)
    }

    // MARK: Saves

    private func autosave() {
        readLog?.save()
        guard let player, !player.finished else { return }
        try? LucaSaves.write(player.saveState(), slot: 0, thumbnail: thumbnail(), in: saves)
    }

    private func thumbnail() -> Data? {
        guard let image = renderer?.snapshot(width: 384, height: 216) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }

    private func presentSlots(saving: Bool) {
        guard let game else { return }
        let thumbnail = saving ? thumbnail() : nil
        var screen: LucaSaveScreen?
        screen = LucaSaveScreen(game: game, folder: saves, saving: saving) { [weak self] slot in
            guard let self else { return }
            screen?.removeFromSuperview()
            self.saveScreen = nil
            guard let slot else { return }
            if saving {
                if let player = self.player {
                    try? LucaSaves.write(player.saveState(), slot: slot, thumbnail: thumbnail, in: self.saves)
                    self.audio.playSystem("TOGGLE", game: game)
                }
            } else if let save = LucaSaves.read(slot: slot, in: self.saves) {
                self.start(state: save.state)
            }
        }
        guard let screen else { return }
        audio.playSystem("TOGGLE", game: game)
        screen.frame = view.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen)
        saveScreen = screen
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
    /// mwin1920_0 in PARTS.PAK: the name plate.
    static let namePlateID = 64_123
    /// __SYS_MW01_KEY00 in PARTS.PAK: the flapping butterfly, 24 frames of 72 px.
    static let pageMarkerID = 64_004
    /// __SYS_SEL_BTN02 in OTHCG.PAK: the choice banners.
    static let choiceSheetID = 25_170
    /// BGM01 in MUSIC.PAK.
    static let titleMusicID = 100_001
}

/// A choice drawn as the game's banner: blue, gold while pressed, the text centred on it.
private final class LucaChoiceBanner: UIControl {
    private let background = UIImageView()
    private let images: [CGImage]
    private let action: () -> Void

    /// `rendered`: the title (and detail) already drawn in the game's font, in stage pixels;
    /// without them the system font draws `title` and `detail`.
    init(images: [CGImage], title: String, detail: String?, rendered: [UIImage] = [], scale: CGFloat, compact: Bool,
         action: @escaping () -> Void) {
        self.images = images
        self.action = action
        super.init(frame: .zero)
        background.contentMode = .scaleToFill
        background.image = images.first.map { UIImage(cgImage: $0) }
        if images.isEmpty {
            background.backgroundColor = UIColor(red: 0.05, green: 0.45, blue: 0.7, alpha: 0.85)
            background.layer.cornerRadius = 8
        }
        addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        let height = (compact ? 112 : 148) * scale
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.centerYAnchor.constraint(equalTo: centerYAnchor),
            background.heightAnchor.constraint(equalToConstant: 225 * scale),
        ])
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        if !rendered.isEmpty {
            let column = UIStackView(arrangedSubviews: rendered.map { image in
                let view = UIImageView(image: image)
                view.layer.minificationFilter = .trilinear
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: image.size.width * scale),
                    view.heightAnchor.constraint(equalToConstant: image.size.height * scale),
                ])
                return view
            })
            column.axis = .vertical
            column.alignment = .center
            column.spacing = -8 * scale
            column.isUserInteractionEnabled = false
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.centerXAnchor.constraint(equalTo: centerXAnchor),
                column.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }
        let label = UILabel()
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: max(13, 46 * scale), weight: .medium), .foregroundColor: UIColor.white,
        ])
        label.layer.shadowColor = UIColor(red: 0, green: 0.12, blue: 0.3, alpha: 1).cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 2.5
        label.layer.shadowOffset = .zero
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: UIFont.systemFont(ofSize: max(10, 30 * scale)), .foregroundColor: UIColor(white: 1, alpha: 0.9),
            ]))
        }
        label.attributedText = text
        label.numberOfLines = 2
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        // A banner row is 225 px with its glow; compact lists overlap the glows.
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard images.count > 2 else { return }
            background.image = UIImage(cgImage: isHighlighted ? images[2] : images[0])
        }
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
