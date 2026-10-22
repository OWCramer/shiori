// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// What Home says with nothing to show.
struct HomePlaceholder: View {
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading library…").foregroundStyle(.secondary).fixedSize()
            }
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
