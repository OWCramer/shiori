#if os(iOS)
import CoreMotion
import Observation
import UIKit

/// Home's hero parallax, as on the TV app: tilting the device pans the banner a little
/// and floats the logo the other way. Reads gravity along the screen's own left–right axis
/// (so landscape tilts the right way), relative to how the device was held when Home appeared
/// and slowly following the hand, at 60 Hz with smoothing, while Home is on screen and the
/// app is active; off with Reduce Motion.
@MainActor @Observable
final class HeroParallax {
    /// -1 (tilted fully left) … 1 (fully right).
    private(set) var tilt: Double = 0

    /// How far the banner pans each way, in points; the logo moves `logoShare` of it.
    static let range: CGFloat = 24
    static let logoShare: CGFloat = 0.35

    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var reference: Double?
    /// The sideways gravity (≈ sine of the tilt) that reads as a full tilt: about 20°.
    private static let fullTilt = 0.34
    /// The screen's orientation, read when updates start and when it changes.
    @ObservationIgnored private var orientation: UIInterfaceOrientation = .portrait

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
        orientation = Self.currentOrientation
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            MainActor.assumeIsolated { self?.update(gravity: data.gravity) }
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        reference = nil
    }

    private static var currentOrientation: UIInterfaceOrientation {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.effectiveGeometry.interfaceOrientation ?? .portrait
    }

    /// Gravity along the screen's left–right axis, whichever way the device is turned.
    private func sideways(_ gravity: CMAcceleration) -> Double {
        switch orientation {
        case .landscapeLeft: gravity.y
        case .landscapeRight: -gravity.y
        case .portraitUpsideDown: -gravity.x
        default: gravity.x
        }
    }

    private func update(gravity: CMAcceleration) {
        let now = Self.currentOrientation
        if now != orientation {
            // Turned: start again from how it's held now.
            orientation = now
            reference = nil
        }
        let value = sideways(gravity)
        // The neutral position drifts toward the current one, so holding the device at a new
        // angle settles back to the middle.
        let base = reference.map { $0 + (value - $0) * 0.005 } ?? value
        reference = base
        let target = max(-1, min(1, (value - base) / Self.fullTilt))
        // Smoothed at 60 Hz (gravity is already filtered by Core Motion, so this mostly
        // hides hand tremor).
        let next = tilt + (target - tilt) * 0.12
        if abs(next - tilt) > 0.0005 { tilt = next }
    }
}
#endif
