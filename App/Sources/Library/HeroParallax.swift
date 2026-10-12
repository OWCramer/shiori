#if os(iOS)
import CoreMotion
import Observation
import UIKit

/// Home's hero parallax, as on the TV app: tilting the device pans the banner a little
/// and floats the logo the other way. Reads the device's attitude (roll, relative to how it
/// was held when Home appeared, slowly following the hand), smoothed, while Home is on
/// screen and the app is active; off with Reduce Motion.
@MainActor @Observable
final class HeroParallax {
    /// -1 (tilted fully left) … 1 (fully right).
    private(set) var tilt: Double = 0

    /// How far the banner pans each way, in points; the logo moves `logoShare` of it.
    static let range: CGFloat = 24
    static let logoShare: CGFloat = 0.35

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var reference: Double?
    /// The roll that reads as a full tilt.
    private static let fullTilt = 0.35

    /// `-ShioriTilt <-1…1>` (Debug) holds the tilt there, for the simulator, which has no motion.
    private static var forcedTilt: Double? {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "ShioriTilt") != nil {
            return max(-1, min(1, UserDefaults.standard.double(forKey: "ShioriTilt")))
        }
        #endif
        return nil
    }

    func start() {
        if let forced = Self.forcedTilt {
            tilt = forced
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled, motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else {
            if UIAccessibility.isReduceMotionEnabled { tilt = 0 }
            return
        }
        reference = nil
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated { self?.update(roll: data.attitude.roll) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        reference = nil
    }

    private func update(roll: Double) {
        // The neutral position drifts toward the current one, so holding the phone at a new
        // angle settles back to the middle.
        let base = reference.map { $0 + (roll - $0) * 0.01 } ?? roll
        reference = base
        let target = max(-1, min(1, (roll - base) / Self.fullTilt))
        let next = tilt + (target - tilt) * 0.15
        if abs(next - tilt) > 0.002 { tilt = next }
    }
}
#endif
