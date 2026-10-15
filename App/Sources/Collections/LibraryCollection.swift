// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// A collection as the library shows it: the suggestion with the user's edits laid over it, or
/// one he made. Games are in release order; sub-groups go one level deep.
struct LibraryCollection: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var isSuggested: Bool
    /// The collection a sub-group is in.
    var parentID: String?
    /// Games directly in it, not in a sub-group.
    var games: [UInt32]
    var subgroups: [LibraryCollection] = []
    /// Every game, sub-groups included, in release order: the first leads its art.
    var inReleaseOrder: [UInt32] = []

    /// Every game, sub-groups included, in release order within each.
    var allGames: [UInt32] { games + subgroups.flatMap(\.allGames) }
}
