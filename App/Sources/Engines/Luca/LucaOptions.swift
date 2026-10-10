import LucaKit
import UIKit

/// The player's settings for a Luca System game, kept with its saves (`saves/luca-settings.json`)
/// so they travel with them. Sliders are 0…1.
struct LucaSettings: Codable, Equatable {
    /// Basic: Skip passes only lines already read (else everything).
    var skipReadOnly = true
    /// Basic: a tap that reads on stops the voice (else it plays until the next voice).
    var voiceStopsOnTap = true
    /// Basic: the MENU / SKIP / AUTO / VOICE column right of the window (the Shortcut Menu).
    var shortcutMenu = true
    /// Text1: the face (`LucaGame.fontFaces`).
    var font = "GOTHIC1"
    var windowTransparency = 0.5
    var colourReadText = true
    var readTextColour = 0
    /// Text2: 1 shows each line at once.
    var textSpeed = 0.73
    /// Text2: Auto's wait per letter and the wait added to it.
    var autoWaitPerLetter = 0.2
    var autoBaseWait = 0.4
    /// Sound.
    var music = 0.8
    var effects = 0.9
    var voice = 1.0
    var system = 0.9
    /// Voice: each character's own level, by English name (missing means 1).
    var characterVoices: [String: Double] = [:]

    func voiceLevel(for speaker: String?) -> Double {
        speaker.flatMap { characterVoices[$0] } ?? 1
    }

    static let readTextColours: [(name: String, color: UIColor)] = [
        ("Blue", UIColor(red: 0.62, green: 0.86, blue: 1, alpha: 1)),
        ("Yellow", UIColor(red: 1, green: 0.93, blue: 0.6, alpha: 1)),
        ("Grey", UIColor(white: 0.78, alpha: 1)),
    ]

    /// Letters per second (`nil`: all at once).
    var lettersPerSecond: Double? { textSpeed >= 0.99 ? nil : 10 * pow(30, textSpeed) }
    /// Seconds Auto waits after a line of `count` letters (and its voice) finishes.
    func autoWait(letters count: Int) -> Double { autoBaseWait * 3 + autoWaitPerLetter * 0.05 * Double(count) }
    /// The window's opacity for a game whose window is `base` opaque at the slider's middle
    /// (as the PC game starts).
    func windowAlpha(base: Float) -> Float { min(1, base * Float(2 * (1 - windowTransparency))) }

    static func url(in saves: URL) -> URL { saves.appendingPathComponent("luca-settings.json") }

    /// The saved settings over the defaults, so settings added later keep their defaults.
    static func load(from saves: URL) -> LucaSettings {
        guard let data = try? Data(contentsOf: url(in: saves)),
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaults = (try? JSONEncoder().encode(LucaSettings()))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return LucaSettings() }
        let merged = defaults.merging(saved) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: merged))
            .flatMap { try? JSONDecoder().decode(LucaSettings.self, from: $0) } ?? LucaSettings()
    }

    func save(to saves: URL) {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url(in: saves), options: .atomic) }
    }
}

/// Lines already read, across every playthrough (`saves/luca-read.bin`, one 64-bit key per line),
/// for Skip's "Previously Read Only" and the read-text colour.
final class LucaReadLog {
    private var keys = Set<UInt64>()
    private var dirty = false
    private let url: URL

    init(saves: URL) {
        url = saves.appendingPathComponent("luca-read.bin")
        if let data = try? Data(contentsOf: url) {
            data.withUnsafeBytes { raw in
                for i in 0..<(raw.count / 8) { keys.insert(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self))) }
            }
        }
    }

    func contains(_ key: UInt64) -> Bool { keys.contains(key) }

    func insert(_ key: UInt64) {
        if keys.insert(key).inserted { dirty = true }
    }

    func save() {
        guard dirty else { return }
        var data = Data(capacity: keys.count * 8)
        for key in keys { withUnsafeBytes(of: key.littleEndian) { data.append(contentsOf: $0) } }
        try? data.write(to: url, options: .atomic)
        dirty = false
    }
}

