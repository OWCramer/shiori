// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The iPhone Duo opened like a book (iOS 27.1): the chosen game's page on the left page and
/// the library on the right, with nothing on the fold between them, so the library's tab
/// strip sits at the screen's trailing edge rather than in the middle. The fold comes from
/// the window's `.division` reserved region; with none (every other iPhone and iPad, the
/// Duo's cover screen, or a fold across the middle), the library fills the window as usual.
/// The library stays the same view either way, so folding and unfolding keep its tab and
/// navigation.
struct DuoBook<Library: View>: View {
    @ViewBuilder var library: Library
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var book = BookSelection()

    var body: some View {
        // The whole window, safe areas included, so the fold's frame and the pages line up
        // with the screen; the pages inside still keep the window's safe areas (the library
        // the trailing strip, both the top).
        GeometryReader { proxy in
            let fold = Self.fold(in: proxy)
            HStack(spacing: 0) {
                if let fold {
                    if style == .classic {
                        DuoGamePage(game: book.game)
                            .frame(width: max(0, fold.minX))
                            .environment(\.horizontalSizeClass, .compact)
                        Color.black.frame(width: fold.width)
                    } else {
                        // The pages meet at the spine, each keeping its content off the fold.
                        DuoGamePage(game: book.game)
                            .safeAreaPadding(.trailing, fold.width / 2)
                            .frame(width: max(0, fold.midX))
                            .environment(\.horizontalSizeClass, .compact)
                            .environment(\.portraitHero, style == .cover)
                    }
                }
                library
                    // Off the crease: the library's own black fills the gap up to the spine.
                    .padding(.leading, fold != nil && style != .classic ? (fold?.width ?? 0) / 2 : 0)
                    .frame(width: libraryWidth(fold: fold, in: proxy))
                    // Each page is a phone's width: compact, whatever the whole screen says.
                    .environment(\.horizontalSizeClass, fold == nil ? sizeClass : .compact)
                    .environment(book)
            }
            .overlay {
                if let fold, style != .classic { DuoSpine(fold: fold) }
            }
            .onChange(of: fold == nil, initial: true) { _, single in
                if single {
                    // Folding: the left page's game goes back onto the current tab.
                    if book.isOpen { book.foldedGame = book.game }
                    book.isOpen = false
                } else {
                    if book.game == nil { book.game = defaultGame }
                    book.isOpen = true
                }
            }
        }
        .ignoresSafeArea(.container)
    }

    /// How the opened book looks: `spine` and `cover` meet at the fold with a book's gutter
    /// shading; `cover` shows the game's box art on the left page; `classic` keeps the fold
    /// black. `-ShioriBookStyle` picks one while the design settles.
    enum Style: String { case classic, spine, cover }

    private var style: Style {
        UserDefaults.standard.string(forKey: "ShioriBookStyle").flatMap(Style.init(rawValue:)) ?? .spine
    }

    private func libraryWidth(fold: CGRect?, in proxy: GeometryProxy) -> CGFloat {
        guard let fold else { return proxy.size.width }
        return max(0, proxy.size.width - (style == .classic ? fold.maxX : fold.midX))
    }

    /// Without a pick yet: the game played last, else the first visual novel.
    private var defaultGame: LibraryGame? {
        let history = PlayHistory.shared
        let played = steam.library
            .compactMap { game in history.lastActivity(game.appID).map { (game, $0.date) } }
            .max { $0.1 < $1.1 }?.0
        return played ?? steam.library.first { curation.isVisualNovel($0) }
    }

    /// The fold running top to bottom through the window, if the device is opened out.
    ///
    /// The unfolded Duo reports its fold as an *inactive* division (iOS 27.1 simulator: one
    /// region, 40 points wide including its 20-point margins, down the middle of the
    /// 951×669 window), so inactive regions count too: lying flat is the book this is for.
    /// A fold across the middle (top and bottom halves, laptop-style) isn't a book, nor is
    /// one that would leave a page narrower than a phone.
    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        #if DEBUG
        // `-ShioriFold <points>`: a simulated fold that wide down the middle, for laying out
        // the opened Duo in a simulator (with `-ShioriCanvas 951x669`).
        let simulated = UserDefaults.standard.double(forKey: "ShioriFold")
        if simulated > 0 {
            return CGRect(x: (proxy.size.width - simulated) / 2, y: 0, width: simulated, height: proxy.size.height)
        }
        #endif
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            // An active one first (the hinge bent), else the flat fold.
            let ordered = regions.filter(\.isActive) + regions.filter { !$0.isActive }
            return ordered.lazy.map(\.frame).first { frame in
                frame.height >= frame.width
                    && frame.minX >= minimumPage
                    && proxy.size.width - frame.maxX >= minimumPage
            }
        }
        return nil
    }

    /// The narrowest page the book shows: an iPhone's compact width.
    private static var minimumPage: CGFloat { 320 }
}

/// The left-hand page: the chosen game's page, in a navigation stack of its own.
private struct DuoGamePage: View {
    let game: LibraryGame?

    var body: some View {
        NavigationStack {
            if let game {
                GameDetailView(game: game)
                    .id(game.appID)
                    // UIKit gives every navigation stack on the Duo the trailing inset of the
                    // window's vertical strip (84 points), even one on the left page well
                    // clear of it; the strip carries the library's bars, not this page's
                    // (its only bar item is the title), so the page runs to the fold.
                    .ignoresSafeArea(.container, edges: .trailing)
            } else {
                ContentUnavailableView("Choose a Game", systemImage: "book.pages")
            }
        }
    }
}
/// The gutter of an open book down the fold: the pages darken into it, with a faint highlight
/// on each edge of the crease. Drawn over both pages, it takes no touches.
private struct DuoSpine: View {
    let fold: CGRect

    var body: some View {
        let width = fold.width * 1.6
        LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black.opacity(0.22), location: 0.35),
            .init(color: .black.opacity(0.5), location: 0.48),
            .init(color: .white.opacity(0.07), location: 0.5),
            .init(color: .black.opacity(0.5), location: 0.52),
            .init(color: .black.opacity(0.22), location: 0.65),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .position(x: fold.midX, y: fold.midY)
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}
#endif
