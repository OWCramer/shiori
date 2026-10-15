// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Add to Collection: every collection and its sub-groups, the one the games are in now
/// ticked; New Collection at the top.
struct AddToCollectionView: View {
    let games: [UInt32]
    @Environment(LibraryCollections.self) private var collections
    @Environment(ShellModel.self) private var shell
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var shown: [LibraryCollection] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return collections.collections }
        return collections.collections.filter { collection in
            collection.name.localizedStandardContains(query) || collection.subgroups.contains { $0.name.localizedStandardContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("New Collection…", systemImage: "plus.square.on.square") {
                        // Swapping the sheet: the shell presents the next one.
                        shell.collectionSheet = .new(games)
                    }
                }
                Section {
                    ForEach(shown) { collection in
                        row(collection, indented: false)
                        ForEach(collection.subgroups) { row($0, indented: true) }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search Collections")
            .navigationTitle(games.count == 1 ? "Add to Collection" : "Add \(games.count) Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func row(_ collection: LibraryCollection, indented: Bool) -> some View {
        let containsAll = games.allSatisfy { collection.games.contains($0) }
        return Button {
            collections.add(games, to: collection.id)
            dismiss()
        } label: {
            HStack {
                Label(collection.name, systemImage: indented ? "square.stack" : "square.stack.3d.up")
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(collection.allGames.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if containsAll {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Added")
                }
            }
            .padding(.leading, indented ? 28 : 0)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(containsAll)
    }
}
#endif
