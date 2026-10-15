// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Kingfisher
import SwiftUI

/// The game's logo at its own proportions, as large as fits in `maxWidth` × `maxHeight`, so
/// whatever sits above or below it (Home's and the game page's meta line) stays right next
/// to it whatever the logo's shape or the window's width. The name stands in until it
/// loads, or when there's no logo.
struct GameLogo: View {
    let game: LibraryGame
    var maxWidth: CGFloat = 280
    var maxHeight: CGFloat = 110
    var alignment: HorizontalAlignment = .center
    /// The loaded logo's width over its height.
    @State private var aspectRatio: CGFloat?

    /// The largest size of the logo's shape inside the box.
    private var size: CGSize? {
        guard let aspectRatio, aspectRatio > 0 else { return nil }
        let width = min(maxWidth, maxHeight * aspectRatio)
        return CGSize(width: width, height: width / aspectRatio)
    }

    var body: some View {
        if let logo = game.logo {
            KFImage(logo)
                .setProcessor(TrimmedLogoProcessor())
                .placeholder { GameLogoTitle(name: game.name, alignment: alignment) }
                .onFailureView { GameLogoTitle(name: game.name, alignment: alignment) }
                .onSuccess { result in
                    let image = result.image.size
                    if image.height > 0 { aspectRatio = image.width / image.height }
                }
                .cacheOriginalImage()
                .fade(duration: 0.25)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size?.width, height: size?.height)
                .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                .accessibilityLabel(game.name)
        } else {
            GameLogoTitle(name: game.name, alignment: alignment)
                .frame(maxWidth: maxWidth)
        }
    }
}
