// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Opens a game's page, pushed onto the current navigation stack and zooming out of this
/// cover (`LibraryStack`).
struct GameLink<Label: View>: View {
    let game: LibraryGame
    @ViewBuilder var label: Label
    @Environment(\.gameZoom) private var zoom
    /// This cover among the game's others on the screen, for the page to zoom out of.
    @State private var source = UUID().uuidString

    var body: some View {
        NavigationLink(value: LibraryRoute.game(game)) {
            if let zoom {
                label.matchedTransitionSource(id: source, in: zoom.namespace)
            } else {
                label
            }
        }
        .simultaneousGesture(TapGesture().onEnded { zoom?.model.source = source })
    }
}
#endif
