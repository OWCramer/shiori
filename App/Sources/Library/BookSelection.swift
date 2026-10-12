import Observation

/// The iPhone Duo opened like a book: the game shown on the left-hand page. Games picked
/// in the library on the right page land here instead of being pushed over the library.
/// Present in the environment only while the device is open that way.
@MainActor @Observable
final class BookSelection {
    var game: LibraryGame?

    func show(_ game: LibraryGame) { self.game = game }
}
