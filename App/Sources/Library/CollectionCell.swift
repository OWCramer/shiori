// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A collection in a grid: its games stacked, its name, and where its downloads stand,
/// opening the collection's page.
struct CollectionCell: View {
    let collection: LibraryCollection
    /// The collection's games in this grid, front one first.
    let games: [LibraryGame]
    @Environment(GameLibrary.self) private var library
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(\.collectionScope) private var scope
    @Environment(LibraryCollections.self) private var collections
    @Environment(ShellModel.self) private var shell: ShellModel?

    var body: some View {
        let summary = CollectionSummary(games: games, library: library, engineScans: engineScans)
        NavigationLink(value: LibraryRoute.collection(collection.id, scope: scope)) {
            VStack(alignment: .leading, spacing: 6) {
                CollectionStack(games: games)
                Text(collection.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu {
            if let shell {
                Button("Edit Collection…", systemImage: "pencil") { shell.editCollection(collection.id) }
            }
            Button(removalTitle, systemImage: collection.isSuggested ? "eye.slash" : "trash", role: .destructive) {
                withAnimation { collections.hide(collection.id) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.name), collection")
        .accessibilityValue(summary.line)
    }

    private var removalTitle: String {
        if collection.parentID != nil { return collection.isSuggested ? "Remove Sub-group" : "Delete Sub-group" }
        return collection.isSuggested ? "Hide Suggestion" : "Delete Collection"
    }
}
#endif
