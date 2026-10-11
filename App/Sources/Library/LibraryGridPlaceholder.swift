#if os(iOS)
import SwiftUI

/// What an empty Visual Novels or Installed tab says.
struct LibraryGridPlaceholder: View {
    let list: LibraryFilter
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            ProgressView("Loading library…")
        } else if list == .installed {
            ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                   description: Text("Open a game and tap Download."))
        } else if !steam.library.isEmpty {
            ContentUnavailableView("No visual novels", systemImage: "books.vertical",
                                   description: Text("None of your games has Steam's Visual Novel tag. Tap + to add games."))
        } else if steam.isLoggedOn, steam.libraryError == nil {
            ContentUnavailableView("No games", systemImage: "books.vertical")
        }
    }
}
#endif
