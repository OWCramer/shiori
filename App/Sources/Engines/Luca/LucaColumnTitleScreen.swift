// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import LucaKit
import UIKit

/// A Luca title screen built from a still picture, the logo and a column of words (Harmonia
/// Full HD's `title_bg2`, `title_logo`, `title_menu`), after its boot pictures on white. The
/// word sheet has the plain words in its left half and the lit ones in its right, one row each:
/// Start, Load, Chapter, Options, Extras, Manual, Exit. Without the art (a Luca game Shiori has
/// no profile for) the words are plain text over black. A tap skips the boot pictures.
final class LucaColumnTitleScreen: UIView {
    private let game: LucaGame
    private let onAction: (LucaTitleScreen.Action) -> Void
    private let onSound: (String) -> Void
    private let stage = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let titleLayer = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private let white = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    private var bootViews: [UIImageView] = []
    private var timers: [Timer] = []
    private var menuShown = false

    /// The sheet's rows and what they do. Extras (row 4) swaps the column for its own rows:
    /// Gallery, Music and Back (rows 7–9).
    private static let rows: [(row: Int, title: String, action: LucaTitleScreen.Action?)] = [
        (0, "Start", .start), (1, "Load", .load), (2, "Chapter", .chapter), (3, "Options", .options),
        (4, "Extras", nil), (5, "Manual", .manual), (6, "Exit", .exit),
    ]
    private static let extrasRows: [(row: Int, title: String, action: LucaTitleScreen.Action?)] = [
        (7, "Gallery", .gallery), (8, "Music", .music), (9, "Back", nil),
    ]
    private var mainButtons: [UIView] = []
    private var extrasButtons: [UIView] = []

    init(game: LucaGame, profile: LucaProfile, boot: Bool, onSound: @escaping (String) -> Void,
         onAction: @escaping (LucaTitleScreen.Action) -> Void) {
        self.game = game
        self.onAction = onAction
        self.onSound = onSound
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        stage.layer.anchorPoint = .zero
        stage.clipsToBounds = true
        addSubview(stage)
        stage.addSubview(titleLayer)
        buildTitle(profile)

        white.backgroundColor = .white
        stage.addSubview(white)
        for name in profile.bootPictures {
            let view = UIImageView(image: picture(name).map { UIImage(cgImage: $0) })
            view.frame = stage.bounds
            view.alpha = 0
            white.addSubview(view)
            bootViews.append(view)
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(skip))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
        if boot, !bootViews.isEmpty { runBoot() } else { showTitle(animated: false) }
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
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.layer.position = CGPoint(x: (bounds.width - 1920 * scale) / 2, y: (bounds.height - 1080 * scale) / 2)
    }

    private func picture(_ name: String) -> CGImage? {
        game.imageID(named: name).flatMap { game.image($0) }.flatMap(LucaGameViewController.cgImage)
    }

    // MARK: Boot

