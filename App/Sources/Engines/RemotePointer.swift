#if os(tvOS)
import UIKit

/// A pointer for the Siri Remote: games built for a mouse or touch screen (buttons clicked
/// where they are) get a cursor that the remote's touch surface moves, and a click lands
/// where it is. Shared by the game views on Apple TV.
@MainActor
final class RemotePointer: NSObject {
    private let cursor = UIView()
    private weak var host: UIView?
    private var start: CGPoint = .zero
    /// Where the pointer is, in the host view's coordinates.
    private(set) var location: CGPoint = .zero
    /// Called as the pointer moves (rollover).
    var onMove: ((CGPoint) -> Void)?
    /// Host points moved per point of travel on the touch surface.
    var speed: CGFloat = 1.8

    init(in host: UIView) {
        self.host = host
        super.init()
        cursor.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        cursor.layer.cornerRadius = 17
        cursor.layer.borderWidth = 3
        cursor.layer.borderColor = UIColor.white.cgColor
        cursor.backgroundColor = UIColor.white.withAlphaComponent(0.25)
        cursor.layer.shadowColor = UIColor.black.cgColor
        cursor.layer.shadowOpacity = 0.6
        cursor.layer.shadowRadius = 4
        cursor.layer.shadowOffset = .zero
        cursor.isUserInteractionEnabled = false
        host.addSubview(cursor)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        host.addGestureRecognizer(pan)
        centre()
    }

    /// Back to the middle of the screen (on start, and when the view changes size).
    func centre() {
        guard let host else { return }
        location = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
        place()
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let host else { return }
        switch recognizer.state {
        case .began:
            start = location
        case .changed:
            let travel = recognizer.translation(in: host)
            location = CGPoint(x: min(max(start.x + travel.x * speed, 0), host.bounds.width),
                               y: min(max(start.y + travel.y * speed, 0), host.bounds.height))
            place()
            onMove?(location)
        default:
            break
        }
    }

    private func place() {
        cursor.center = location
        host?.bringSubviewToFront(cursor)
    }
}
#endif
