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
