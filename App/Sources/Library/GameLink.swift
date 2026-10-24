// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Opens a game's page, pushed onto the current navigation stack.
struct GameLink<Label: View>: View {
    let game: LibraryGame
    @ViewBuilder var label: Label

    var body: some View {
        NavigationLink(value: LibraryRoute.game(game)) { label }
    }
}
#endif
