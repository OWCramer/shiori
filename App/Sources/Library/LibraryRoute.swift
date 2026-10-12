#if os(iOS)
import SwiftUI

/// A page pushed in one of the library's navigation stacks: a game, or a collection.
enum LibraryRoute: Hashable {
    case game(LibraryGame)
    /// A collection or sub-group, by id (`LibraryCollections`).
    case collection(String)

    var game: LibraryGame? {
        if case let .game(game) = self { game } else { nil }
    }
}

extension View {
    /// The pages the library's stacks push: games and collections.
    func libraryDestinations() -> some View {
        navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case let .game(game): GameDetailView(game: game)
            case let .collection(id): CollectionPage(collectionID: id)
            }
        }
    }
}
#endif