/// Cuts pieces out of the game's UI sheets, trimmed to their pixels.
struct LucaArt {
    let game: LucaGame

    func picture(_ name: String) -> CGImage? {
        game.imageID(named: name).flatMap { game.image($0) }.flatMap(LucaGameViewController.cgImage)
    }

    /// The part of `rect` in the picture that holds pixels (alpha over 24).
    func piece(_ name: String, in rect: CGRect) -> CGImage? {
        guard let id = game.imageID(named: name), let image = game.image(id), let cg = LucaGameViewController.cgImage(image) else { return nil }
        let r = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) where image.rgba[(y * image.width + x) * 4 + 3] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}

// MARK: Options screen

/// The game's OPTIONS screen (manual pages 12–15), rebuilt from its art: options_bg, the tab
/// strip (options_tab_en, its lit words in options_tab2_en), the boxes and slider pieces of
/// options_parts. Pages that only concern a keyboard, mouse or the PC's window say so.
final class LucaOptionsScreen: UIView, UIGestureRecognizerDelegate {
    enum Tab: Int, CaseIterable { case basic, text1, text2, sound, voice, keyboard, mouse, touch, system }

    private let art: LucaArt
    private(set) var settings: LucaSettings
    private let onChange: (LucaSettings) -> Void
    private let onClose: () -> Void
    private let onSound: (String) -> Void
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let page = UIView(frame: CGRect(x: 0, y: 112, width: 1920, height: 898))
    private var tabLights: [UIImageView] = []
    private var tab = Tab.basic
    private let pieces: Pieces
    /// The voiced characters (English names) and their faces (a row of square cells,
    /// `VOICE_ICONRB` in REFLECTION BLUE), in the
    /// order `_voice_param` lists them.
    private let characters: [(name: String, face: CGImage?)]
    /// Plays a line of the named character's (a tap on a face on the Voice page).
    var onSample: ((String) -> Void)?

    struct Pieces {
        var on: UIImage?
        var off: UIImage?
        var track: UIImage?
        var fill: UIImage?
        var knob: UIImage?
        var back: (plain: CGImage?, lit: CGImage?)
    }

