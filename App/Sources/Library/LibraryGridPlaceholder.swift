// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// What an empty library grid says.
struct LibraryGridPlaceholder: View {
    let section: LibrarySection
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading library…").foregroundStyle(.secondary).fixedSize()
            }
        } else {
            switch section {
            case .installed:
                ContentUnavailableView("No Installed Games", systemImage: "arrow.down.circle",
                                       description: Text("Open a game and tap Download."))
            case .recentlyPlayed:
                ContentUnavailableView("No Recently Played Games", systemImage: "clock")
            case .engine:
                ContentUnavailableView("No Games", systemImage: "cpu")
            case .visualNovels:
                if !steam.library.isEmpty {
                    ContentUnavailableView("No Visual Novels", systemImage: "books.vertical",
                                           description: Text("Tap + to add games."))
                } else if steam.isLoggedOn, steam.libraryError == nil {
                    ContentUnavailableView("No Games", systemImage: "books.vertical")
                }
            }
        }
    }
}
#endif
