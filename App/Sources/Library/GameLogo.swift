import Kingfisher
import SwiftUI

/// The game's logo at its own proportions, as large as fits in `maxWidth` × `maxHeight`, so
/// whatever sits above or below it (Home's eyebrow, its meta line) stays right next to it
/// whatever the logo's shape or the window's width. The name stands in until it loads, or
/// when there's no logo.
struct GameLogo: View {
    let game: LibraryGame
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 110
    var alignment: HorizontalAlignment = .center

    var body: some View {
        if let logo = game.logo {
            KFImage(logo)
                .placeholder { GameLogoTitle(name: game.name, alignment: alignment) }
                .onFailureView { GameLogoTitle(name: game.name, alignment: alignment) }
                .cacheOriginalImage()
                .fade(duration: 0.25)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                .accessibilityLabel(game.name)
        } else {
            GameLogoTitle(name: game.name, alignment: alignment)
                .frame(maxWidth: maxWidth)
        }
    }
}
