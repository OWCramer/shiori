// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI
import UIKit

/// What the laptop pad asks of the game above it. Points are in the game's own view, which
/// fills the top half; each engine's view controller answers through the paths its trackpad
/// and gestures already use.
@MainActor
protocol LaptopInput: UIViewController {
    /// The pointer moved there. True when the game draws its own cursor at it.
    func laptopPointer(at point: CGPoint) -> Bool
    func laptopClick(at point: CGPoint)
    func laptopSecondaryClick(at point: CGPoint)
    /// Wheel steps: positive turns it back (up, toward the backlog).
    func laptopScroll(_ steps: Int, at point: CGPoint)
    func laptopSkip()
    func laptopAuto()
    /// Opens the backlog, or closes it when it's open.
    func laptopBacklog()
    func laptopLeave()
    /// The game's own menu (the PC build's menu bar), or nil for none: Menu right-clicks then.
    func laptopMenuItems() -> [LaptopMenuItem]?
    func laptopChoose(_ item: LaptopMenuItem)
}

extension LaptopInput {
    func laptopMenuItems() -> [LaptopMenuItem]? { nil }
    func laptopChoose(_ item: LaptopMenuItem) {}
}

/// An item of the game's own menu, with its submenu.
struct LaptopMenuItem: Identifiable, Hashable {
    /// Where the item is in the game's menu (child indices from the top).
    let id: [Int]
    let title: String
    let enabled: Bool
    let checked: Bool
    var children: [LaptopMenuItem] = []
}

/// The iPhone Duo bent like a laptop (iOS 27.1): the game on the top half, a trackpad and the
/// shared controls on the bottom half. The pointer the trackpad moves lives here, in the top
/// half's points.
@MainActor @Observable
final class LaptopPad {
    static let shared = LaptopPad()

    /// The game being played; each engine's view controller sets itself when it loads.
    @ObservationIgnored weak var game: (any LaptopInput)?
    /// Where the pointer is over the game, once the trackpad has moved it.
    private(set) var pointer: CGPoint?
    /// The game draws its own cursor at the pointer, so Shiori's stays hidden.
    private(set) var gameDrawsCursor = false
    /// The top half's size, which bounds the pointer.
    var area: CGSize = .zero
    /// The game's own menu, read again every few seconds while the pad shows.
    private(set) var menu: [LaptopMenuItem] = []

    func refreshMenu() {
        let items = game?.laptopMenuItems() ?? []
        if items != menu { menu = items }
    }

    func choose(_ item: LaptopMenuItem) {
        game?.laptopChoose(item)
        refreshMenu()
    }

    /// A new game starts with no pointer.
    func reset() {
        pointer = nil
        gameDrawsCursor = false
    }

    /// The trackpad moved by `delta` points: the pointer follows, faster for a quick flick.
    func move(by delta: CGSize, speed: CGFloat) {
        let gain = 1.2 + min(speed / 900, 1.6)
        let start = pointer ?? CGPoint(x: area.width / 2, y: area.height / 2)
        let next = CGPoint(x: min(max(start.x + delta.width * gain, 0), area.width),
                           y: min(max(start.y + delta.height * gain, 0), area.height))
        pointer = next
        gameDrawsCursor = game?.laptopPointer(at: next) ?? false
    }

    private var here: CGPoint { pointer ?? CGPoint(x: area.width / 2, y: area.height / 2) }

    func click() {
        if pointer == nil { move(by: .zero, speed: 0) }
        game?.laptopClick(at: here)
    }

    func secondaryClick() { game?.laptopSecondaryClick(at: here) }
    func scroll(_ steps: Int) { game?.laptopScroll(steps, at: here) }
    func skip() { game?.laptopSkip() }
    func auto() { game?.laptopAuto() }
    func backlog() { game?.laptopBacklog() }
    func leave() { game?.laptopLeave() }
}