    init(game: LucaGame, settings: LucaSettings, voiceFaces: (name: String, cell: Int)?, onSound: @escaping (String) -> Void,
         onChange: @escaping (LucaSettings) -> Void, onClose: @escaping () -> Void) {
        art = LucaArt(game: game)
        self.settings = settings
        self.onChange = onChange
        self.onClose = onClose
        self.onSound = onSound
        func stretchable(_ image: CGImage?, _ cap: CGFloat) -> UIImage? {
            image.map { UIImage(cgImage: $0).resizableImage(withCapInsets: UIEdgeInsets(top: cap, left: cap, bottom: cap, right: cap)) }
        }
        let icons = art.picture("system_icon_1920_en")
        pieces = Pieces(
            on: stretchable(art.piece("options_parts", in: CGRect(x: 150, y: 0, width: 155, height: 92)), 20),
            off: stretchable(art.piece("options_parts", in: CGRect(x: 305, y: 150, width: 105, height: 100)), 8),
            track: stretchable(art.piece("options_parts", in: CGRect(x: 0, y: 266, width: 1000, height: 24)), 6),
            fill: stretchable(art.piece("options_parts", in: CGRect(x: 0, y: 292, width: 1000, height: 16)), 3),
            knob: art.piece("options_parts", in: CGRect(x: 960, y: 74, width: 40, height: 52)).map { UIImage(cgImage: $0) },
            back: (icons?.cropping(to: CGRect(x: 4 * 270, y: 0, width: 270, height: 270)),
                   icons?.cropping(to: CGRect(x: 4 * 270, y: 270, width: 270, height: 270))))
        let faceArt = LucaArt(game: game)
        let faces = voiceFaces.flatMap { faceArt.picture($0.name) }
        let cell = voiceFaces?.cell ?? 0
        characters = game.voiceCharacters().enumerated().compactMap { index, names in
            // The two "Misc" groups have no name a line can be matched to.
            names.english.hasPrefix("Misc") ? nil
                : (names.english, faces?.cropping(to: CGRect(x: index * cell, y: 0, width: cell, height: cell)))
        }
        super.init(frame: .zero)
        backgroundColor = .black
        stage.layer.anchorPoint = .zero
        stage.clipsToBounds = true
        addSubview(stage)
        let background = UIImageView(image: art.picture("options_bg").map { UIImage(cgImage: $0) })
        background.frame = stage.bounds
        stage.addSubview(background)
        buildTabs()
        stage.addSubview(page)

        let back = LucaIconButton(plain: pieces.back.plain, lit: pieces.back.lit)
        back.frame = CGRect(x: 1740, y: 905, width: 170, height: 170)
        back.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        stage.addSubview(back)

        let reset = LucaOptionButton(title: "Default", pieces: pieces)
        reset.frame = CGRect(x: 60, y: 1020, width: 220, height: 52)
        reset.addAction(UIAction { [weak self] _ in self?.restoreDefaults() }, for: .touchUpInside)
        stage.addSubview(reset)
        show(.basic)

        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(close))
        swipe.direction = .down
        swipe.delegate = self
        addGestureRecognizer(swipe)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        guard scale > 0 else { return }
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (bounds.width - 1920 * scale) / 2, y: (bounds.height - 1080 * scale) / 2)
    }

    @objc private func close() {
        onSound("TOGGLE")
        onClose()
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    // MARK: Tabs

    private func buildTabs() {
        let strip = UIImageView(image: art.picture("options_tab_en").map { UIImage(cgImage: $0) })
        strip.frame = CGRect(x: 0, y: 8, width: 1920, height: 98)
        stage.addSubview(strip)
        guard let lit = art.picture("options_tab2_en") else { return }
        // options_tab2_en holds the tab words alone, lit; each becomes a button over the strip.
        for (index, span) in Self.columnSpans(lit, gap: 24).enumerated() {
            guard let tab = Tab(rawValue: index) else { break }
            let rect = CGRect(x: span.lowerBound - 12, y: 0, width: span.count + 24, height: 98)
            let light = UIImageView(image: lit.cropping(to: rect).map { UIImage(cgImage: $0) })
            light.frame = rect.offsetBy(dx: 0, dy: 8)
            light.alpha = 0
            stage.addSubview(light)
            tabLights.append(light)
            let button = UIControl(frame: rect.insetBy(dx: -4, dy: 0).offsetBy(dx: 0, dy: 8))
            button.addAction(UIAction { [weak self] _ in
                self?.onSound("TOGGLE")
                self?.show(tab)
            }, for: .touchUpInside)
            stage.addSubview(button)
        }
    }

    /// Column ranges holding solid pixels (the strip has a faint band behind its words), split at gaps of `gap` px or more.
    static func columnSpans(_ image: CGImage, gap minimumGap: Int) -> [Range<Int>] {
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        var used = [Bool](repeating: false, count: width)
        for y in 0..<height { for x in 0..<width where data[(y * width + x) * 4 + 3] > 180 { used[x] = true } }
        var spans: [Range<Int>] = []
        var start: Int?
        var gap = 0
        for x in 0..<width {
            if used[x] {
                if start == nil { start = x }
                gap = 0
            } else if let s = start {
                gap += 1
                if gap >= minimumGap { spans.append(s..<(x - gap + 1)); start = nil; gap = 0 }
            }
        }
        if let s = start { spans.append(s..<width) }
        return spans
    }

    // MARK: Pages

    private var rowY: CGFloat = 0

    private func show(_ tab: Tab) {
        self.tab = tab
        for (index, light) in tabLights.enumerated() { light.alpha = index == tab.rawValue ? 1 : 0 }
        page.subviews.forEach { $0.removeFromSuperview() }
        rowY = 50
        switch tab {
        case .basic:
            choice("Skip", ["Previously Read Only", "All"], settings.skipReadOnly ? 0 : 1) { $0.skipReadOnly = $1 == 0 }
            choice("Voice", ["Stop on Next Message", "Play until Next Voice"], settings.voiceStopsOnTap ? 0 : 1) { $0.voiceStopsOnTap = $1 == 0 }
            choice("Shortcut Menu", ["Show", "Hide"], settings.shortcutMenu ? 0 : 1) { $0.shortcutMenu = $1 == 0 }
        case .text1:
            let faces = LucaGame.fontFaces
            choice("Font", ["Gothic 1", "Gothic 2", "Gothic 3", "Mincho", "Modern"], faces.firstIndex(of: settings.font) ?? 0) {
                $0.font = faces[$1]
            }
            slider("Window Transparency", settings.windowTransparency) { $0.windowTransparency = $1 }
            choice("Color of Previously Read Text", ["On", "Off"], settings.colourReadText ? 0 : 1) { $0.colourReadText = $1 == 0 }
            choice("Read Text Color", LucaSettings.readTextColours.map(\.name), settings.readTextColour) { $0.readTextColour = $1 }
        case .text2:
            slider("Text Speed", settings.textSpeed) { $0.textSpeed = $1 }
            slider("Wait Time Per Character", settings.autoWaitPerLetter) { $0.autoWaitPerLetter = $1 }
            slider("Base Wait Time", settings.autoBaseWait) { $0.autoBaseWait = $1 }
            note("The two waits set how long Auto mode pauses after each line.")
        case .sound:
            slider("Music", settings.music) { $0.music = $1 }
            slider("Sound Effects", settings.effects) { $0.effects = $1 }
            slider("Voice", settings.voice) { $0.voice = $1 }
            slider("System Sounds", settings.system) { $0.system = $1 }
        case .voice:
            voicePage()
        case .keyboard, .mouse:
            note("These settings are for a keyboard and mouse on PC. On iPhone and iPad the game is played by touch; see the Touch page.")
        case .touch:
            note("Tap — read on.   Flick up — System Menu.   Flick down — Message Log.")
            note("SKIP and AUTO beside the message window race ahead or read on by themselves; tap anywhere to stop.")
            note("VOICE plays the line's voice again.   Two-finger tap — System Menu.   Two-finger hold — leave the game.")
        case .system:
            note("Shiori plays the game full screen at the device's own resolution.")
        }
    }

    private func label(_ text: String, at y: CGFloat) {
        let label = UILabel(frame: CGRect(x: 150, y: y, width: 560, height: 80))
        label.text = text
        label.font = .systemFont(ofSize: 40, weight: .semibold)
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.layer.shadowColor = UIColor(red: 0, green: 0.2, blue: 0.3, alpha: 1).cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        page.addSubview(label)
        let rule = UIView(frame: CGRect(x: 150, y: y + 96, width: 1620, height: 2))
        rule.backgroundColor = UIColor(white: 1, alpha: 0.25)
        page.addSubview(rule)
    }

    private func choice(_ title: String, _ options: [String], _ selected: Int, set: @escaping (inout LucaSettings, Int) -> Void) {
        let y = rowY
        label(title, at: y)
        var buttons: [LucaOptionButton] = []
        let width = min(440, (1770 - 760 - CGFloat(options.count - 1) * 24) / CGFloat(options.count))
        for (index, option) in options.enumerated() {
            let button = LucaOptionButton(title: option, pieces: pieces)
            button.frame = CGRect(x: 760 + CGFloat(index) * (width + 24), y: y + 6, width: width, height: 70)
            button.isSelected = index == selected
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                buttons.enumerated().forEach { $0.element.isSelected = $0.offset == index }
                self.onSound("TOGGLE")
                set(&self.settings, index)
                self.onChange(self.settings)
            }, for: .touchUpInside)
            buttons.append(button)
            page.addSubview(button)
        }
        rowY += 130
    }

    private func slider(_ title: String, _ value: Double, set: @escaping (inout LucaSettings, Double) -> Void) {
        let y = rowY
        label(title, at: y)
        let slider = LucaOptionSlider(pieces: pieces)
        slider.frame = CGRect(x: 760, y: y + 6, width: 1000, height: 70)
        slider.value = value
        slider.addAction(UIAction { [weak self, weak slider] _ in
            guard let self, let slider else { return }
            set(&self.settings, slider.value)
            self.onChange(self.settings)
        }, for: .valueChanged)
        page.addSubview(slider)
        rowY += 130
    }

    /// Each character's voice level, two columns of faces and sliders; a tap on a face plays
    /// one of their lines.
    private func voicePage() {
        let rows = (characters.count + 1) / 2
        let rowHeight = min(110, 840 / CGFloat(max(rows, 1)))
        for (index, character) in characters.enumerated() {
            let column = CGFloat(index / rows), row = CGFloat(index % rows)
            let x = 110 + column * 860, y = 20 + row * rowHeight
            let face = UIButton(type: .custom)
            face.setImage(character.face.map { UIImage(cgImage: $0) }, for: .normal)
            face.frame = CGRect(x: x, y: y, width: rowHeight - 12, height: rowHeight - 12)
            face.addAction(UIAction { [weak self] _ in self?.onSample?(character.name) }, for: .touchUpInside)
            page.addSubview(face)
            let label = UILabel(frame: CGRect(x: x + rowHeight, y: y, width: 230, height: rowHeight - 12))
            label.text = character.name
            label.font = .systemFont(ofSize: 34, weight: .semibold)
            label.textColor = .white
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.layer.shadowColor = UIColor(red: 0, green: 0.2, blue: 0.3, alpha: 1).cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
            page.addSubview(label)
            let slider = LucaOptionSlider(pieces: pieces)
            slider.frame = CGRect(x: x + rowHeight + 240, y: y, width: 520, height: rowHeight - 12)
            slider.value = settings.characterVoices[character.name] ?? 1
            slider.addAction(UIAction { [weak self, weak slider] _ in
                guard let self, let slider else { return }
                self.settings.characterVoices[character.name] = slider.value
                self.onChange(self.settings)
            }, for: .valueChanged)
            page.addSubview(slider)
        }
    }

    private func note(_ text: String) {
        let label = UILabel(frame: CGRect(x: 150, y: rowY, width: 1620, height: 110))
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 38, weight: .medium)
        label.textColor = .white
        label.layer.shadowColor = UIColor(red: 0, green: 0.2, blue: 0.3, alpha: 1).cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
        page.addSubview(label)
        rowY += 130
    }

    private func restoreDefaults() {
        onSound("TOGGLE")
        settings = LucaSettings()
        onChange(settings)
        show(tab)
    }
}

