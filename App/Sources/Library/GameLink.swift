// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Opens a game's page: pushed onto the current navigation stack, or, on an opened iPhone
/// Duo, shown on the left-hand page (`BookSelection`).
struct GameLink<Label: View>: View {
    let game: LibraryGame
    @ViewBuilder var label: Label
    @Environment(BookSelection.self) private var book: BookSelection?

    var body: some View {
        if let book, book.isOpen {
            Button { book.show(game) } label: { label }
        } else {
            NavigationLink(value: LibraryRoute.game(game)) { label }
        }
    }
}
#endif
