// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
        #if os(iOS)
        // On the iPhone Duo bent like a laptop, the game takes the top half and the laptop pad
        // the bottom (`LaptopPad`). The game keeps its place in the tree either way, so bending
        // or flattening the hinge resizes it rather than starting it again.
        GeometryReader { proxy in
            let fold = LaptopFold.fold(in: proxy)
            VStack(spacing: 0) {
                screen
                    .overlay { if fold != nil { LaptopPointer() } }
                    .frame(height: fold?.minY ?? proxy.size.height)
                    .onGeometryChange(for: CGSize.self, of: \.size) { LaptopPad.shared.area = $0 }
                if let fold {
                    Color.black.frame(height: fold.height)
                    LaptopPadView()
                        .frame(height: max(0, proxy.size.height - fold.maxY))
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.smooth, value: fold == nil)
            .onChange(of: LaptopFold.hasFold(in: proxy), initial: true) { _, fold in OrientationLock.setFoldable(fold) }
        }
        // Nothing here takes text, and the Duo's keyboard mustn't move the halves.
        .ignoresSafeArea()
        .ignoresSafeArea(.keyboard)
        .background(Color.black)
        .onAppear { LaptopPad.shared.reset() }
        .onDisappear { OrientationLock.setFoldable(false) }
        .modifier(CoverSession(lift: lift, gameCreated: $gameCreated))
        #else
        screen.modifier(CoverSession(lift: lift, gameCreated: $gameCreated))
        #endif
    }

    private var screen: some View {
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
    }

    private func lift() {
        guard covered else { return }
        withAnimation(.easeInOut(duration: 0.45).delay(0.2)) { covered = false }
    }
}

/// The cover's timing and the full-screen session around it.
private struct CoverSession: ViewModifier {
    let lift: () -> Void
    @Binding var gameCreated: Bool

    func body(content: Content) -> some View {
        content
            .task {
                // Let the cover reach the screen before the engine blocks the main thread.
                try? await Task.sleep(for: .milliseconds(50))
                gameCreated = true
                try? await Task.sleep(for: .seconds(12))
                lift()
            }
            // A game leaves through its own exit, never by UIKit dismissing the cover (Escape).
            .interactiveDismissDisabled()
            .persistentSystemOverlays(.hidden)
            .hiddenStatusBar()
    }
}
