#if os(iOS)
import SwiftUI

/// Opens a game's page: pushed onto the current navigation stack, or, on an opened iPhone
/// Duo, shown on the left-hand page (`BookSelection`).
struct GameLink<Label: View>: View {
    let game: LibraryGame
    @ViewBuilder var label: Label
    @Environment(BookSelection.self) private var book: BookSelection?

    var body: some View {
        if let book {
            Button { book.show(game) } label: { label }
        } else {
            NavigationLink(value: game) { label }
        }
    }
}
#endif
