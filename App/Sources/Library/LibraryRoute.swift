#if os(iOS)
import SwiftUI

/// A page pushed in one of the library's navigation stacks: a game, or a collection.
enum LibraryRoute: Hashable {
    case game(LibraryGame)
    /// A collection or sub-group, by id (`LibraryCollections`), opened on part of it or whole.
    case collection(String, scope: CollectionScope? = nil)

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
            case let .collection(id, scope): CollectionPage(collectionID: id, scope: scope)
            }
        }
    }
}
#endif
