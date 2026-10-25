// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The left of a game's page laid out wide (`GameDetailView.sideBySide`), as Music holds an
/// album's cover: the game's box art whole, as a card over a wash of it, with the line on the
/// game and Play's row beneath. It doesn't scroll.
struct GamePageCover: View {
    let game: LibraryGame
    let model: GamePageModel
    let metaLine: String

    var body: some View {
        VStack(spacing: 18) {
            // The box art carries the game's title.
            RemoteImage(url: game.capsuleLarge ?? game.capsule, fallback: game.header) { ArtworkPlaceholder(title: game.name) }
                .aspectRatio(2 / 3, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)) }
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
                .frame(maxHeight: .infinity)
                .accessibilityLabel(game.name)
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
            }
            GamePageActionRow(game: game, model: model)
        }
        .padding(.horizontal, GamePageMetrics.wideMargin)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
