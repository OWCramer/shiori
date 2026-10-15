// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Picks games for a collection: the Visual Novels tab's and downloaded games (searching
/// finds any owned game), ticked when chosen, each with the collection it's in now. With
/// `naming`, a name field leads (a new collection or sub-group).
struct CollectionGamePicker: View {
    let title: String
    let confirmTitle: String
    /// The name field's placeholder; nil for no name field.
    var naming: String?
    let onDone: (_ name: String, _ games: [UInt32]) -> Void
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var library
    @Environment(LibraryCuration.self) private var curation
    @Environment(LibraryCollections.self) private var collections
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UInt32>
    @State private var name = ""
    @State private var search = ""
    private let initial: Set<UInt32>

    init(title: String, confirmTitle: String, naming: String? = nil, selected: Set<UInt32> = [],
         onDone: @escaping (_ name: String, _ games: [UInt32]) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.naming = naming
        self.onDone = onDone
        initial = selected
        _selection = State(initialValue: selected)
    }

    private var candidates: [LibraryGame] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return steam.library.filter { game in
            if !query.isEmpty { return game.name.localizedStandardContains(query) }
            return initial.contains(game.appID) || curation.isVisualNovel(game) || library.isOnDevice(game.appID)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let naming {
                    Section("Name") {
                        TextField(naming, text: $name)
                            .textInputAutocapitalization(.words)
                    }
                }
                Section {
                    ForEach(candidates) { game in
                        row(game)
                    }
                } header: {
                    Text(selection.count == 1 ? "1 Game Chosen" : "\(selection.count) Games Chosen")
                }
            }
            .searchable(text: $search, prompt: "Search Your Library")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle, action: confirm)
                        .disabled(naming != nil && selection.isEmpty)
                }
            }
        }
    }

    private func row(_ game: LibraryGame) -> some View {
        let chosen = selection.contains(game.appID)
        let current = collections.collection(of: game.appID)
        return Button {
            if chosen { selection.remove(game.appID) } else { selection.insert(game.appID) }
        } label: {
            HStack(spacing: 12) {
                CapsuleArt(game: game)
                    .frame(width: 36)
                    .clipShape(.rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let current {
                        Text("In \(current.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func confirm() {
        // Games in the order they appear in the library.
        let order = steam.library.map(\.appID)
        onDone(name, order.filter(selection.contains))
        dismiss()
    }
}
#endif
