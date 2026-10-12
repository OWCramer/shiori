import LucaKit
import UIKit

/// The game's save and load screens, from its art: `save_bg` (pink) or `load_bg` (blue) with
/// SAVE/LOAD running up both edges, 4×2 slot frames per page (`SAVE_BLANK` / `save_cursor`,
/// 328×188), and the page column (`saveload_scrollbar_num`: 1–15, A for the autosave, Q for
/// the quick save) down the right. Slots are Shiori's saves (LucaSaves): page p, slot s is
/// number (p - 1) * 8 + s + 1. A tap on a slot saves or loads; a two-finger tap or flick
/// down closes.
final class LucaSaveScreen: UIView, UIGestureRecognizerDelegate {
    private let game: LucaGame
    private let folder: URL
    private let saving: Bool
    private let onPick: (Int?) -> Void
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let slotLayer = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private var pageLabels: [UIView] = []
    private var page = 1

    static let perPage = 8
    static let pages = 15
    private static let autoPage = 16, quickPage = 17

    private let blankNames: [String]
    private let cursorNames: [String]

    /// `blank` and `cursor`: the slot frame's names to try, as for saving (Load uses the same
    /// names with "load" for "save").
    init(game: LucaGame, folder: URL, saving: Bool, blank: [String], cursor: [String], onPick: @escaping (Int?) -> Void) {
        func forScreen(_ names: [String]) -> [String] {
            saving ? names : names.map { $0.replacingOccurrences(of: "save", with: "load").replacingOccurrences(of: "SAVE", with: "LOAD") }
        }
        blankNames = forScreen(blank)
        cursorNames = forScreen(cursor)
        self.game = game
        self.folder = folder
        self.saving = saving
        self.onPick = onPick
        super.init(frame: .zero)
        backgroundColor = .black
        stage.layer.anchorPoint = .zero
        stage.clipsToBounds = true
        addSubview(stage)
        let prefix = saving ? "save" : "load"
        let background = UIImageView(image: picture("\(prefix)_bg"))
        background.frame = stage.bounds
        stage.addSubview(background)
        let edges = UIImageView(image: picture("\(prefix)_bg_text_1920"))
        edges.frame = stage.bounds
        stage.addSubview(edges)
        stage.addSubview(slotLayer)
        buildPageColumn()
        let close = UITapGestureRecognizer(target: self, action: #selector(closeScreen))
        close.requireSecondaryClick()
        close.delegate = self
        addGestureRecognizer(close)
        let down = UISwipeGestureRecognizer(target: self, action: #selector(closeScreen))
        down.direction = .down
        addGestureRecognizer(down)
        let left = UISwipeGestureRecognizer(target: self, action: #selector(nextPage))
        left.direction = .left
        addGestureRecognizer(left)
        let right = UISwipeGestureRecognizer(target: self, action: #selector(previousPage))
        right.direction = .right
        addGestureRecognizer(right)
        // Open on the page with the newest save.
        if let newest = ((1...(Self.pages * Self.perPage))).compactMap({ slot in
            LucaSaves.read(slot: slot, in: folder).map { (slot, $0.date) }
        }).max(by: { $0.1 < $1.1 }) {
            page = (newest.0 - 1) / Self.perPage + 1
        }
        showPage()
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

    private func picture(_ name: String) -> UIImage? {
        guard let id = game.imageID(named: name), let image = game.image(id),
              let cg = LucaGameViewController.cgImage(image) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Pages

    private func buildPageColumn() {
        guard let strip = picture("saveload_scrollbar_num_1920")?.cgImage else { return }
        // 17 entries (1–15, A, Q), 41 px apart.
        for index in 0..<17 {
            let pageNumber = index + 1
            if saving && pageNumber == Self.autoPage { continue }
            guard let crop = strip.cropping(to: CGRect(x: 0, y: index * 41, width: 72, height: 41)) else { continue }
            let button = LucaIconButton(plain: crop, lit: crop)
            // White numbers on a pale background: tinted in the screen's colour.
            button.tint(saving ? UIColor(red: 0.75, green: 0.2, blue: 0.4, alpha: 1)
                               : UIColor(red: 0.2, green: 0.3, blue: 0.75, alpha: 1))
            button.frame = CGRect(x: 1752, y: 150 + CGFloat(index) * 46, width: 72, height: 41)
            button.addAction(UIAction { [weak self] _ in
                self?.page = pageNumber
                self?.showPage()
            }, for: .touchUpInside)
            stage.addSubview(button)
            pageLabels.append(button)
        }
    }

    @objc func nextPage() {
        page = page % Self.pages + 1
        showPage()
    }

    @objc func previousPage() {
        page = page == 1 ? Self.pages : min(page - 1, Self.pages)
        showPage()
    }

    @objc func closeScreen() { onPick(nil) }

    private var slotsOnPage: [Int] {
        switch page {
        case Self.autoPage: [0]
        case Self.quickPage: [LucaSaves.quickSlot]
        default: (0..<Self.perPage).map { (page - 1) * Self.perPage + $0 + 1 }
        }
    }

    private func showPage() {
        for (i, label) in pageLabels.enumerated() {
            let number = saving && i >= Self.autoPage - 1 ? i + 2 : i + 1
            label.alpha = number == page ? 1 : 0.4
            label.transform = number == page ? CGAffineTransform(scaleX: 1.35, y: 1.35) : .identity
        }
        slotLayer.subviews.forEach { $0.removeFromSuperview() }
        let blank = blankNames.lazy.compactMap { self.picture($0)?.cgImage }.first
        let cursor = cursorNames.lazy.compactMap { self.picture($0)?.cgImage }.first
        for (index, slot) in slotsOnPage.enumerated() {
            let column = index % 4, row = index / 4
            let frame = CGRect(x: 150 + CGFloat(column) * 390, y: 170 + CGFloat(row) * 400, width: 328, height: 188)
            let save = LucaSaves.read(slot: slot, in: folder)
            let tile = LucaSlotTile(frame: frame, blank: blank, cursor: cursor, slot: slot, save: save,
                                    thumbnail: UIImage(contentsOfFile: LucaSaves.url(slot: slot, in: folder, ext: "jpg").path),
                                    tint: saving ? UIColor(red: 0.85, green: 0.3, blue: 0.5, alpha: 1)
                                                 : UIColor(red: 0.25, green: 0.4, blue: 0.85, alpha: 1))
            tile.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if !self.saving, save == nil { return }
                self.onPick(slot)
            }, for: .touchUpInside)
            slotLayer.addSubview(tile)
        }
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    /// Slots and page numbers take touches before the swipes and close gesture.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for control in (slotLayer.subviews + pageLabels).reversed() where control is UIControl {
            if control.point(inside: convert(point, to: control), with: event) { return control }
        }
        return super.hitTest(point, with: event)
    }
}

/// One save slot: its frame (the cursor frame while pressed), thumbnail, and the date and line
/// written below it.
private final class LucaSlotTile: UIControl {
    private let frameView = UIImageView()
    private let blank: UIImage?
    private let cursor: UIImage?

    init(frame: CGRect, blank: CGImage?, cursor: CGImage?, slot: Int, save: LucaSaves.Save?, thumbnail: UIImage?, tint: UIColor) {
        self.blank = blank.map { UIImage(cgImage: $0) }
        self.cursor = cursor.map { UIImage(cgImage: $0) }
        super.init(frame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height + 150))
        #if os(iOS)
        highlightsOnHover()
        #endif
        if let thumbnail, save != nil {
            let shot = UIImageView(image: thumbnail)
            shot.frame = CGRect(x: 8, y: 8, width: frame.width - 16, height: frame.height - 16)
            shot.contentMode = .scaleAspectFill
            shot.clipsToBounds = true
            addSubview(shot)
        }
        frameView.image = self.blank
        frameView.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        addSubview(frameView)
        let label = UILabel(frame: CGRect(x: 4, y: frame.height + 8, width: frame.width - 8, height: 130))
        label.numberOfLines = 3
        label.textColor = UIColor(white: 0.15, alpha: 1)
        let number = slot == 0 ? "AUTO" : (slot == LucaSaves.quickSlot ? "QUICK" : String(format: "No.%03d", slot))
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: UIFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: tint,
        ])
        if let save {
            text.append(NSAttributedString(string: "  " + save.date.formatted(date: .numeric, time: .shortened) + "\n",
                                           attributes: [.font: UIFont.systemFont(ofSize: 24, weight: .medium),
                                                        .foregroundColor: UIColor(white: 0.2, alpha: 1)]))
            text.append(NSAttributedString(string: save.text, attributes: [.font: UIFont.systemFont(ofSize: 22),
                                                                           .foregroundColor: UIColor(white: 0.25, alpha: 1)]))
        } else {
            text.append(NSAttributedString(string: "  NO DATA", attributes: [.font: UIFont.systemFont(ofSize: 24, weight: .medium),
                                                                             .foregroundColor: UIColor(white: 0.45, alpha: 1)]))
        }
        label.attributedText = text
        addSubview(label)
        for view in subviews { view.isUserInteractionEnabled = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { frameView.image = isHighlighted ? (cursor ?? blank) : blank }
    }
}
