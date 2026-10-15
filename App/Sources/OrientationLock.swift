// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
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
        // UIKit calls the error handler on a background queue (when the request times out while
        // the main thread is busy), so it must not be main-actor isolated, or the isolation check traps.
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: OrientationLock.ignoreError)
    }

    nonisolated private static func ignoreError(_ error: any Error) {}
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}
#endif
