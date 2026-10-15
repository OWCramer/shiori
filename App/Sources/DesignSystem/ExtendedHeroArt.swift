// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A game's banner as the TV app's show pages have it (Home's lead game and the game page):
/// clean at the top, and below it the art extended downward, mirrored and blurred
/// (`backgroundExtensionEffect`), into a soft region that holds the line on the game and
/// its actions (the logo stays on the banner).
struct ExtendedHeroArt: View {
    let game: LibraryGame
    /// Height of the banner itself (the game page's).
    let bannerHeight: CGFloat
    /// Height of the extended region under it.
    let extensionHeight: CGFloat
    /// How far the page is pulled past its top.
    var overscroll: CGFloat = 0

    var body: some View {
        StretchyHeader(height: bannerHeight + extensionHeight, overscroll: overscroll) {
            // The extension fills the bottom safe-area padding with the art's mirrored,
            // blurred edge; the banner keeps its own frame above it.
            HeroArtwork(game: game)
                .backgroundExtensionEffect()
                .safeAreaPadding(.bottom, extensionHeight)
                .overlay {
                    // The status bar over the top of the art, and the extended region darkening
                    // into the backdrop so its text reads on light art too.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.35), location: 0),
                        .init(color: .clear, location: 0.12),
                        // A light shade where the logo sits on the banner's foot.
                        .init(color: .clear, location: bannerHeight / (bannerHeight + extensionHeight) - 0.2),
                        .init(color: .black.opacity(0.35), location: bannerHeight / (bannerHeight + extensionHeight)),
                        .init(color: .black.opacity(0.55), location: bannerHeight / (bannerHeight + extensionHeight) + 0.14),
                        .init(color: .black.opacity(0.75), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .contentShape(.rect)
    }
}
#endif
