import Kingfisher
import SteamKit
import SwiftUI

/// 600×900 library art, falling back to the landscape header, then to the name.
struct CapsuleArt: View {
    let game: LibraryGame

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                // Decoded at grid size, cached in memory and on disk (Kingfisher).
                KFImage(game.capsule)
                    .placeholder { Rectangle().fill(.fill.tertiary) }
                    .onFailureView { fallback }
                    .downsampling(size: CGSize(width: 400, height: 600))
                    .cacheOriginalImage()
                    .cancelOnDisappear(true)
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                KFImage(game.header)
                    .placeholder { EmptyView() }
                    .onFailureView { EmptyView() }
                    .downsampling(size: CGSize(width: 460, height: 215))
                    .resizable()
                    .scaledToFit()
                Text(game.name)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }
}
