#if os(iOS)
import SwiftUI

/// What an empty library grid says.
struct LibraryGridPlaceholder: View {
    let section: LibrarySection
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            ProgressView("Loading library…")
        } else {
            switch section {
            case .installed:
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Open a game and tap Download."))
            case .recentlyPlayed:
                ContentUnavailableView("Nothing played yet", systemImage: "clock",
                                       description: nil)
            case .engine:
                ContentUnavailableView("No games", systemImage: "cpu",
                                       description: nil)
            case .visualNovels:
                if !steam.library.isEmpty {
                    ContentUnavailableView("No visual novels", systemImage: "books.vertical",
                                           description: Text("Tap + to add games."))
                } else if steam.isLoggedOn, steam.libraryError == nil {
                    ContentUnavailableView("No games", systemImage: "books.vertical")
                }
            }
        }
    }
}
#endif
