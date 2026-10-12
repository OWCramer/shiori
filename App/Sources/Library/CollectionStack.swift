#if os(iOS)
import SwiftUI

/// A collection's capsules stacked: its first game in front, the next two peeking out
/// above it, and how many games it holds in the corner. The same footprint as one capsule,
/// so stacks and games line up in a grid.
struct CollectionStack: View {
    let games: [LibraryGame]
    var count: Int?

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(alignment: .top) {
                if games.count > 2 { layer(games[2]).padding(.horizontal, 20) }
            }
            .overlay(alignment: .top) {
                if games.count > 1 { layer(games[1]).padding(.horizontal, 12).padding(.top, 6) }
            }
            .overlay(alignment: .bottom) {
                if let front = games.first {
                    capsule(front)
                        .overlay(alignment: .topTrailing) { badge }
                        .background {
                            RoundedRectangle(cornerRadius: ShowcaseMetrics.capsuleRadius)
                                .fill(.black)
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
                        }
                        .padding(.horizontal, 4)
                }
            }
            .accessibilityHidden(true)
    }

    private func layer(_ game: LibraryGame) -> some View {
        capsule(game)
            .overlay { RoundedRectangle(cornerRadius: ShowcaseMetrics.capsuleRadius).fill(.black.opacity(0.25)) }
    }

    private func capsule(_ game: LibraryGame) -> some View {
        CapsuleArt(game: game)
            .clipShape(.rect(cornerRadius: ShowcaseMetrics.capsuleRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ShowcaseMetrics.capsuleRadius)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
            }
    }

    private var badge: some View {
        Label("\(count ?? games.count)", systemImage: "square.stack.fill")
            .font(.caption.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.65), in: .capsule)
            .padding(6)
    }
}
#endif
