#if os(iOS)
import SwiftUI

/// The game you were last playing, full-bleed: its art, logo and what it is, opening its
/// page when tapped, with its actions on glass below the logo.
struct HomeHero: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var record: GameRecord? {
        if case let .installed(record) = games.status(for: game.appID) { record } else { nil }
    }

    /// "Played today · Ren'Py 8 · 2.09 GB".
    private var metaLine: String {
        var parts: [String] = []
        if let activity = PlayHistory.shared.lastActivity(game.appID) { parts.append(activity.description) }
        if let record {
            parts.append(Playability.badge(record.engine, appID: game.appID))
            parts.append(record.sizeBytes.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let wide = sizeClass == .regular
        let alignment: HorizontalAlignment = wide ? .leading : .center
        NavigationLink(value: game) {
            HomeHeroArt(game: game, wide: wide)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(game.name), \(metaLine)")
        .accessibilityHint("Opens the game's page")
        // Outside the link's label: the text lets taps through to the art; the buttons
        // take their own.
        .overlay(alignment: wide ? .bottomLeading : .bottom) {
            VStack(alignment: alignment, spacing: 16) {
                VStack(alignment: alignment, spacing: 10) {
                    GameLogo(game: game, maxWidth: wide ? 420 : 300, maxHeight: wide ? 150 : 110, alignment: alignment)
                    // The eyebrow sits on the meta line, under the logo: logos carry
                    // transparent margins, so anything above one floats loose.
                    HomeHeroCaption(eyebrow: PlayHistory.shared.lastActivity(game.appID) == nil ? "Ready to Play" : "Continue",
                                    detail: metaLine)
                        .multilineTextAlignment(wide ? .leading : .center)
                }
                .shadow(color: .black.opacity(0.6), radius: 6)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                HomeActionRow(game: game, canSync: record != nil)
            }
            .padding(.horizontal, wide ? ShowcaseMetrics.wideMargin : ShowcaseMetrics.margin)
            .padding(.bottom, 28)
        }
    }
}
#endif
