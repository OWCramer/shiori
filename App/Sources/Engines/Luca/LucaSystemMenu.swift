import LucaKit
import UIKit

/// The game's system menu (manual page 9): the stage dimmed under a deep blue veil, nine round
/// icons in two rows (SAVE LOAD RECORD OPTIONS TITLE / Q.SAVE Q.LOAD MANUAL EXIT), each lit
/// with its butterfly while pressed. From `systemmenuen`: a 5×4 grid of 280 px cells, rows 0
/// and 2 plain, rows 1 and 3 lit. A tap outside the icons closes it.
final class LucaSystemMenu: UIView, UIGestureRecognizerDelegate {
    enum Item: Int, CaseIterable { case save, load, record, options, title, quickSave, quickLoad, manual, exit }

    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let onPick: (Item?) -> Void

    enum Layout {
        /// REFLECTION BLUE's `systemmenuen`.
        case grid(CGImage?)
        /// The Prototype kit's `system_icon_1920_en` (Harmonia): Save, Load, Options, Title,
        /// Back, Quick Save, Quick Load, Manual, Voice Collection in 270 px cells, plain over
        /// lit, on `system_BG`.
        case icons(CGImage?, background: CGImage?)
    }

    init(layout: Layout, onPick: @escaping (Item?) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.0, green: 0.07, blue: 0.2, alpha: 0.72)
        stage.layer.anchorPoint = .zero
        addSubview(stage)
        let tap = UITapGestureRecognizer(target: self, action: #selector(close))
        tap.delegate = self
        addGestureRecognizer(tap)
        switch layout {
        case .grid(let sheet): buildGrid(sheet)
        case .icons(let sheet, let background): buildIcons(sheet, background: background)
        }
    }

    private func buildIcons(_ sheet: CGImage?, background: CGImage?) {
        if let background {
            backgroundColor = UIColor(white: 0, alpha: 0.35)
            let view = UIImageView(image: UIImage(cgImage: background))
            view.frame = stage.bounds
            view.alpha = 0.92
            stage.addSubview(view)
        }
        // Back closes; Voice Collection has no Shiori screen yet.
        let cells: [(column: Int, item: Item?)] = [(0, .save), (1, .load), (2, .options), (3, .title),
                                                    (5, .quickSave), (6, .quickLoad), (7, .manual), (4, nil)]
        let cell = 270, shown: CGFloat = 230, spacing: CGFloat = 260
        let perRow = 4
        for (index, entry) in cells.enumerated() {
            let row = index / perRow, column = index % perRow
            let plain = sheet?.cropping(to: CGRect(x: entry.column * cell, y: 0, width: cell, height: cell))
            let lit = sheet?.cropping(to: CGRect(x: entry.column * cell, y: cell, width: cell, height: cell))
            let button = LucaIconButton(plain: plain, lit: lit)
            let left = (1920 - CGFloat(perRow - 1) * spacing - shown) / 2
            button.frame = CGRect(x: left + CGFloat(column) * spacing, y: row == 0 ? 280 : 580, width: shown, height: shown)
            let item = entry.item
            button.addAction(UIAction { [weak self] _ in
                if let item { self?.onPick(item) } else { self?.close() }
            }, for: .touchUpInside)
            stage.addSubview(button)
        }
    }

    private func buildGrid(_ sheet: CGImage?) {
        // The sheet's cells are 315 px apart; shown at 260 px, as in the manual's picture.
        let cell = 315, shown: CGFloat = 260
        for item in Item.allCases {
            let row = item.rawValue < 5 ? 0 : 1
            let column = item.rawValue < 5 ? item.rawValue : item.rawValue - 5
            let sourceRow = row == 0 ? 0 : 2
            let plain = sheet?.cropping(to: CGRect(x: column * cell, y: sourceRow * cell, width: cell, height: cell))
            let lit = sheet?.cropping(to: CGRect(x: column * cell, y: (sourceRow + 1) * cell, width: cell, height: cell))
            let button = LucaIconButton(plain: plain, lit: lit)
            let count = row == 0 ? 5 : 4
            let spacing: CGFloat = 300
            let left = (1920 - CGFloat(count - 1) * spacing - shown) / 2
            button.frame = CGRect(x: left + CGFloat(column) * spacing, y: row == 0 ? 250 : 560, width: shown, height: shown)
            button.addAction(UIAction { [weak self] _ in self?.onPick(item) }, for: .touchUpInside)
            stage.addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc func close() { onPick(nil) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = min(bounds.width / 1920, bounds.height / 1080)
        guard scale > 0 else { return }
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (bounds.width - 1920 * scale) / 2, y: (bounds.height - 1080 * scale) / 2)
    }

    /// Touches on the buttons are theirs, not the background's gestures.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }

    /// Icons take touches before the close-on-tap background.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for control in stage.subviews.reversed() where control is UIControl {
            if control.point(inside: convert(point, to: control), with: event) { return control }
        }
        return super.hitTest(point, with: event)
    }
}

/// A picture button that swaps to its lit picture while pressed.
final class LucaIconButton: UIControl {
    private let imageView = UIImageView()
    private let plain: UIImage?
    private let lit: UIImage?

    init(plain: CGImage?, lit: CGImage?) {
        self.plain = plain.map { UIImage(cgImage: $0) }
        self.lit = lit.map { UIImage(cgImage: $0) }
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        imageView.image = self.plain
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
    }

    private var tinted = false

    override var isHighlighted: Bool {
        didSet {
            let image = isHighlighted ? (lit ?? plain) : plain
            imageView.image = tinted ? image?.withRenderingMode(.alwaysTemplate) : image
        }
    }

    /// Draws the picture in one colour (its alpha as the shape), pressed or not.
    func tint(_ color: UIColor) {
        tinted = true
        imageView.image = imageView.image?.withRenderingMode(.alwaysTemplate)
        imageView.tintColor = color
    }
}
