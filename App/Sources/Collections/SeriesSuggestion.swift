// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// A series Shiori suggests as a collection: its games in release order and, one level
/// down, the numbered runs inside it (Sakura › Sakura Succubus). `id` comes from the name
/// it's suggested under, so it stays the same each time the suggestions are worked out and
/// the user's edits keep applying.
struct SeriesSuggestion: Hashable, Sendable {
    var id: String
    var name: String
    /// Games directly in it, not in a sub-group.
    var games: [UInt32]
    var subgroups: [SeriesSuggestion] = []

    /// Every game, sub-groups included.
    var allGames: [UInt32] { games + subgroups.flatMap(\.allGames) }
}
