#if os(iOS)
import SwiftUI

/// Home's lead artwork, darkened where its text sits and fading into the backdrop.
struct HomeHeroArt: View {
    let game: LibraryGame
    let wide: Bool

    var body: some View {
        // The game page's banner at the game page's height, so it's cropped the same way.
        HeroArtwork(game: game)
            .frame(height: GameHeroHeader.standardHeight)
            .backgroundExtensionEffect()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.15), .init(color: .black.opacity(0.45), location: 0.5), .init(color: .black.opacity(0.8), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Wide windows put the text at the leading side: darken that side too.
            .overlay {
                if wide {
                    LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .clear, location: 0.6)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            // The art fades into the tinted backdrop instead of ending on an edge.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .contentShape(.rect)
    }
}
#endif
