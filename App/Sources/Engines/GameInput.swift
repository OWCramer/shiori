// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import GameController
import UIKit

// Input shared by the game views: the controller read once a frame, a notice pill, the
// gestures every engine has (spec, Touch), and on iPhone and iPad a focus that the arrow keys
// and the d-pad move between a screen's controls, and a pointer the stick moves.

/// A controller's buttons, read once a frame: presses, repeats of held directions (as a
/// keyboard's arrows repeat) and releases since the last read.
struct GamePadReader {
    enum Button: Hashable, CaseIterable {
        case up, down, left, right, a, b, x, y, lb, rb, menu, options
        var isDirection: Bool { [.up, .down, .left, .right].contains(self) }
    }

    private(set) var held: Set<Button> = []
    private var repeatAt: [Button: CFTimeInterval] = [:]

    /// `stick`: the left stick counts as the d-pad (off where it moves a pointer instead).
    mutating func read(_ pad: GCExtendedGamepad, stick: Bool = true) -> [(button: Button, down: Bool)] {
        let threshold: Float = 0.55
        let x = stick ? pad.leftThumbstick.xAxis.value : 0, y = stick ? pad.leftThumbstick.yAxis.value : 0
        let pressed: [Button: Bool] = [
            .up: pad.dpad.up.isPressed || y > threshold,
            .down: pad.dpad.down.isPressed || y < -threshold,
            .left: pad.dpad.left.isPressed || x < -threshold,
            .right: pad.dpad.right.isPressed || x > threshold,
            .a: pad.buttonA.isPressed, .b: pad.buttonB.isPressed,
            .x: pad.buttonX.isPressed, .y: pad.buttonY.isPressed,
            .lb: pad.leftShoulder.isPressed,
            .rb: pad.rightShoulder.isPressed || pad.rightTrigger.isPressed,
            .menu: pad.buttonMenu.isPressed,
            .options: pad.buttonOptions?.isPressed ?? false,
        ]
        let now = CACurrentMediaTime()
        var events: [(Button, Bool)] = []
        for button in Button.allCases {
            let down = pressed[button] ?? false
            if down, !held.contains(button) {
                held.insert(button)
                repeatAt[button] = now + 0.35
                events.append((button, true))
            } else if down, button.isDirection, let at = repeatAt[button], now >= at {
                repeatAt[button] = now + 0.11
                events.append((button, true))
            } else if !down, held.contains(button) {
                held.remove(button)
                repeatAt[button] = nil
                events.append((button, false))
            }
        }
        return events
    }

    /// Everything down now counts as held, so nothing fires until it's let go (after an
    /// alert closes, say).
    mutating func absorb(_ pad: GCExtendedGamepad) {
        _ = read(pad)
    }
}

/// A short message in a pill at the top of a game, for a few seconds.
@MainActor
enum GameNotice {
    private static let tag = 0x5_4E_4F_54

    static func show(_ text: String, in view: UIView) {
        view.viewWithTag(tag)?.removeFromSuperview()
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 2
        #if os(tvOS)
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        #else
        let pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        #endif
        pill.tag = tag
        pill.isUserInteractionEnabled = false
        pill.layer.cornerRadius = 18
        pill.clipsToBounds = true
        pill.contentView.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pill)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.contentView.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: pill.contentView.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: pill.contentView.topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: pill.contentView.bottomAnchor, constant: -9),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
            pill.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
        ])
        pill.alpha = 0
        UIView.animate(withDuration: 0.25) { pill.alpha = 1 }
        UIView.animate(withDuration: 0.4, delay: 3, options: []) { pill.alpha = 0 } completion: { _ in
            pill.removeFromSuperview()
        }
    }
}

#if os(iOS)
extension UIView {
    /// A swipe with `fingers` fingers (the shared gestures: two-finger swipes right for skip,
    /// up for auto, down for the backlog).
    @discardableResult
    func addSwipe(_ direction: UISwipeGestureRecognizer.Direction, fingers: Int = 1, target: Any, action: Selector) -> UISwipeGestureRecognizer {
        let swipe = UISwipeGestureRecognizer(target: target, action: action)
        swipe.direction = direction
        swipe.numberOfTouchesRequired = fingers
        swipe.fingersOnly()
        addGestureRecognizer(swipe)
        return swipe
    }
}

/// The arrow keys and the d-pad moving between a screen's controls (Shiori-drawn screens,
/// Luca's), with the control's own highlight and a ring; Enter or A presses it. The
/// trackpad's pointer lights the control under it the same way, without the ring.
@MainActor
final class ControlFocus {
    private(set) weak var focused: UIControl?
    private weak var hovered: UIControl?
    private let ring = CAShapeLayer()

    init() {
        ring.fillColor = nil
        ring.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2.5
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.6
        ring.shadowRadius = 3
        ring.shadowOffset = .zero
        ring.zPosition = 900
    }

