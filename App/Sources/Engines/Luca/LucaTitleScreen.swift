import LucaKit
import UIKit

/// REFLECTION BLUE's boot sequence and title screen, as the PC game draws them (it does so in
/// its executable, so Shiori rebuilds them from the game's art): the warning, the VISUAL ARTS,
/// LUCA System and Key logos on white, the summer sky fading in behind the Key logo, the
/// camera panning down to the heroines, then the logo and the menu row. A tap skips ahead.
/// Everything is laid out in the game's 1920×1080 space.
final class LucaTitleScreen: UIView {
    enum Action { case start, load, options, manual, exit, chapter, gallery, music }

    private let game: LucaGame
    private let onAction: (Action) -> Void
    private let onSound: (String) -> Void
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let background = UIImageView()
    private let white = UIView()
    private let bootPictures = [UIImageView(), UIImageView(), UIImageView(), UIImageView()]
    private let keyOverSky = UIImageView()
    private let titleLayer = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private var skipped = false
    private var menuShown = false
    private var timers: [Timer] = []

    /// The menu row: START LOAD OPTIONS MANUAL EXIT (TITLE_MENU01's first row).
    private static let rowHeight = 76
    private static let menuTop: CGFloat = 330
    private static let actions: [Action] = [.start, .load, .options, .manual, .exit]

