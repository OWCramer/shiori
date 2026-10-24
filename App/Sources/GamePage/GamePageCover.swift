// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The left of a game's page laid out wide (`GameDetailView.sideBySide`), as Music's album
/// page holds its cover: the game's art filling the column and fading into the page, with the
/// logo, the line on the game and Play's row over its foot. It doesn't scroll.
struct GamePageCover: View {
    let game: LibraryGame
    let model: GamePageModel
    let metaLine: String

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            GameLogo(game: game, maxWidth: 320, maxHeight: 120)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .accessibilityLabel(game.name)
            if !metaLine.isEmpty {
                Text(metaLine)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
            GamePageActionRow(game: game, model: model)
        }
        .padding(.horizontal, GamePageMetrics.wideMargin)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Sized to the column (the art fills it, cropped), so the fade below meets its edge.
            Color.clear
                .overlay { HeroArtwork(game: game).scaledToFill() }
                .clipped()
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.35), location: 0), .init(color: .clear, location: 0.18),
                                           .init(color: .clear, location: 0.45), .init(color: .black.opacity(0.75), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}
#endif