/// The fold across the middle of a window held upright, with the hinge bent: the laptop
/// posture. Nil otherwise (a phone, an iPad, the Duo closed, opened flat, or opened as a book).
enum LaptopFold {
    static func fold(in proxy: GeometryProxy) -> CGRect? {
        let size = proxy.size
        #if DEBUG
        // `-ShioriLaptopFold <points>`: a simulated fold that tall across the middle, for laying
        // out laptop mode in a simulator that can't bend its hinge.
        let simulated = UserDefaults.standard.double(forKey: "ShioriLaptopFold")
        if simulated > 0 {
            return CGRect(x: 0, y: (size.height - simulated) / 2, width: size.width, height: simulated)
        }
        #endif
        guard #available(iOS 27.1, *), size.height > size.width else { return nil }
        return proxy.reservedRegions(kind: .division, options: .includeInactive)
            .first { region in
                region.isActive
                    && region.frame.width > region.frame.height
                    && region.frame.minY >= minimumHalf
                    && size.height - region.frame.maxY >= minimumHalf
            }?.frame
    }

    /// Whether the window has a fold at all (the Duo's inner screen), bent or flat: games may
    /// then turn upright, for the laptop posture.
    static func hasFold(in proxy: GeometryProxy) -> Bool {
        #if DEBUG
        if UserDefaults.standard.double(forKey: "ShioriLaptopFold") > 0 { return true }
        #endif
        guard #available(iOS 27.1, *) else { return false }
        return !proxy.reservedRegions(kind: .division, options: .includeInactive).isEmpty
    }

    /// The shortest half laptop mode splits into.
    private static var minimumHalf: CGFloat { 220 }
}

/// The pointer over the game: a ring like the iPad's, unless the game draws its own cursor.
struct LaptopPointer: View {
    @State private var pad = LaptopPad.shared

    var body: some View {
        if let point = pad.pointer, !pad.gameDrawsCursor {
            Circle()
                .fill(.white.opacity(0.35))
                .strokeBorder(.black.opacity(0.45), lineWidth: 1)
                .frame(width: 18, height: 18)
                .position(point)
                .allowsHitTesting(false)
        }
    }
}

/// The bottom half: the shared controls along the top, the trackpad below.
struct LaptopPadView: View {
    @State private var pad = LaptopPad.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                control("Skip", "forward.fill", pad.skip)
                control("Auto", "play.fill", pad.auto)
                control("Backlog", "text.bubble", pad.backlog)
                menuControl
                control("Leave", "xmark", pad.leave)
            }
            LaptopTrackpad()
                .background(.white.opacity(0.07), in: .rect(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1)).allowsHitTesting(false) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background { LaptopReflection().ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                pad.refreshMenu()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The game's own menu where it has one; otherwise the right button, which opens the
    /// menu in most games.
    @ViewBuilder private var menuControl: some View {
        if pad.menu.isEmpty {
            control("Menu", "line.3.horizontal", { pad.secondaryClick() })
        } else {
            Menu {
                LaptopMenuItems(items: pad.menu, choose: pad.choose)
            } label: {
                controlLabel("Menu", "line.3.horizontal")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .tint(.white)
        }
    }

    private func control(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { controlLabel(title, symbol) }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 16))
        .tint(.white)
    }
}

extension LaptopPadView {
    fileprivate func controlLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.body.weight(.semibold))
            Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(.rect)
    }
}

/// The game's menu items as iOS menu items, submenus nested.
private struct LaptopMenuItems: View {
    let items: [LaptopMenuItem]
    let choose: (LaptopMenuItem) -> Void