    private func after(_ seconds: Double, _ body: @escaping () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in body() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// Each picture fades in, holds and fades out on white; then the white gives way to the title.
    private func runBoot() {
        titleLayer.alpha = 0
        var time = 0.3
        for (index, view) in bootViews.enumerated() {
            let hold = index == 0 ? 3.0 : 1.8
            after(time) { UIView.animate(withDuration: 0.6) { view.alpha = 1 } }
            after(time + 0.6 + hold) { UIView.animate(withDuration: 0.6) { view.alpha = 0 } }
            time += 0.6 + hold + 0.8
        }
        after(time) { [weak self] in self?.showTitle(animated: true) }
    }

    @objc private func skip() {
        guard !menuShown else { return }
        timers.forEach { $0.invalidate() }
        bootViews.forEach { $0.layer.removeAllAnimations() }
        showTitle(animated: true)
    }

    private func showTitle(animated: Bool) {
        guard !menuShown else { return }
        menuShown = true
        onSound("music")
        if animated {
            titleLayer.alpha = 1
            UIView.animate(withDuration: 1.2, animations: { self.white.alpha = 0 }) { _ in self.white.isHidden = true }
        } else {
            white.isHidden = true
            titleLayer.alpha = 1
        }
    }

    // MARK: Title

    private func buildTitle(_ profile: LucaProfile) {
        guard case .column(let backgroundName, let logoName, let menuName, let rowHeight, let copyrightName) = profile.title,
              let sheet = picture(menuName) else {
            buildPlainTitle()
            return
        }
        let background = UIImageView(image: picture(backgroundName).map { UIImage(cgImage: $0) })
        background.frame = stage.bounds
        titleLayer.addSubview(background)
        if let id = game.imageID(named: logoName), let image = game.image(id), let cg = LucaGameViewController.cgImage(image) {
            // Placed by its own offset in the picture, as the game's art is.
            let logo = UIImageView(image: UIImage(cgImage: cg))
            logo.frame = CGRect(x: image.offsetX, y: image.offsetY, width: image.width, height: image.height)
            titleLayer.addSubview(logo)
        }
        if let name = copyrightName, let copyright = picture(name) {
            let view = UIImageView(image: UIImage(cgImage: copyright))
            view.frame = CGRect(x: 1920 - copyright.width - 24, y: 1080 - copyright.height - 16, width: copyright.width, height: copyright.height)
            titleLayer.addSubview(view)
        }
        let column = sheet.width / 2
        func place(_ rows: [(row: Int, title: String, action: LucaTitleScreen.Action?)], hidden: Bool) -> [UIView] {
            let top: CGFloat = 1080 - CGFloat(Self.rows.count) * CGFloat(rowHeight) - 120
            return rows.enumerated().map { index, entry in
                let plain = sheet.cropping(to: CGRect(x: 0, y: entry.row * rowHeight, width: column, height: rowHeight))
                let lit = sheet.cropping(to: CGRect(x: column, y: entry.row * rowHeight, width: column, height: rowHeight))
                let button = LucaIconButton(plain: plain, lit: lit)
                button.frame = CGRect(x: 1920 - CGFloat(column) - 120, y: top + CGFloat(index * rowHeight),
                                      width: CGFloat(column), height: CGFloat(rowHeight))
                button.isHidden = hidden
                add(button, action: entry.action)
                return button
            }
        }
        mainButtons = place(Self.rows, hidden: false)
        extrasButtons = place(Self.extrasRows, hidden: true)
    }

    /// Plain words over black, for a game without title art.
    private func buildPlainTitle() {
        let name = UILabel(frame: CGRect(x: 0, y: 220, width: 1920, height: 120))
        name.text = "Luca System"
        name.font = .systemFont(ofSize: 80, weight: .light)
        name.textColor = .white
        name.textAlignment = .center
        titleLayer.addSubview(name)
        func place(_ rows: [(row: Int, title: String, action: LucaTitleScreen.Action?)], hidden: Bool) -> [UIView] {
            rows.enumerated().map { index, entry in
                let button = UIButton(type: .system)
                button.setTitle(entry.title, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 56, weight: .medium)
                button.tintColor = .white
                button.frame = CGRect(x: 760, y: 340 + CGFloat(index) * 100, width: 400, height: 90)
                button.isHidden = hidden
                add(button, action: entry.action)
                return button
            }
        }
        mainButtons = place(Self.rows, hidden: false)
        extrasButtons = place(Self.extrasRows, hidden: true)
    }

    /// A row with no action switches between the main column and Extras' (Extras, Back).
    private func add(_ control: UIControl, action: LucaTitleScreen.Action?) {
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onSound("title_hit")
            if let action { self.onAction(action) } else { self.showExtras(self.extrasButtons.first?.isHidden ?? false) }
        }, for: .touchUpInside)
        titleLayer.addSubview(control)
    }

    private func showExtras(_ extras: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.mainButtons.forEach { $0.alpha = extras ? 0 : 1 }
            self.extrasButtons.forEach { $0.alpha = extras ? 1 : 0 }
        }
        mainButtons.forEach { $0.isHidden = extras }
        extrasButtons.forEach { $0.isHidden = !extras; $0.alpha = extras ? 1 : 0 }
    }

    /// The menu takes touches first once it's up.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if menuShown {
            for control in titleLayer.subviews.reversed() where control is UIControl && !control.isHidden {
                if control.point(inside: convert(point, to: control), with: event) { return control }
            }
        }
        return super.hitTest(point, with: event)
    }
}