/// A box with a word on it: the game's teal box when selected, its pale box otherwise.
final class LucaOptionButton: UIControl {
    private let box = UIImageView()
    private let label = UILabel()
    private let pieces: LucaOptionsScreen.Pieces

    init(title: String, pieces: LucaOptionsScreen.Pieces) {
        self.pieces = pieces
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        box.isUserInteractionEnabled = false
        addSubview(box)
        label.text = title
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 34, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        addSubview(label)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        box.frame = bounds
        label.frame = bounds.insetBy(dx: 14, dy: 4)
    }

    override var isSelected: Bool { didSet { update() } }
    override var isHighlighted: Bool { didSet { update() } }

    private func update() {
        let lit = isSelected || isHighlighted
        box.image = lit ? pieces.on : pieces.off
        box.alpha = isHighlighted && !isSelected ? 0.7 : 1
        label.textColor = lit ? .white : UIColor(red: 0, green: 0.5, blue: 0.58, alpha: 1)
    }
}

/// The game's slider: a grey track, the teal fill up to the value, the white knob. Dragged or
/// tapped anywhere along it.
final class LucaOptionSlider: UIControl {
    private let track = UIImageView()
    private let fill = UIImageView()
    private let knob = UIImageView()
    private let percent = UILabel()

    var value = 0.5 { didSet { setNeedsLayout() } }

