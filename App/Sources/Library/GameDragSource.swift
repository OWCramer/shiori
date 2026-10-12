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
