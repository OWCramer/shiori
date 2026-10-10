#if os(iOS)
import UIKit

/// iPad trackpad and mouse support shared by the game views (UIApplicationSupportsIndirectInputEvents
/// is on, so a pointer's clicks arrive as `.indirectPointer` touches with a button mask).
extension UIGestureRecognizer {
    /// Fingers only: swipes, holds and multi-finger gestures shouldn't fire on a trackpad
    /// click-drag or a held click.
    func fingersOnly() {
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }
}

extension UIView {
    /// A trackpad or mouse secondary click (right click, two-finger click, Control-click).
    @discardableResult
    func addSecondaryClick(target: Any, action: Selector) -> UITapGestureRecognizer {
        let click = UITapGestureRecognizer(target: target, action: action)
        click.buttonMaskRequired = .secondary
        click.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        addGestureRecognizer(click)
        return click
    }

    /// The pointer moving over the view with no button down (rollover).
    @discardableResult
    func addHover(target: Any, action: Selector) -> UIHoverGestureRecognizer {
        let hover = UIHoverGestureRecognizer(target: target, action: action)
        addGestureRecognizer(hover)
        return hover
    }

    /// Two-finger trackpad scrolls and mouse wheels; `translation(in:)` gives the distance.
    @discardableResult
    func addScroll(target: Any, action: Selector) -> UIPanGestureRecognizer {
        let scroll = UIPanGestureRecognizer(target: target, action: action)
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = [] // Scrolls only, never a drag.
        addGestureRecognizer(scroll)
        return scroll
    }
}

extension UIControl {
    /// Lights the control up while a trackpad or mouse pointer is over it, with the same
    /// art a press shows (`isHighlighted`), as the game's buttons do under a PC mouse.
    func highlightsOnHover() {
        let highlighter = HoverHighlighter(control: self)
        addGestureRecognizer(UIHoverGestureRecognizer(target: highlighter, action: #selector(HoverHighlighter.hovered(_:))))
        objc_setAssociatedObject(self, &HoverHighlighter.key, highlighter, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class HoverHighlighter: NSObject {
    nonisolated(unsafe) static var key: UInt8 = 0
    weak var control: UIControl?

    init(control: UIControl) { self.control = control }

    @MainActor @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
        guard let control, control.isEnabled, !control.isTracking else { return }
        switch recognizer.state {
        case .began, .changed: control.isHighlighted = true
        default: control.isHighlighted = false
        }
    }
}

/// Debug builds: pointer events to Caches/pointer-log.txt, readable from a device's app
/// container, for checking trackpad support on hardware the simulator can't stand in for.
enum PointerLog {
    static func write(_ line: String) {
        #if DEBUG
        let url = URL.cachesDirectory.appendingPathComponent("pointer-log.txt")
        let data = Data("\(ISO8601DateFormatter().string(from: .now)) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 200_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        #endif
    }
}

extension UITouch {
    /// A click from a trackpad or mouse rather than a finger.
    var isPointer: Bool { type == .indirectPointer }
}
#endif
