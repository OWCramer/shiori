// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI
import UIKit

/// On iPad, a capsule can be dragged (onto a collection in the sidebar). Phones keep the
/// long press for the menu alone.
struct GameDragSource: ViewModifier {
    let appID: UInt32
    private static let isPad = UIDevice.current.userInterfaceIdiom == .pad

    func body(content: Content) -> some View {
        if Self.isPad {
            content.draggable(GameDrag.payload(appID))
        } else {
            content
        }
    }
}
#endif
