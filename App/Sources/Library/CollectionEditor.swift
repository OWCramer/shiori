#if os(iOS)
import SwiftUI

/// Editing a collection (or sub-group): its name, its games (remove with a swipe or Edit,
/// add with the picker), its sub-groups (reorder, open, hide or delete, make a new one),
/// merging it into another collection, and hiding it (a suggestion) or deleting it (one
/// the user made). Changes apply as they're made, and sync to his other devices.
struct CollectionEditor: View {
    let collectionID: String
    @Environment(LibraryCollections.self) private var collections
    @Environment(SteamModel.self) private var steam
    @State private var name = ""
    @State private var pickingGames = false
    @State private var makingSubgroup = false
    @State private var confirmingRemoval = false
    @State private var merging: LibraryCollection?

    private var collection: LibraryCollection? { collections.collection(id: collectionID) }

    var body: some View {
        if let collection {
            form(collection)
        } else {
            ContentUnavailableView("No Collection", systemImage: "square.stack",
                                   description: Text("This collection was removed."))
        }
    }

    private func form(_ collection: LibraryCollection) -> some View {
        let byID = Dictionary(steam.library.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        let isSubgroup = collection.parentID != nil
        return Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(rename)
            } header: {
                Text("Name")
            } footer: {
                if collection.isSuggested {
                    Text("Suggested from Steam and VNDB. Your changes stay when the suggestions are refreshed.")
                }
            }

            Section {
                ForEach(collection.games, id: \.self) { appID in
                    if let game = byID[appID] { gameRow(game) }
                }
                .onDelete { offsets in
                    collections.remove(offsets.map { collection.games[$0] }, from: collection.id)
                }
                Button("Add Games…", systemImage: "plus") { pickingGames = true }
            } header: {
                Text(isSubgroup || collection.subgroups.isEmpty ? "Games" : "Games Not in a Sub-group")
            }

            if !isSubgroup {
                Section {
                    ForEach(collection.subgroups) { sub in
                        NavigationLink {
                            CollectionEditor(collectionID: sub.id)
                        } label: {
                            LabeledContent(sub.name, value: "\(sub.games.count)")
                        }
                    }
                    .onMove { from, to in
                        var order = collection.subgroups.map(\.id)
                        order.move(fromOffsets: from, toOffset: to)
                        collections.setSubgroupOrder(order, in: collection.id)
                    }
                    .onDelete { offsets in
                        for index in offsets { collections.hide(collection.subgroups[index].id) }
                    }
                    Button("New Sub-group…", systemImage: "plus.square.on.square") { makingSubgroup = true }
                } header: {
                    Text("Sub-groups")
                } footer: {
                    Text("A sub-group shows as its own stack on the collection's page. Removing a suggested one puts its games back in the collection.")
                }
            }

            Section {
                Menu {
                    ForEach(mergeTargets(for: collection)) { target in
                        Button(target.name) { merging = target }
                    }
                } label: {
                    Label("Merge Into…", systemImage: "arrow.triangle.merge")
                }
                .disabled(mergeTargets(for: collection).isEmpty)
                Button(role: .destructive) {
                    confirmingRemoval = true
                } label: {
                    Label(removalTitle(collection), systemImage: collection.isSuggested ? "eye.slash" : "trash")
                }
            } footer: {
                Text(collection.isSuggested
                     ? "Hiding a suggestion leaves its games ungrouped. Settings › Collections brings hidden suggestions back."
                     : "Deleting a collection leaves its games ungrouped.")
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .onAppear { name = collection.name }
        .onDisappear(perform: rename)
        .sheet(isPresented: $pickingGames) {
            CollectionGamePicker(title: "Add Games", confirmTitle: "Done", selected: Set(collection.allGames)) { _, picked in
                applyPicked(picked, to: collection)
            }
        }
        .sheet(isPresented: $makingSubgroup) {
            CollectionGamePicker(title: "New Sub-group", confirmTitle: "Create", naming: "Sub-group Name") { name, picked in
                collections.create(named: name, games: picked, parent: collection.id)
            }
        }
        .confirmationDialog(removalTitle(collection) + "?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(removalTitle(collection), role: .destructive) { collections.hide(collection.id) }
        } message: {
            Text("Its \(collection.allGames.count) games stay in your library.")
        }
        .confirmationDialog("Merge \(collection.name) into \(merging?.name ?? "")?", isPresented: mergingBinding,
                            titleVisibility: .visible, presenting: merging) { target in
            Button("Merge") { collections.merge(collection.id, into: target.id) }
        } message: { _ in
            Text("Its games\(collection.subgroups.isEmpty ? "" : " and sub-groups") join the other collection.")
        }
    }

    private func gameRow(_ game: LibraryGame) -> some View {
        HStack(spacing: 12) {
            CapsuleArt(game: game)
                .frame(width: 30)
                .clipShape(.rect(cornerRadius: 5))
            Text(game.name)
                .lineLimit(2)
        }
    }

    private var mergingBinding: Binding<Bool> {
        Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })
    }

    /// Other collections it can fold into: top-level ones, and for a sub-group its siblings too.
    private func mergeTargets(for collection: LibraryCollection) -> [LibraryCollection] {
        var targets = collections.collections.filter { $0.id != collection.id && $0.id != collection.parentID }
        if let parent = collection.parentID, let siblings = collections.collection(id: parent)?.subgroups {
            targets = siblings.filter { $0.id != collection.id } + targets
        }
        return targets
    }

    private func removalTitle(_ collection: LibraryCollection) -> String {
        collection.isSuggested ? (collection.parentID == nil ? "Hide Suggestion" : "Remove Sub-group")
            : (collection.parentID == nil ? "Delete Collection" : "Delete Sub-group")
    }

    private func rename() {
        guard let collection, !name.trimmingCharacters(in: .whitespaces).isEmpty, name != collection.name else { return }
        collections.rename(collection.id, to: name)
    }

    /// The picker's choice: new games join this collection; unticked ones leave it (or the
    /// sub-group they were in).
    private func applyPicked(_ picked: [UInt32], to collection: LibraryCollection) {
        let current = Set(collection.allGames)
        let added = picked.filter { !current.contains($0) }
        if !added.isEmpty { collections.add(added, to: collection.id) }
        let kept = Set(picked)
        let removedDirect = collection.games.filter { !kept.contains($0) }
        if !removedDirect.isEmpty { collections.remove(removedDirect, from: collection.id) }
        for sub in collection.subgroups {
            let removed = sub.games.filter { !kept.contains($0) }
            if !removed.isEmpty { collections.remove(removed, from: sub.id) }
        }
    }
}
#endif
