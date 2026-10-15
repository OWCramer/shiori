// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Owned games that aren't in the Visual Novels tab, to add by hand.
struct AddVisualNovelView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [LibraryGame] {
        steam.library
            .filter { !curation.isVisualNovel($0) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { game in
                Button {
                    withAnimation { curation.add(game) }
                } label: {
                    HStack(spacing: 12) {
                        CapsuleArt(game: game)
                            .frame(width: 36)
                            .clipShape(.rect(cornerRadius: 4))
                        Text(game.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .alwaysSearchable(text: $query, prompt: "Your Steam games")
            .navigationTitle("Add to Visual Novels")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
