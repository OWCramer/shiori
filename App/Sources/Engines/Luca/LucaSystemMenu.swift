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

    init(sheet: CGImage?, onPick: @escaping (Item?) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.0, green: 0.07, blue: 0.2, alpha: 0.72)
        stage.layer.anchorPoint = .zero
        addSubview(stage)
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
        let tap = UITapGestureRecognizer(target: self, action: #selector(close))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func close() { onPick(nil) }

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
