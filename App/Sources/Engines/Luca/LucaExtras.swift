import LucaKit
import UIKit

/// What the player has reached, for the title's Chapter and Extras screens (Harmonia's PC
/// executable keeps these itself): the story chapters started, the event pictures shown and
/// the music tracks heard. Kept in `saves/luca-extras.json`, so it syncs with the saves.
struct LucaExtrasRecord: Codable, Equatable {
    var chapters: Set<Int> = []
    /// Event picture names shown on stage (`FG_014002`, `EF_011010`, …).
    var pictures: Set<String> = []
    /// MUSIC.PAK ids played.
    var tracks: Set<Int> = []

    private static func file(_ saves: URL) -> URL { saves.appendingPathComponent("luca-extras.json") }

    static func load(from saves: URL) -> LucaExtrasRecord {
        (try? JSONDecoder().decode(LucaExtrasRecord.self, from: Data(contentsOf: file(saves)))) ?? LucaExtrasRecord()
    }

    func save(to saves: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try? encoder.encode(self).write(to: Self.file(saves), options: .atomic)
    }

    /// The chapter number of a story script named like `届けたいメロディー_03章`.
    static func chapter(ofScript name: String) -> Int? {
        guard let match = name.firstMatch(of: /_(\d+)章$/) else { return nil }
        return Int(match.1)
    }

    /// A picture name that counts for the gallery.
    static func isEventPicture(_ name: String) -> Bool {
        name.hasPrefix("FG_") || name.hasPrefix("EF_") || name.hasPrefix("SP_")
    }
}

/// A full-screen page drawn in the game's 1920×1080 space and scaled to fit, closed with its
/// Back word, a two-finger tap or a secondary click.
class LucaExtrasPage: UIViewController {
    let game: LucaGame
    let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    var onSound: (String) -> Void = { _ in }
    var onClose: () -> Void = {}

    init(game: LucaGame) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stage.clipsToBounds = true
        stage.layer.anchorPoint = .zero
        view.addSubview(stage)
        #if os(iOS)
        let close = UITapGestureRecognizer(target: self, action: #selector(closePage))
        close.numberOfTouchesRequired = 2
        view.addGestureRecognizer(close)
        let secondary = UITapGestureRecognizer(target: self, action: #selector(closePage))
        secondary.requireSecondaryClick()
        view.addGestureRecognizer(secondary)
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = min(view.bounds.width / 1920, view.bounds.height / 1080)
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (view.bounds.width - 1920 * scale) / 2, y: (view.bounds.height - 1080 * scale) / 2)
    }

    func picture(_ name: String) -> CGImage? {
        game.imageID(named: name).flatMap { game.image($0) }.flatMap(LucaGameViewController.cgImage)
    }

    /// A full-stage background picture (Harmonia's are 1920 or 1280 wide; both fill the stage).
    func addBackground(_ name: String) {
        let view = UIImageView(image: picture(name).map { UIImage(cgImage: $0) })
        view.frame = stage.bounds
        stage.addSubview(view)
    }

    /// The title sheet's Back word, in the corner.
    func addBack(sheet: CGImage?, row: Int = 9, rowHeight: Int = 110) {
        let button: UIControl
        if let sheet {
            let column = sheet.width / 2
            button = LucaIconButton(plain: sheet.cropping(to: CGRect(x: 0, y: row * rowHeight, width: column, height: rowHeight)),
                                    lit: sheet.cropping(to: CGRect(x: column, y: row * rowHeight, width: column, height: rowHeight)))
            button.frame = CGRect(x: 1920 - CGFloat(column) - 40, y: 1080 - CGFloat(rowHeight) - 20,
                                  width: CGFloat(column), height: CGFloat(rowHeight))
        } else {
            let plain = UIButton(type: .system)
            plain.setTitle("Back", for: .normal)
            plain.titleLabel?.font = .systemFont(ofSize: 56, weight: .medium)
            plain.tintColor = .white
            plain.frame = CGRect(x: 1620, y: 960, width: 260, height: 100)
            button = plain
        }
        button.addAction(UIAction { [weak self] _ in self?.closePage() }, for: .touchUpInside)
        stage.addSubview(button)
    }

    @objc func closePage() {
        onSound("cancel")
        dismiss(animated: true) { [onClose] in onClose() }
    }

    /// A caption in the game's serif look (white with a soft shadow, as the title's words).
    func caption(_ text: String, size: CGFloat, colour: UIColor = .white) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = UIFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        label.textColor = colour
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.6
        label.layer.shadowRadius = 6
        label.layer.shadowOffset = .zero
        return label
    }
}

