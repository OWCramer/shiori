// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Play (or what the game's state calls for), Details, Sync Now and More: controls over
/// the art, so on Liquid Glass, all one size (large controls, past the 44-point minimum).
struct HomeActionRow: View {
    let game: LibraryGame
    var canSync: Bool

    var body: some View {
        // Words where they fit. Narrower windows first leave Sync Now to the More menu
        // (it's there too), then drop Details' word, then Play's (the Duo's cover screen).
        ViewThatFits(in: .horizontal) {
            HomeActionButtons(game: game, showsSync: canSync, labels: 2)
            HomeActionButtons(game: game, showsSync: false, labels: 2)
            HomeActionButtons(game: game, showsSync: false, labels: 1)
            HomeActionButtons(game: game, showsSync: false, labels: 0)
        }
        .controlSize(.large)
    }
}
#endif
