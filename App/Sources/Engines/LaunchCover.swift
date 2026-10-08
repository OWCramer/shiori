import SwiftUI
import UIKit

/// The game's banner art, logo and a spinner from the moment Play hands over until the engine
/// draws its first frame: the SwiftUI twin of the Ren'Py runtime's cover (RenPyRuntime.m).
struct LaunchCover: View {
    struct Art {
        var hero: UIImage?
        var logo: UIImage?
        var title = ""
    }

    let art: Art

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                if let hero = art.hero {
                    Image(uiImage: hero)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .opacity(0.55)
                }
                VStack(spacing: 28) {
                    if let logo = art.logo {
                        Image(uiImage: logo)
                            .resizable()
                            .scaledToFit()
                            // As wide as half the screen, within a third of its height.
                            .frame(width: proxy.size.width * 0.5, height: proxy.size.height * 0.36)
                            .shadow(color: .black.opacity(0.6), radius: 12, y: 4)
                    } else {
                        Text(art.title)
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: proxy.size.width * 0.5)
                    }
                    ProgressView()
                        .tint(.white.opacity(0.85))
                }
                .offset(y: -16)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Puts the cover up first, then creates the game behind it (engines start synchronously on
/// the main thread, which would otherwise freeze the game page instead), and fades the cover
/// out on the game's first frame, or after 12 seconds whatever happens.
struct CoveredGame<Game: View>: View {
    let art: LaunchCover.Art
    @ViewBuilder let game: (_ firstFrame: @escaping () -> Void) -> Game

    @State private var gameCreated = false
    @State private var covered = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if gameCreated {
                game { lift() }
            }
            if covered {
                LaunchCover(art: art)
                    .transition(.opacity)
            }
        }
        .task {
            // Let the cover reach the screen before the engine blocks the main thread.
            try? await Task.sleep(for: .milliseconds(50))
            gameCreated = true
            try? await Task.sleep(for: .seconds(12))
            lift()
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden()
    }

    private func lift() {
        guard covered else { return }
        withAnimation(.easeInOut(duration: 0.45).delay(0.2)) { covered = false }
    }
}
