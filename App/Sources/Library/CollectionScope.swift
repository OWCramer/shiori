// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The part of a collection a page opens on, from where it was opened: from Installed only
/// the downloaded games, from a filtered grid only the games it shows (as an album opened
/// from Apple Music's Downloaded shows only the downloaded songs), with Show All for the rest.
enum CollectionScope: Hashable {
    case downloaded
    /// The games a filtered grid shows.
    case games(Set<UInt32>)

    @MainActor
    func admits(_ appID: UInt32, library: GameLibrary) -> Bool {
        switch self {
        case .downloaded: library.isOnDevice(appID)
        case let .games(games): games.contains(appID)
        }
    }

    /// For the header: "3 of 6 downloaded".
    func line(shown: Int, of total: Int) -> String {
        switch self {
        case .downloaded: "\(shown) of \(total) downloaded"
        case .games: "\(shown) of \(total) match your filters"
        }
    }
}

extension EnvironmentValues {
    /// The scope collections open with from this grid; nil opens them whole.
    @Entry var collectionScope: CollectionScope?
}

extension LibraryCollection {
    /// Only the games `admits` keeps, with sub-groups that still hold any.
    func filtered(_ admits: (UInt32) -> Bool) -> LibraryCollection {
        var copy = self
        copy.games = games.filter(admits)
        copy.subgroups = subgroups.map { $0.filtered(admits) }.filter { !$0.allGames.isEmpty }
        copy.inReleaseOrder = inReleaseOrder.filter(admits)
        return copy
    }
}
#endif
