// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import Foundation

/// A game dragged from the library (iPad), as text: "shiori-game:<appid>". Dropped on a
/// collection in the sidebar, it joins it; text from elsewhere is ignored.
enum GameDrag {
    private static let prefix = "shiori-game:"

    static func payload(_ appID: UInt32) -> String { prefix + String(appID) }

    static func appID(_ payload: String) -> UInt32? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UInt32(payload.dropFirst(prefix.count))
    }
}
#endif
