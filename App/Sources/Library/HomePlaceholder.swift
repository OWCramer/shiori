#if os(iOS)
import SwiftUI

/// What Home says with nothing to show.
struct HomePlaceholder: View {
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            ProgressView("Loading library…")
        } else if let error = steam.libraryError {
            ContentUnavailableView("Couldn't Load Library", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if !steam.library.isEmpty {
            ContentUnavailableView("No Visual Novels", systemImage: "books.vertical",
                                   description: Text("Tap + to add games."))
        } else {
            ContentUnavailableView("No Games", systemImage: "books.vertical",
                                   description: steam.offlineReason.map { Text($0) })
        }
    }
}
#endif
