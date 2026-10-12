#if os(iOS)
import SwiftUI

/// The hero's logo, moving against the art's pan by a smaller amount so it floats in front.
struct ParallaxLogo: View {
    let game: LibraryGame
    let parallax: HeroParallax
    var maxWidth: CGFloat
    var maxHeight: CGFloat
    var alignment: HorizontalAlignment

    var body: some View {
        GameLogo(game: game, maxWidth: maxWidth, maxHeight: maxHeight, alignment: alignment)
            .offset(x: -parallax.tilt * HeroParallax.range * HeroParallax.logoShare)
    }
}
#endif
