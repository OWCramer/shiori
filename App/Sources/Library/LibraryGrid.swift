// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// An adaptive grid of capsules, with collections as stacked tiles.
struct LibraryGrid: View {
    let items: [LibraryGridItem]
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(items: [LibraryGridItem]) {
        self.items = items
    }

    init(games: [LibraryGame]) {
        items = games.map(LibraryGridItem.game)
    }

    var body: some View {
        let _ = RenderProbe.hit("LibraryGrid")
        let minimum = sizeClass == .regular ? ShowcaseMetrics.wideGridMinimum : ShowcaseMetrics.gridMinimum
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16, alignment: .top)],
                  spacing: ShowcaseMetrics.gridRowSpacing) {
            ForEach(items) { item in
                switch item {
                case let .game(game): LibraryCell(game: game)
                case let .collection(collection, games): CollectionCell(collection: collection, games: games)
                }
            }
        }
        .padding(.horizontal, ShowcaseMetrics.margin)
    }
}
#endif
