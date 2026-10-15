// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Kingfisher
import SwiftUI

/// The player's Steam avatar in a circle, or the first letter of their name until it loads
/// (or when there's none).
struct SteamAvatar: View {
    let url: URL?
    let name: String
    var size: CGFloat = 52

    var body: some View {
        Group {
            if let url {
                KFImage(url)
                    .placeholder { initial }
                    .onFailureView { initial }
                    .cacheOriginalImage()
                    .downsampling(size: CGSize(width: size * 2, height: size * 2))
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }

    private var initial: some View {
        ZStack {
            Circle().fill(.blue.gradient)
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.title2)
                .bold()
                .foregroundStyle(.white)
        }
    }
}
