// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// The collection sheets the library presents from anywhere (a capsule's menu, a tile's).
enum CollectionSheet: Identifiable, Hashable {
    /// Pick a collection for these games.
    case addTo([UInt32])
    /// Name a new collection of these games.
    case new([UInt32])
    /// A collection's editor.
    case edit(String)

    var id: Self { self }
}
