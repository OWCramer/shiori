// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The top of the game page, as Home's lead game (the TV app's show pages): the banner clean
/// at the top with the logo on it, and the art extended below it behind the line on the game
/// and Play's row, flowing into the sections. The extended region is as tall as what it
/// holds (the row grows a line when Steam is unreachable).
struct GamePageHero: View {
    let game: LibraryGame
    let model: GamePageModel
    let metaLine: String
    let bannerHeight: CGFloat
    var overscroll: CGFloat = 0
    /// Content width and side margin, as the sections below.
    let contentWidth: CGFloat
    let margin: CGFloat
    let wide: Bool
    @State private var extensionHeight: CGFloat = 150
    @Environment(\.portraitHero) private var portraitHero

    var body: some View {
        let alignment: HorizontalAlignment = wide ? .leading : .center
        VStack(spacing: 0) {
            if portraitHero {
                // The box art carries its own title.
                RemoteImage(url: game.capsuleLarge ?? game.capsule, fallback: game.header) { ArtworkPlaceholder(title: game.name) }
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12)) }
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 10)
                    .padding(.top, 64)
                    .frame(height: bannerHeight, alignment: .bottom)
                    .accessibilityLabel(game.name)
            } else {
                GameLogo(game: game, maxWidth: wide ? 420 : 300, maxHeight: wide ? 150 : 110, alignment: alignment)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .frame(maxWidth: .infinity, alignment: wide ? .bottomLeading : .bottom)
                    .padding(.bottom, 20)
                    .frame(height: bannerHeight, alignment: .bottom)
                    .accessibilityLabel(game.name)
            }
            VStack(alignment: alignment, spacing: 14) {
                if !metaLine.isEmpty {
                    Text(metaLine)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(wide ? .leading : .center)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                }
                GamePageActionRow(game: game, model: model)
            }
            .padding(.top, 16)
            .padding(.bottom, 28)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { extensionHeight = $0 }
        }
        .frame(maxWidth: contentWidth)
        .padding(.horizontal, margin)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            if portraitHero {
                CoverWash(game: game, height: bannerHeight + extensionHeight + overscroll)
                    .offset(y: -overscroll)
            } else {
                ExtendedHeroArt(game: game, bannerHeight: bannerHeight, extensionHeight: extensionHeight, overscroll: overscroll)
                    .allowsHitTesting(false)
            }
        }
    }
}
/// Behind the cover card: the box art blurred into a wash, fading into the page.
private struct CoverWash: View {
    let game: LibraryGame
    let height: CGFloat

    var body: some View {
        RemoteImage(url: game.capsuleLarge ?? game.capsule, fallback: game.hero) { Color.black }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .blur(radius: 50, opaque: true)
            .saturation(1.3)
            .overlay(.black.opacity(0.35))
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}
#endif
