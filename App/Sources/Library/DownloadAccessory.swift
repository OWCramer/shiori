#if os(iOS)
import SwiftUI

/// The mini player in the tab bar's accessory slot (iOS 26.1's `isEnabled`, so it goes
/// away with nothing downloading; nothing on 26.0).
struct DownloadAccessory: ViewModifier {
    let game: LibraryGame?
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: game != nil) {
                if let game { MiniDownload(game: game, open: open) }
            }
        } else {
            content
        }
    }
}
#endif
