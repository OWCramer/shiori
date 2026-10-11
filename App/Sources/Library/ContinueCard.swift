#if os(iOS)
import SwiftUI

/// A game you've played: its landscape art with a scrim, its name and when you last
/// played in plain text, and one solid Play button. Content, so no Liquid Glass on it.
struct ContinueCard: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var canPlay: Bool { games.playBlocker(appID: game.appID) == nil }
    private var launching: Bool { games.launchPhase(for: game.appID) != nil }

    var body: some View {
        NavigationLink(value: game) {
            HeaderArt(game: game)
                .frame(width: sizeClass == .regular ? ShowcaseMetrics.wideCard : ShowcaseMetrics.card)
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.name)
                            .font(.headline)
                            .lineLimit(1)
                        if let activity = PlayHistory.shared.lastActivity(game.appID) {
                            Text(activity.description)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.leading, 14)
                    .padding(.trailing, canPlay ? 72 : 14)
                    .padding(.top, 36)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                    }
                }
                .clipShape(.rect(cornerRadius: ShowcaseMetrics.cardRadius))
                .contentShape(.rect(cornerRadius: ShowcaseMetrics.cardRadius))
        }
        .buttonStyle(.plain)
        // Outside the link's label, so it takes its own taps.
        .overlay(alignment: .bottomTrailing) {
            if canPlay {
                Button(action: play) {
                    if launching {
                        ProgressView().tint(.white)
                    } else {
                        Label("Play \(game.name)", systemImage: "play.fill").labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.green)
                .disabled(launching)
                .padding(12)
            }
        }
        .hoverEffect(.lift)
        .contextMenu { LibraryGameMenuItems(game: game) }
    }

    private func play() { games.play(appID: game.appID) }
}
#endif
