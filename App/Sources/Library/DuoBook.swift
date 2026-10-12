#if os(iOS)
import SwiftUI

/// The iPhone Duo opened flat, like a book (iOS 27.1): the library on the left page and the
/// chosen game's page on the right, with nothing on the fold between them. The fold comes
/// from the window's `.division` reserved region; with none (every other iPhone and iPad,
/// the Duo's cover screen, or the Duo half open across the middle), the library fills the
/// window as usual. The library stays the same view either way, so folding and unfolding
/// keep its tab and navigation.
struct DuoBook<Library: View>: View {
    @ViewBuilder var library: Library
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var book = BookSelection()

    var body: some View {
        GeometryReader { proxy in
            let fold = Self.fold(in: proxy)
            HStack(spacing: 0) {
                library
                    .frame(width: fold.map { max(0, $0.minX) } ?? proxy.size.width)
                    // Each page is a phone's width: compact, whatever the whole screen says.
                    .environment(\.horizontalSizeClass, fold == nil ? sizeClass : .compact)
                    .environment(fold == nil ? nil : book)
                if let fold {
                    Color.black.frame(width: fold.width)
                    DuoGamePage(game: book.game)
                        .frame(width: max(0, proxy.size.width - fold.maxX))
                        .environment(\.horizontalSizeClass, .compact)
                }
            }
            .onChange(of: fold == nil, initial: true) { _, single in
                if !single, book.game == nil { book.game = defaultGame }
            }
        }
    }

    /// Without a pick yet: the game played last, else the first visual novel.
    private var defaultGame: LibraryGame? {
        let history = PlayHistory.shared
        let played = steam.library
            .compactMap { game in history.lastActivity(game.appID).map { (game, $0.date) } }
            .max { $0.1 < $1.1 }?.0
        return played ?? steam.library.first { curation.isVisualNovel($0) }
    }

    /// The fold running top to bottom through the window, if the device is opened flat.
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
            let division = proxy.reservedRegions(kind: .division).first { $0.isActive }?.frame
            // A fold across the middle (half open, top and bottom halves) isn't a book.
            if let division, division.height >= division.width { return division }
        }
        return nil
    }
}

/// The right-hand page: the chosen game's page, in a navigation stack of its own.
private struct DuoGamePage: View {
    let game: LibraryGame?

    var body: some View {
        NavigationStack {
            if let game {
                GameDetailView(game: game)
                    .id(game.appID)
            } else {
                ContentUnavailableView("Choose a Game", systemImage: "book.pages",
                                       description: Text("Pick a game on the left to see it here."))
            }
        }
    }
}
#endif