    /// The controls a player can reach in `root`: shown, enabled and on screen.
    func controls(in root: UIView) -> [UIControl] {
        var found: [UIControl] = []
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return }
            if let control = view as? UIControl {
                let frame = control.convert(control.bounds, to: root)
                if control.isEnabled, frame.width > 4, frame.height > 4, root.bounds.intersects(frame) { found.append(control) }
                return
            }
            view.subviews.forEach(visit)
        }
        visit(root)
        return found
    }

    /// Moves the focus one step (dx, dy: -1, 0 or 1) to the nearest control that way; the
    /// first step picks the first control. False when there's nowhere to go.
    @discardableResult
    func move(dx: Int, dy: Int, in root: UIView) -> Bool {
        let all = controls(in: root)
        guard !all.isEmpty else { clear(); return false }
        func centre(_ control: UIControl) -> CGPoint {
            let frame = control.convert(control.bounds, to: root)
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        guard let current = focused, all.contains(where: { $0 === current }) else {
            // Reading order: top to bottom, left to right (the last for up and left).
            let ordered = all.sorted { a, b in
                let p = centre(a), q = centre(b)
                return abs(p.y - q.y) > 8 ? p.y < q.y : p.x < q.x
            }
            focus((dx < 0 || dy < 0) ? ordered.last : ordered.first, in: root)
            return true
        }
        let from = centre(current)
        var best: (control: UIControl, score: CGFloat)?
        for control in all where control !== current {
            let p = centre(control)
            let along = (p.x - from.x) * CGFloat(dx) + (p.y - from.y) * CGFloat(dy)
            let across = dx != 0 ? abs(p.y - from.y) : abs(p.x - from.x)
            guard along > 4 else { continue }
            let score = along + across * 2.5
            if score < best?.score ?? .infinity { best = (control, score) }
        }
        guard let best else { return false }
        focus(best.control, in: root)
        return true
    }

    func focus(_ control: UIControl?, in root: UIView) {
        if let focused, focused !== control { focused.isHighlighted = false }
        focused = control
        guard let control else { ring.removeFromSuperlayer(); return }
        control.isHighlighted = true
        let frame = control.convert(control.bounds, to: root).insetBy(dx: -3, dy: -3)
        if ring.superlayer !== root.layer { root.layer.addSublayer(ring) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.path = UIBezierPath(roundedRect: frame, cornerRadius: min(12, frame.height / 4)).cgPath
        CATransaction.commit()
    }

    /// Presses the focused control. False when nothing is focused.
    @discardableResult
    func activate() -> Bool {
        guard let control = focused, control.window != nil, control.isEnabled else { return false }
        control.isHighlighted = false
        control.sendActions(for: .touchUpInside)
        clear()
        return true
    }

    func clear() {
        focused?.isHighlighted = false
        focused = nil
        ring.removeFromSuperlayer()
    }

    /// The pointer over `point` in `root`: the control under it lights up, the last one goes
    /// out (nil when the pointer left).
    func hover(at point: CGPoint?, in root: UIView?) {
        var control: UIControl?
        if let point, let root {
            var view = root.hitTest(point, with: nil)
            while let current = view, control == nil {
                control = current as? UIControl
                view = current.superview
            }
        }
        guard control !== hovered else { return }
        if let hovered, hovered !== focused { hovered.isHighlighted = false }
        hovered = control
        if let control, control.isEnabled, !control.isTracking { control.isHighlighted = true }
    }
}

/// A pointer the controller's left stick moves over a game made for the mouse (Artemis): a
/// ring, or the game's cursor art when it has some, at the point a press lands.
@MainActor
final class StickPointer {
    let layer = CALayer()
    private(set) var location: CGPoint = .zero
    private(set) var isShown = false
    private var hotspot = CGPoint.zero
    /// Points a second at full tilt, for a host as wide as an iPhone in landscape.
    private let speed: CGFloat = 900

    init() {
        layer.zPosition = 1000
        layer.isHidden = true
        drawRing()
    }

    private func drawRing() {
        layer.contents = nil
        layer.bounds = CGRect(x: 0, y: 0, width: 30, height: 30)
        layer.cornerRadius = 15
        layer.borderWidth = 3
        layer.borderColor = UIColor.white.cgColor
        layer.backgroundColor = UIColor.white.withAlphaComponent(0.25).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.6
        layer.shadowRadius = 4
        layer.shadowOffset = .zero
        hotspot = CGPoint(x: 15, y: 15)
    }

    func attach(to view: UIView) {
        view.layer.addSublayer(layer)
        location = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    }

    /// The left stick, applied over `dt` seconds. True when it moved.
    @discardableResult
    func move(x: Float, y: Float, dt: CFTimeInterval, in bounds: CGRect) -> Bool {
        let dead: Float = 0.15
        let vx = abs(x) < dead ? 0 : CGFloat(x), vy = abs(y) < dead ? 0 : CGFloat(y)
        guard vx != 0 || vy != 0 else { return false }
        // Squared for fine control near the middle of the stick's travel.
        let scale = speed * CGFloat(dt) * max(bounds.width / 950, 0.6)
        place(at: CGPoint(x: location.x + vx * abs(vx) * scale, y: location.y - vy * abs(vy) * scale), in: bounds)
        return true
    }

    func place(at point: CGPoint, in bounds: CGRect) {
        location = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        isShown = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = false
        layer.position = CGPoint(x: location.x - hotspot.x + layer.bounds.width / 2, y: location.y - hotspot.y + layer.bounds.height / 2)
        CATransaction.commit()
        layer.superlayer.map { $0.addSublayer(layer) } // on top of anything added since
    }

    func hide() {
        isShown = false
        layer.isHidden = true
    }
}
#endif
