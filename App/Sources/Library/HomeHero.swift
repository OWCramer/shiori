// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The game you were last playing, full-bleed: its art, logo and what it is, opening its
/// page when tapped, with its actions on glass below the logo.
struct HomeHero: View {
    let game: LibraryGame
    /// The height Home has on screen, for the banner's height.
    var viewportHeight: CGFloat = 0
    var overscroll: CGFloat = 0
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var record: GameRecord? {
        games.record(for: game.appID)
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
    /// hero to about two-thirds of an iPhone screen. iPad's line fits on one row, so its
    /// region is shorter and the actions sit close under the banner.
    private func extensionHeight(wide: Bool) -> CGFloat {
        // Short screens (an iPhone in landscape): the line fits on one row, so less room.
        if viewportHeight > 0, viewportHeight < 600 { return 120 }
        return wide ? 150 : 180
    }

    private var bannerHeight: CGFloat { GameHeroHeader.height(forViewport: viewportHeight) }

    /// Trying out (`-ShioriHomeHero extend|card`): the art under the iPhone Duo's side strip,
    /// opened with a plain push; or the whole header as an inset card that zooms.
    private enum Style: String { case cutoff, extend, card }
    private var style: Style {
        UserDefaults.standard.string(forKey: "ShioriHomeHero").flatMap(Style.init(rawValue:)) ?? .extend
    }

    var body: some View {
        switch style {
        case .card:
            header
                .clipShape(.rect(cornerRadius: 32))
                .padding(.horizontal, sizeClass == .regular ? ShowcaseMetrics.wideMargin : ShowcaseMetrics.margin)
                .padding(.top, 8)
                .safeAreaPadding(.top)
        default:
            header
        }
    }

    private var header: some View {
        let wide = sizeClass == .regular
        let alignment: HorizontalAlignment = wide ? .leading : .center
        return GameLink(game: game, zooms: style != .extend) {
            ExtendedHeroArt(game: game, bannerHeight: bannerHeight,
                        extensionHeight: extensionHeight(wide: wide), overscroll: style == .card ? 0 : overscroll)
                .ignoresSafeArea(.container, edges: style == .extend ? .horizontal : [])
        }
        .buttonStyle(NoPressButtonStyle())
        .accessibilityLabel("\(game.name), \(metaLine)")
        .accessibilityHint("Opens the game's page")
        // Outside the link's label: the logo and the line let taps through to the art; the
        // buttons take their own. The logo stays on the banner; the line and the actions sit
        // in the extended region under it, as on the TV app's show pages.
        .overlay(alignment: .top) {
            let banner = bannerHeight
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
