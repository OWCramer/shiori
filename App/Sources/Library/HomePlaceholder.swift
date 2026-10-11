#if os(iOS)
import SwiftUI

/// What Home says with nothing to show.
struct HomePlaceholder: View {
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            ProgressView("Loading library…")
        } else if let error = steam.libraryError {
            ContentUnavailableView("Couldn't load your library", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if !steam.library.isEmpty {
            ContentUnavailableView("No visual novels yet", systemImage: "books.vertical",
                                   description: Text("None of your games has Steam's Visual Novel tag. Tap + to add games."))
        } else {
            ContentUnavailableView("No games yet", systemImage: "books.vertical",
                                   description: Text(steam.offlineReason ?? "Your Steam library appears here once it loads."))
        }
    }
}
#endif
