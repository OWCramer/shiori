#if os(iOS)
import SwiftUI

/// The game you were last playing, full-bleed: its art, logo and what it is, opening its
/// page when tapped, with its actions on glass below the logo.
struct HomeHero: View {
    let game: LibraryGame
    var overscroll: CGFloat = 0
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

    /// The extended region under the banner: room for the line and the actions, bringing the
    /// hero to about two-thirds of an iPhone screen, while on iPad the next shelf still
    /// starts on screen.
    private func extensionHeight(wide: Bool) -> CGFloat {
        // The line and the actions (with breathing room), more on iPad's wider row.
        wide ? 300 : 180
    }

    var body: some View {
        let wide = sizeClass == .regular
        let alignment: HorizontalAlignment = wide ? .leading : .center
        NavigationLink(value: game) {
            HomeHeroArt(game: game, bannerHeight: GameHeroHeader.standardHeight,
                        extensionHeight: extensionHeight(wide: wide), overscroll: overscroll)
        }
        .buttonStyle(NoPressButtonStyle())
        .accessibilityLabel("\(game.name), \(metaLine)")
        .accessibilityHint("Opens the game's page")
        // Outside the link's label: the logo and the line let taps through to the art; the
        // buttons take their own. The logo stays on the banner; the line and the actions sit
        // in the extended region under it, as on the TV app's show pages.
        .overlay(alignment: .top) {
            let banner = GameHeroHeader.standardHeight
            VStack(alignment: alignment, spacing: 0) {
                GameLogo(game: game, maxWidth: wide ? 420 : 300, maxHeight: wide ? 150 : 110, alignment: alignment)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .frame(maxWidth: .infinity, alignment: wide ? .bottomLeading : .bottom)
                    .frame(height: banner - 20, alignment: .bottom)
                    .padding(.bottom, 20)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                VStack(alignment: alignment, spacing: 16) {
                    HomeHeroCaption(eyebrow: PlayHistory.shared.lastActivity(game.appID) == nil ? "Ready to Play" : "Continue",
                                    detail: metaLine)
                        .multilineTextAlignment(wide ? .leading : .center)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    HomeActionRow(game: game, canSync: record != nil)
                }
                .frame(maxWidth: .infinity, alignment: wide ? .leading : .center)
                // At the foot of the extended region, next to the shelves below.
                .frame(height: extensionHeight(wide: wide) - 24, alignment: .bottom)
            }
            .padding(.horizontal, wide ? ShowcaseMetrics.wideMargin : ShowcaseMetrics.margin)
        }
    }
}
#endif
