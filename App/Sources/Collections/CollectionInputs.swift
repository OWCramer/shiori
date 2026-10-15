// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// What Collections' suggestions depend on, compared to know when to work them out again.
struct CollectionInputs: Equatable {
    var library: [LibraryGame]
    var added: Set<UInt32>
    var hidden: Set<UInt32>
    var downloaded: Set<UInt32>
}
