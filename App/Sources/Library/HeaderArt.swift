// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Landscape Steam header art (460×215), falling back to the hero.
struct HeaderArt: View {
    let game: LibraryGame

    var body: some View {
        RemoteImage(url: game.header, fallback: game.hero, downsample: CGSize(width: 460, height: 215)) {
            ArtworkPlaceholder(title: game.name)
        }
        .aspectRatio(460 / 215, contentMode: .fit)
    }
}
