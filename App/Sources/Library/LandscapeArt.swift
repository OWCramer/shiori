import SwiftUI

/// A game's wide banner (the hero the game page shows, a SteamGridDB pick included), filled
/// into a landscape card. Steam's 460×215 header is only the fallback: it's small and has
/// the logo baked in, so cards built from it didn't match the game page.
struct LandscapeArt: View {
    let game: LibraryGame

    var body: some View {
        Color.clear
            .aspectRatio(460 / 215, contentMode: .fit)
            .overlay {
                RemoteImage(url: game.hero, fallback: game.header, downsample: CGSize(width: 960, height: 450)) {
                    ArtworkPlaceholder(title: game.name)
                }
            }
            .clipped()
    }
}
