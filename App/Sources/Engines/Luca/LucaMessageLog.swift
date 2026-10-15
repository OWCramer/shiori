// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import LucaKit
import UIKit

/// The game's Message Log (manual page 11), from its art: the olive `backlog_texture`, the
/// lines with their speakers, a speaker icon (`speaker_1920`, six frames that play while the
/// voice does) on lines whose voice can be heard again, and the `MessageLogBar` grip as the
/// scroll thumb. A tap closes it, as do a two-finger tap and pulling up past the last line;
/// pressing and holding a line returns the game to it.
final class LucaMessageLog: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let scroll = UIScrollView(frame: CGRect(x: 0, y: 40, width: 1920, height: 1000))
    private let thumb = UIImageView()
    private let onClose: () -> Void
    private let onVoice: (LucaMessage) -> Void
    /// Pressing and holding line `i` (an index into the lines) returns the game to it.
    var onReturn: ((Int) -> Void)?
    private var rows: [(top: CGFloat, bottom: CGFloat)] = []
    private var speakerFrames: [UIImage] = []
    private var closing = false

    private static let trackTop: CGFloat = 70, trackBottom: CGFloat = 1010
    private static let nameColour = UIColor(red: 1, green: 0.92, blue: 0.62, alpha: 1)

    /// Lays text out in the game's font: its size in stage pixels, and a way to draw it (nil
    /// falls back to the system font). Lines are drawn only as they scroll into view.
    typealias Typesetter = (_ text: String, _ width: Int, _ fill: UIColor) -> (size: CGSize, draw: () -> UIImage?)?
    private let typeset: Typesetter?
    private var undrawn: [(view: UIImageView, draw: () -> UIImage?)] = []

    init(game: LucaGame, lines: [LucaMessage], typeset: Typesetter? = nil, onVoice: @escaping (LucaMessage) -> Void,
         onClose: @escaping () -> Void) {
        self.typeset = typeset
        self.onClose = onClose
        self.onVoice = onVoice
        super.init(frame: .zero)
        backgroundColor = .black
        let art = LucaArt(game: game)
        stage.layer.anchorPoint = .zero
        stage.clipsToBounds = true
        addSubview(stage)
        let background = UIImageView(image: art.picture("backlog_texture").map { UIImage(cgImage: $0) })
        background.frame = stage.bounds
        stage.addSubview(background)

        if let sheet = art.picture("speaker_1920") {
            speakerFrames = (0..<(sheet.width / 60)).compactMap {
                sheet.cropping(to: CGRect(x: $0 * 60, y: 0, width: 60, height: 60)).map { UIImage(cgImage: $0) }
            }
        }
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        stage.addSubview(scroll)
        layOut(lines, game: game)

        thumb.image = art.picture("MessageLogBar_1920").map { UIImage(cgImage: $0) }
        thumb.frame = CGRect(x: 1830, y: Self.trackTop, width: 48, height: 42)
        let track = UIView(frame: CGRect(x: 1852, y: Self.trackTop, width: 4, height: Self.trackBottom - Self.trackTop))
        track.backgroundColor = UIColor(white: 1, alpha: 0.25)
        stage.addSubview(track)
        stage.addSubview(thumb)

        let tap = UITapGestureRecognizer(target: self, action: #selector(close))
        tap.delegate = self
        addGestureRecognizer(tap)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.6
        scroll.addGestureRecognizer(hold)
        let twoFinger = UITapGestureRecognizer(target: self, action: #selector(close))
        twoFinger.requireSecondaryClick()
        addGestureRecognizer(twoFinger)
        tap.require(toFail: twoFinger)
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

    /// The newest line at the bottom, shown first.
    func scrollToEnd() {
        layoutIfNeeded()
        scroll.contentOffset.y = max(0, scroll.contentSize.height - scroll.bounds.height)
        moveThumb()
        drawVisible()
    }

    private func layOut(_ lines: [LucaMessage], game: LucaGame) {
        let textFont = UIFont.systemFont(ofSize: 40, weight: .medium)
        let nameFont = UIFont.systemFont(ofSize: 34, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 8
        let textWidth: CGFloat = 1420
        var y: CGFloat = 40
        for line in lines {
            let top = y
            if game.hasVoice(line.voice) {
                let button = LucaSpeakerButton(frames: speakerFrames)
                button.frame = CGRect(x: 170, y: y + (line.speaker == nil ? -4 : 30), width: 76, height: 76)
                button.addAction(UIAction { [weak self, weak button] _ in
                    self?.onVoice(line)
                    button?.play()
                }, for: .touchUpInside)
                scroll.addSubview(button)
            }
            if let typeset {
                if let speaker = line.speaker, let name = typeset(speaker, Int(textWidth), Self.nameColour) {
                    let view = UIImageView(frame: CGRect(x: 290, y: y - 6, width: name.size.width, height: name.size.height))
                    scroll.addSubview(view)
                    undrawn.append((view, name.draw))
                    y += 50
                }
                if let text = typeset(line.text, Int(textWidth), .white) {
                    let view = UIImageView(frame: CGRect(x: 290, y: y - 6, width: text.size.width, height: text.size.height))
                    scroll.addSubview(view)
                    undrawn.append((view, text.draw))
                    y += text.size.height + 30
                }
                rows.append((top - 10, y - 30))
                continue
            }
            if let speaker = line.speaker {
                let name = UILabel(frame: CGRect(x: 290, y: y, width: textWidth, height: 44))
                name.text = speaker
                name.font = nameFont
                name.textColor = Self.nameColour
                Self.shade(name)
                scroll.addSubview(name)
                y += 46
            }
            let text = NSAttributedString(string: line.text, attributes: [.font: textFont, .foregroundColor: UIColor.white,
                                                                          .paragraphStyle: paragraph])
            let height = ceil(text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                                                options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
            let label = UILabel(frame: CGRect(x: 290, y: y, width: textWidth, height: height))
            label.numberOfLines = 0
            label.attributedText = text
            Self.shade(label)
            scroll.addSubview(label)
            y += height + 44
            rows.append((top - 10, y - 30))
        }
        scroll.contentSize = CGSize(width: 1920, height: y + 20)
    }

    private static func shade(_ label: UILabel) {
        label.layer.shadowColor = UIColor(red: 0.15, green: 0.12, blue: 0, alpha: 1).cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = .zero
    }

    /// Scrolls by `lines` (keys, the pad): negative is back towards older lines.
    func scroll(lines: Int) {
        let end = max(0, scroll.contentSize.height - scroll.bounds.height)
        let y = min(end, max(0, scroll.contentOffset.y + CGFloat(lines) * 160))
        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: true)
    }

    private func moveThumb() {
        let range = scroll.contentSize.height - scroll.bounds.height
        let t = range > 0 ? min(1, max(0, scroll.contentOffset.y / range)) : 1
        thumb.frame.origin.y = Self.trackTop + t * (Self.trackBottom - Self.trackTop - thumb.frame.height)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        moveThumb()
        drawVisible()
    }

    /// Draws the lines on screen and a screen's height around them.
    private func drawVisible() {
        guard !undrawn.isEmpty else { return }
        let near = scroll.bounds.insetBy(dx: 0, dy: -scroll.bounds.height)
        undrawn.removeAll { item in
            guard item.view.frame.intersects(near) else { return false }
            item.view.image = item.draw()
            return true
        }
    }

    /// Pulling up past the newest line closes the log, as the wheel does on PC.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let end = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        if scrollView.contentOffset.y > end + 120 { close() }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        let y = recognizer.location(in: scroll).y
        guard let index = rows.firstIndex(where: { $0.top...$0.bottom ~= y }) else { return }
        onReturn?(index)
    }

    @objc func close() {
        guard !closing else { return }
        closing = true
        onClose()
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
}

/// The speaker icon; its waves play while the voice does.
private final class LucaSpeakerButton: UIControl {
    private let icon = UIImageView()
    private let frames: [UIImage]

    init(frames: [UIImage]) {
        self.frames = frames
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        icon.image = frames.first
        icon.isUserInteractionEnabled = false
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override var isHighlighted: Bool { didSet { icon.alpha = isHighlighted ? 0.6 : 1 } }

    func play() {
        guard frames.count > 1 else { return }
        icon.animationImages = frames
        icon.animationDuration = 0.6
        icon.animationRepeatCount = 3
        icon.startAnimating()
    }
}