    init(game: LucaGame, boot: Bool, onSound: @escaping (String) -> Void, onAction: @escaping (Action) -> Void) {
        self.game = game
        self.onAction = onAction
        self.onSound = onSound
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        stage.clipsToBounds = true
        addSubview(stage)

        background.image = picture("__SYS_TM_BGRB01B")
        background.frame = CGRect(x: 0, y: -840, width: 1920, height: 1920)
        stage.addSubview(background)
        keyOverSky.image = picture("logo2")
        keyOverSky.frame = CGRect(x: 824, y: 432, width: 272, height: 216)
        keyOverSky.alpha = 0
        stage.addSubview(keyOverSky)
        buildTitle()
        stage.addSubview(titleLayer)

        white.frame = stage.bounds
        white.backgroundColor = .white
        stage.addSubview(white)
        for (view, name) in zip(bootPictures, ["warning_en", "logo1", "logo0", "logo2b"]) {
            view.image = picture(name)
            view.frame = stage.bounds
            view.alpha = 0
            white.addSubview(view)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        if boot { runBoot() } else { showTitle(animated: false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func removeFromSuperview() {
        timers.forEach { $0.invalidate() }
        super.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        guard scale > 0 else { return }
        // Scaled about its own top-left corner, then placed letterboxed in the middle.
        stage.layer.anchorPoint = .zero
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (bounds.width - 1920 * scale) / 2, y: (bounds.height - 1080 * scale) / 2)
    }

    private func picture(_ name: String) -> UIImage? {
        guard let id = game.imageID(named: name), let image = game.image(id),
              let cg = LucaGameViewController.cgImage(image) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Boot

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            guard self?.skipped == false else { return }
            body()
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func runBoot() {
        titleLayer.alpha = 0
        background.frame.origin.y = 0
        // Timings from the PC game: warning, VISUAL ARTS, LUCA System, Key.
        let steps: [(start: Double, hold: Double)] = [(0.3, 3.4), (4.4, 1.8), (6.9, 1.8), (9.4, 2.0)]
        for (index, step) in steps.enumerated() {
            let view = bootPictures[index]
            after(step.start) { UIView.animate(withDuration: 0.6) { view.alpha = 1 } }
            if index < 3 {
                after(step.start + step.hold) { UIView.animate(withDuration: 0.6) { view.alpha = 0 } }
            }
        }
        after(11.4) { [weak self] in
            guard let self else { return }
            // The sky comes up through the white behind the Key logo.
            self.onSound("music")
            self.keyOverSky.alpha = 1
            UIView.animate(withDuration: 2) { self.white.alpha = 0 }
        }
        after(13.4) { [weak self] in
            guard let self else { return }
            UIView.animate(withDuration: 7, delay: 0, options: [.curveEaseInOut]) {
                self.background.frame.origin.y = -840
            }
            UIView.animate(withDuration: 1.5, delay: 4.5, options: []) { self.keyOverSky.alpha = 0 }
        }
        after(20.6) { [weak self] in self?.showTitle(animated: true) }
    }

    /// The menu words take touches first (they sit among picture layers that don't).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if menuShown {
            for control in titleLayer.subviews.reversed() where control is UIControl && !control.isHidden {
                let local = convert(point, to: control)
                if control.point(inside: local, with: event) { return control }
            }
        }
        return super.hitTest(point, with: event)
    }

    @objc private func tapped() {
        guard !menuShown else { return }
        skipped = true
        timers.forEach { $0.invalidate() }
        onSound("music")
        layer.removeAllAnimations()
        for view in [white, keyOverSky, background, titleLayer] + bootPictures { view.layer.removeAllAnimations() }
        showTitle(animated: true)
    }

    private func showTitle(animated: Bool) {
        menuShown = true
        // The boot layers sit over the menu; once it shows they must not take its touches.
        white.isHidden = true
        white.alpha = 0
        keyOverSky.alpha = 0
        background.frame.origin.y = -840
        if animated {
            titleLayer.alpha = 0
            UIView.animate(withDuration: 1.2) { self.titleLayer.alpha = 1 }
        } else {
            titleLayer.alpha = 1
            onSound("music")
        }
    }

    // MARK: Title

    private func buildTitle() {
        titleLayer.isUserInteractionEnabled = true
        let logo = UIImageView(image: picture("__SYS_RBLOGO02a"))
        logo.frame = CGRect(x: 432, y: 16, width: 1056, height: 304)
        titleLayer.addSubview(logo)

        // The pale band behind the menu: title_bar's vertical fade, stretched across.
        let band = UIImageView(image: picture("title_bar"))
        band.frame = CGRect(x: 0, y: Self.menuTop - 16, width: 1920, height: 108)
        band.alpha = 0.8
        titleLayer.addSubview(band)

        guard let normal = picture("TITLE_MENU01B")?.cgImage, let lit = picture("TITLE_MENU01")?.cgImage else { return }
        let glow = picture("TITLE_MENU01_GLOW")?.cgImage
        let rowRect = CGRect(x: 0, y: 0, width: 1920, height: Self.rowHeight)
        for (index, span) in Self.wordSpans(in: normal, row: 0).enumerated() where index < Self.actions.count {
            let crop = CGRect(x: span.lowerBound, y: 0, width: span.count, height: Self.rowHeight)
            let button = LucaTitleWord(
                normal: normal.cropping(to: crop.offsetBy(dx: 0, dy: rowRect.minY)),
                lit: lit.cropping(to: crop),
                glow: glow?.cropping(to: CGRect(x: crop.minX - 16, y: 0, width: crop.width + 32, height: 108)))
            // Touch-sized: the word plus room around it.
            button.frame = CGRect(x: CGFloat(span.lowerBound) - 40, y: Self.menuTop - 30,
                                  width: CGFloat(span.count) + 80, height: CGFloat(Self.rowHeight) + 60)
            let action = Self.actions[index]
            button.addAction(UIAction { [weak self] _ in
                self?.onSound("title_hit")
                self?.onAction(action)
            }, for: .touchUpInside)
            titleLayer.addSubview(button)
        }
        let copyright = UIImageView(image: picture("TITLE_COPYRIGHT01"))
        copyright.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        titleLayer.insertSubview(copyright, at: 0)
    }

    /// Column ranges holding the words of a strip row (gaps of 40 px or more between words).
    static func wordSpans(in strip: CGImage, row: Int) -> [Range<Int>] {
        let width = strip.width, height = rowHeight
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let rowImage = strip.cropping(to: CGRect(x: 0, y: row * height, width: width, height: height)) else { return [] }
        ctx.draw(rowImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var used = [Bool](repeating: false, count: width)
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > 24 { used[x] = true }
        }
        var spans: [Range<Int>] = []
        var start: Int?
        var gap = 0
        for x in 0..<width {
            if used[x] {
                if start == nil { start = x }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap >= 40 { spans.append(s..<(x - gap + 1)); start = nil; gap = 0 }
            }
        }
        if let s = start { spans.append(s..<width) }
        return spans
    }
}

/// One menu word: dark blue, lit with its glow while pressed.
private final class LucaTitleWord: UIControl {
    private let normalView = UIImageView()
    private let litView = UIImageView()
    private let glowView = UIImageView()

    init(normal: CGImage?, lit: CGImage?, glow: CGImage?) {
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        normalView.image = normal.map { UIImage(cgImage: $0) }
        litView.image = lit.map { UIImage(cgImage: $0) }
        glowView.image = glow.map { UIImage(cgImage: $0) }
        litView.alpha = 0
        glowView.alpha = 0
        for view in [glowView, normalView, litView] { addSubview(view); view.isUserInteractionEnabled = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let word = CGRect(x: 40, y: 30, width: bounds.width - 80, height: 76)
        normalView.frame = word
        litView.frame = word
        glowView.frame = word.insetBy(dx: -16, dy: -16)
    }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.12) {
                self.litView.alpha = self.isHighlighted ? 1 : 0
                self.glowView.alpha = self.isHighlighted ? 1 : 0
            }
        }
    }
}
