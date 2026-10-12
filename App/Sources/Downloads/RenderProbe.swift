#if DEBUG
import OSLog
import QuartzCore

/// `-ShioriRenderProbe` (debug): counts body evaluations of the views that show download
/// and patch progress, and frames that took too long, and logs both every five seconds
/// ("render" category), to measure how much a progress tick re-evaluates.
@MainActor
enum RenderProbe {
    static let isOn = UserDefaults.standard.bool(forKey: "ShioriRenderProbe")
    private static var counts: [String: Int] = [:]
    private static var monitor: FrameMonitor?
    private static let log = Logger(subsystem: "com.owencramer.vnhub", category: "render")

    /// Call as `let _ = RenderProbe.hit("Name")` at the top of a body.
    @discardableResult
    static func hit(_ name: String) -> Bool {
        guard isOn else { return false }
        if monitor == nil { start() }
        counts[name, default: 0] += 1
        return true
    }

    private static func start() {
        let monitor = FrameMonitor()
        self.monitor = monitor
        Task {
            while true {
                try? await Task.sleep(for: .seconds(5))
                let frames = monitor.take()
                let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                log.notice("5s: frames \(frames.total) hitches \(frames.hitches) dropped \(frames.dropped) | \(line, privacy: .public)")
                counts.removeAll()
            }
        }
    }
}

/// Frames over the last period, and how many came late (a hitch) and by how many frames.
@MainActor
private final class FrameMonitor: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var total = 0
    private var hitches = 0
    private var dropped = 0

    override init() {
        super.init()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let expected = link.targetTimestamp - link.timestamp
        let delta = link.timestamp - last
        total += 1
        if expected > 0, delta > expected * 1.5 {
            hitches += 1
            dropped += Int((delta / expected).rounded()) - 1
        }
    }

    func take() -> (total: Int, hitches: Int, dropped: Int) {
        defer { total = 0; hitches = 0; dropped = 0 }
        return (total, hitches, dropped)
    }
}
#else
/// Release builds: nothing to count.
enum RenderProbe {
    @inline(__always) @discardableResult
    static func hit(_ name: String) -> Bool { false }
}
#endif