    init(pieces: LucaOptionsScreen.Pieces) {
        super.init(frame: .zero)
        track.image = pieces.track
        fill.image = pieces.fill
        knob.image = pieces.knob
        percent.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        percent.textColor = .white
        percent.textAlignment = .right
        for view in [track, fill, knob, percent] as [UIView] { view.isUserInteractionEnabled = false; addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var trackRect: CGRect { CGRect(x: 20, y: bounds.midY - 12, width: bounds.width - 150, height: 24) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rect = trackRect
        track.frame = rect
        fill.frame = CGRect(x: rect.minX + 4, y: rect.midY - 8, width: max(0, (rect.width - 8) * value), height: 16)
        let knobSize = CGSize(width: 34, height: 52)
        knob.frame = CGRect(x: rect.minX + rect.width * value - knobSize.width / 2, y: rect.midY - knobSize.height / 2,
                            width: knobSize.width, height: knobSize.height)
        percent.frame = CGRect(x: rect.maxX + 10, y: 0, width: 110, height: bounds.height)
        percent.text = "\(Int((value * 100).rounded()))"
    }

    private func setValue(at point: CGPoint) {
        let rect = trackRect
        value = min(1, max(0, (point.x - rect.minX) / rect.width))
        sendActions(for: .valueChanged)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        setValue(at: touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        setValue(at: touch.location(in: self))
        return true
    }
}

// MARK: Shortcut menu

/// The column right of the message window (the PC game's Shortcut Menu): MENU, SKIP, AUTO and
/// VOICE from `legacy_pt`, a 4×4 sheet of 240×60 cells — greyed, plain, lit, on.
final class LucaWindowBar: UIView {
    enum Item: Int, CaseIterable { case menu, skip, auto, voice }

    private var buttons: [LucaBarButton] = []
    var onPick: ((Item) -> Void)?

    /// Where the column sits in the game's 1920×1080 space.
    static let frameInStage = CGRect(x: 1743, y: 837, width: 177, height: 240)

    init(sheet: CGImage?) {
        super.init(frame: .zero)
        for item in Item.allCases {
            let states = (0..<4).map { column in
                sheet?.cropping(to: CGRect(x: column * 240, y: item.rawValue * 60, width: 177, height: 60))
            }
            let button = LucaBarButton(states: states)
            button.addAction(UIAction { [weak self] _ in self?.onPick?(item) }, for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let row = bounds.height / 4
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: 0, y: CGFloat(index) * row, width: bounds.width, height: row)
        }
    }

    /// Lights SKIP or AUTO while that mode runs; greys VOICE for unvoiced lines.
    func update(skip: Bool, auto: Bool, voice: Bool) {
        buttons[Item.skip.rawValue].isOn = skip
        buttons[Item.auto.rawValue].isOn = auto
        buttons[Item.voice.rawValue].isEnabled = voice
    }

    /// The buttons are short; a touch a little outside one still counts.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -30, dy: -10).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), !isHidden, alpha > 0.01 else { return nil }
        let row = Int(min(3, max(0, point.y / (bounds.height / 4))))
        return buttons[row].isEnabled ? buttons[row] : self
    }
}

private final class LucaBarButton: UIControl {
    private let imageView = UIImageView()
    private let states: [UIImage?]
    var isOn = false { didSet { if isOn != oldValue { update() } } }

    init(states: [CGImage?]) {
        self.states = states.map { $0.map { UIImage(cgImage: $0) } }
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFit
        addSubview(imageView)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    override var isHighlighted: Bool { didSet { update() } }
    override var isEnabled: Bool { didSet { if isEnabled != oldValue { update() } } }

    /// Whole touches: the bar's own hit-testing picks the row.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -30, dy: -10).contains(point)
    }

    private func update() {
        let index = !isEnabled ? 0 : isOn ? 3 : isHighlighted ? 2 : 1
        imageView.image = states[index]
    }
}