/// Chapter: the story's chapters over `chapter_bg`, each as its `CHAPTER_n` picture. Chapters
/// reached open there; the rest are blank frames, as in the PC game.
final class LucaChapterPage: LucaExtrasPage {
    private let chapters: [(number: Int, script: String)]
    private let reached: Set<Int>
    private let sheet: CGImage?
    var onChapter: (String) -> Void = { _ in }

    init(game: LucaGame, chapters: [(number: Int, script: String)], reached: Set<Int>, sheet: CGImage?) {
        self.chapters = chapters
        self.reached = reached
        self.sheet = sheet
        super.init(game: game)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addBackground("chapter_bg")
        // Three columns of 448×252 frames (CHAPTER_n's 512×288, shrunk), under the header.
        let frame = picture("ext_chapter_pt")
        let blank = frame?.cropping(to: CGRect(x: 0, y: 100, width: 498, height: 282))
        let width: CGFloat = 448, height: CGFloat = 252, gapX: CGFloat = 64, gapY: CGFloat = 52
        let left = (1920 - 3 * width - 2 * gapX) / 2, top: CGFloat = 170
        for (index, chapter) in chapters.prefix(9).enumerated() {
            let x = left + CGFloat(index % 3) * (width + gapX), y = top + CGFloat(index / 3) * (height + gapY)
            let open = reached.contains(chapter.number)
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: x, y: y, width: width, height: height)
            if open, let image = picture("CHAPTER_\(chapter.number)") {
                button.setImage(UIImage(cgImage: image), for: .normal)
                button.imageView?.contentMode = .scaleAspectFill
                button.layer.borderColor = UIColor(red: 0.73, green: 0.69, blue: 0.64, alpha: 1).cgColor
                button.layer.borderWidth = 4
                #if os(iOS)
                button.highlightsOnHover()
                #endif
                button.addAction(UIAction { [weak self] _ in
                    self?.onSound("title_hit")
                    self?.dismiss(animated: true) { self?.onChapter(chapter.script) }
                }, for: .touchUpInside)
            } else {
                button.setBackgroundImage(blank.map { UIImage(cgImage: $0) }, for: .normal)
                button.isEnabled = false
            }
            stage.addSubview(button)
            let label = caption(chapter.number == 0 ? "Prologue" : "Chapter \(chapter.number)", size: 34,
                                colour: open ? UIColor(white: 0.25, alpha: 1) : UIColor(white: 0.55, alpha: 1))
            label.layer.shadowOpacity = 0
            label.frame = CGRect(x: x, y: y + height + 4, width: width, height: 44)
            stage.addSubview(label)
        }
        addBack(sheet: sheet)
    }
}

/// Gallery: one thumbnail per event picture family (the game's `CGGALLERY_*` sheet), open once
/// any picture of the family has been shown; a tap shows the family's pictures in turn.
final class LucaGalleryPage: LucaExtrasPage {
    private let entries: [(thumb: String, prefix: String)]
    private let seen: Set<String>
    private let sheet: CGImage?

    init(game: LucaGame, entries: [(thumb: String, prefix: String)], seen: Set<String>, sheet: CGImage?) {
        self.entries = entries
        self.seen = seen
        self.sheet = sheet
        super.init(game: game)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addBackground("extra_bg")
        let title = caption("Gallery", size: 64)
        title.frame = CGRect(x: 80, y: 6, width: 400, height: 100)
        title.textAlignment = .left
        stage.addSubview(title)
        // Six columns of 266×148 thumbnails (the sheet's 560×312, shrunk), four rows inside the
        // band between extra_bg's dark bars.
        let width: CGFloat = 266, height: CGFloat = 148, gapX: CGFloat = 30, gapY: CGFloat = 28
        let left = (1920 - 6 * width - 5 * gapX) / 2, top: CGFloat = 170
        for (index, entry) in entries.enumerated() {
            let x = left + CGFloat(index % 6) * (width + gapX), y = top + CGFloat(index / 6) * (height + gapY)
            let pictures = familyPictures(entry.prefix)
            let open = pictures.contains { seen.contains($0) }
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: x, y: y, width: width, height: height)
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
            button.layer.borderWidth = 3
            if open, let thumb = picture(entry.thumb) {
                button.setImage(UIImage(cgImage: thumb), for: .normal)
                button.imageView?.contentMode = .scaleAspectFill
                #if os(iOS)
                button.highlightsOnHover()
                #endif
                let shown = pictures.filter { seen.contains($0) }
                button.addAction(UIAction { [weak self] _ in self?.view(shown) }, for: .touchUpInside)
            } else {
                button.backgroundColor = UIColor(white: 0.18, alpha: 0.85)
                button.isEnabled = false
            }
            stage.addSubview(button)
        }
        addBack(sheet: sheet)
    }

    /// The family's full pictures in order, without the zoomed copies scenes use.
    private func familyPictures(_ prefix: String) -> [String] {
        // Names come from the event archive's own listing (EF_011010, FG_014002, SP_02, …).
        var names: [String] = []
        for id in 0..<Self.maxEventPictures {
            guard let name = game.imageName(Self.firstEventPicture + id) else { continue }
            if name.hasPrefix(prefix), !name.contains("scale"), !name.hasSuffix("_150"), !name.hasSuffix("_200") { names.append(name) }
        }
        return names
    }

    private static let firstEventPicture = 1001
    private static let maxEventPictures = 400

    private func view(_ names: [String]) {
        onSound("title_hit")
        let viewer = LucaPictureViewer(game: game, names: names)
        present(viewer, animated: true)
    }
}

