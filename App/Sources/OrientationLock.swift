import UIKit

/// The orientations the app allows: any in the library, landscape while a game is open. iOS
/// asks the app delegate every time the device turns, so a game stays landscape even when the
/// phone is held upright (a one-off geometry request alone doesn't hold).
@MainActor
enum OrientationLock {
    static private(set) var mask: UIInterfaceOrientationMask = .all

    static func set(_ mask: UIInterfaceOrientationMask, in scene: UIWindowScene?) {
        self.mask = mask
        for window in scene?.windows ?? [] {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
