// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Observation

/// The iPhone Duo opened like a book: the game shown on the left-hand page. Games picked
/// in the library on the right page land here instead of being pushed over the library.
/// `isOpen` is true only while the device is open that way.
@MainActor @Observable
final class BookSelection {
    var game: LibraryGame?
    var isOpen = false
    /// The game the left page showed when the Duo folded, for the current tab to push so
    /// the page stays open on the cover screen.
    var foldedGame: LibraryGame?

    func show(_ game: LibraryGame) { self.game = game }
}