/// One event picture after another, full screen; a tap moves on, past the last it closes.
final class LucaPictureViewer: UIViewController {
    private let game: LucaGame
    private let names: [String]
    private var index = 0
    private let imageView = UIImageView()

    init(game: LucaGame, names: [String]) {
        self.game = game
        self.names = names
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    #if os(iOS)
    override var prefersStatusBarHidden: Bool { true }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.frame = view.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageView)
        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(showNext)))
        show()
    }

    private func show() {
        guard index < names.count, let id = game.imageID(named: names[index]), let image = game.image(id),
              let cg = LucaGameViewController.cgImage(image) else { return }
        UIView.transition(with: imageView, duration: 0.25, options: .transitionCrossDissolve) {
            self.imageView.image = UIImage(cgImage: cg)
        }
    }

    @objc func showNext() {
        index += 1
        if index >= names.count { dismiss(animated: true) } else { show() }
    }
}

/// Music: the soundtrack's tracks in MUSIC.PAK order, playable once heard in the story.
final class LucaMusicPage: LucaExtrasPage {
    private let tracks: [Int]
    private let heard: Set<Int>
    private let sheet: CGImage?
    var onPlay: (Int?) -> Void = { _ in }
    private var buttons: [Int: UIButton] = [:]
    private var playing: Int?

    init(game: LucaGame, tracks: [Int], heard: Set<Int>, sheet: CGImage?) {
        self.tracks = tracks
        self.heard = heard
        self.sheet = sheet
        super.init(game: game)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addBackground("extra_bg")
        let title = caption("Music", size: 64)
        title.frame = CGRect(x: 80, y: 6, width: 400, height: 100)
        title.textAlignment = .left
        stage.addSubview(title)
        let icon = picture("music_icon").map { UIImage(cgImage: $0) }
        // Three columns of rows inside the band.
        let rowsPerColumn = Int((Double(tracks.count) / 3).rounded(.up))
        let columnWidth: CGFloat = 520, rowHeight: CGFloat = min(64, 820 / CGFloat(max(1, rowsPerColumn)))
        let left = (1920 - 3 * columnWidth) / 2, top: CGFloat = 150
        for (index, track) in tracks.enumerated() {
            let x = left + CGFloat(index / rowsPerColumn) * columnWidth, y = top + CGFloat(index % rowsPerColumn) * rowHeight
            let open = heard.contains(track)
            let button = UIButton(type: .custom)
            button.frame = CGRect(x: x, y: y, width: columnWidth - 40, height: rowHeight - 8)
            button.contentHorizontalAlignment = .left
            button.titleLabel?.font = UIFont(name: "Georgia", size: 38) ?? .systemFont(ofSize: 38)
            button.setTitle(open ? "  Track \(index + 1)" : "  – – –", for: .normal)
            button.setTitleColor(open ? UIColor(white: 0.2, alpha: 1) : UIColor(white: 0.55, alpha: 1), for: .normal)
            button.setTitleColor(UIColor(red: 0, green: 0.55, blue: 0.7, alpha: 1), for: .selected)
            if open { button.setImage(icon, for: .normal) }
            button.isEnabled = open
            button.addAction(UIAction { [weak self] _ in self?.toggle(track) }, for: .touchUpInside)
            stage.addSubview(button)
            buttons[track] = button
        }
        addBack(sheet: sheet)
    }

    private func toggle(_ track: Int) {
        playing = playing == track ? nil : track
        for (id, button) in buttons { button.isSelected = id == playing }
        onPlay(playing)
    }
}