    var body: some View {
        ForEach(items) { item in
            if item.children.isEmpty {
                Button { choose(item) } label: {
                    if item.checked { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
                .disabled(!item.enabled)
            } else {
                Menu(item.title) { LaptopMenuItems(items: item.children, choose: choose) }
                    .disabled(!item.enabled)
            }
        }
    }
}

/// The game mirrored into the bottom half, as if on a glossy table: a dim, blurred copy,
/// flipped at the fold and fading away from it. Drawn from snapshots of the game's view a dozen
/// times a second, which the blur hides; any engine works the same.
private struct LaptopReflection: UIViewRepresentable {
    func makeUIView(context: Context) -> ReflectionView { ReflectionView() }
    func updateUIView(_ view: ReflectionView, context: Context) {}

    final class ReflectionView: UIView {
        private let mirror = UIView()
        private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        private let fade = CAGradientLayer()
        private var link: CADisplayLink?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            isUserInteractionEnabled = false
            mirror.alpha = 0.9
            addSubview(mirror)
            addSubview(blur)
            fade.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.9).cgColor]
            fade.locations = [0.1, 0.95]
            layer.addSublayer(fade)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            blur.frame = bounds
            fade.frame = bounds
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(refresh))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func refresh() {
            guard let game = LaptopPad.shared.game?.viewIfLoaded, game.window != nil, game.bounds.width > 0,
                  let snapshot = game.snapshotView(afterScreenUpdates: false)
            else { return }
            // As wide as the pad, flipped about the fold (the game's bottom edge meets the top).
            let scale = bounds.width / game.bounds.width
            mirror.subviews.forEach { $0.removeFromSuperview() }
            mirror.frame = CGRect(x: 0, y: 0, width: bounds.width, height: game.bounds.height * scale)
            snapshot.frame = CGRect(origin: .zero, size: game.bounds.size)
            snapshot.layer.anchorPoint = .zero
            snapshot.layer.position = CGPoint(x: 0, y: game.bounds.height * scale)
            snapshot.transform = CGAffineTransform(scaleX: scale, y: -scale)
            mirror.addSubview(snapshot)
        }
    }
}

/// One finger moves the pointer and taps to click; two fingers tap for the game's menu (the
/// right button) and scroll the wheel, as on a laptop's trackpad.
private struct LaptopTrackpad: UIViewRepresentable {
    func makeUIView(context: Context) -> TrackpadView { TrackpadView() }
    func updateUIView(_ view: TrackpadView, context: Context) {}

    final class TrackpadView: UIView {
        private var scrollSent: CGFloat = 0
        private var lastTranslation: CGPoint = .zero

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            let move = UIPanGestureRecognizer(target: self, action: #selector(moved(_:)))
            move.maximumNumberOfTouches = 1
            addGestureRecognizer(move)
            let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
            scroll.minimumNumberOfTouches = 2
            scroll.maximumNumberOfTouches = 2
            addGestureRecognizer(scroll)
            let click = UITapGestureRecognizer(target: self, action: #selector(clicked))
            addGestureRecognizer(click)
            let menu = UITapGestureRecognizer(target: self, action: #selector(secondaryClicked))
            menu.numberOfTouchesRequired = 2
            addGestureRecognizer(menu)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func moved(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { lastTranslation = .zero }
            guard recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: self)
            let delta = CGSize(width: translation.x - lastTranslation.x, height: translation.y - lastTranslation.y)
            lastTranslation = translation
            let velocity = recognizer.velocity(in: self)
            LaptopPad.shared.move(by: delta, speed: hypot(velocity.x, velocity.y))
        }

        /// One wheel step per 30 points (positive is up, the backlog), as the games' own
        /// trackpad scrolling.
        @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { scrollSent = 0 }
            guard recognizer.state == .changed else { return }
            let travel = recognizer.translation(in: self).y - scrollSent
            let steps = (travel / 30).rounded(.towardZero)
            guard steps != 0 else { return }
            scrollSent += steps * 30
            LaptopPad.shared.scroll(Int(steps))
        }

        @objc private func clicked() { LaptopPad.shared.click() }
        @objc private func secondaryClicked() { LaptopPad.shared.secondaryClick() }
    }
}

extension UIView {
    /// The control under `point`, for a click that should press it (Shiori-drawn screens).
    func control(at point: CGPoint) -> UIControl? {
        var view = hitTest(point, with: nil)
        while let current = view {
            if let control = current as? UIControl { return control }
            view = current.superview
        }
        return nil
    }
}
#endif
