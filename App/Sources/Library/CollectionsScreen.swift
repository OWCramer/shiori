#if os(iOS)
import SwiftUI

/// Every collection, to look after them: open or edit one, hide or delete it with a swipe,
/// make a new one, and bring back hidden suggestions. In Settings rows open the editor; in
/// the iPad's sidebar (All Collections) they open the collection's page.
struct CollectionsScreen: View {
    /// Rows open collection pages (`LibraryRoute`) rather than editors.
    var opensPages = false
    @Environment(LibraryCollections.self) private var collections
    @Environment(SteamModel.self) private var steam
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(collections.collections) { collection in
                    link(collection)
                        .swipeActions {
                            Button(collection.isSuggested ? "Hide" : "Delete", systemImage: collection.isSuggested ? "eye.slash" : "trash",
                                   role: .destructive) { collections.hide(collection.id) }
                        }
                }
            } footer: {
                Text("Suggested from Steam's franchise and developer data, VNDB's series and relations, and numbered titles. Edits sync to your other devices through iCloud Keychain.")
            }
            if collections.hiddenSuggestionCount > 0 {
                Section {
                    Button("Show \(collections.hiddenSuggestionCount) Hidden Suggestion\(collections.hiddenSuggestionCount == 1 ? "" : "s")",
                           systemImage: "eye", action: collections.restoreHidden)
                }
            }
        }
        .overlay {
            if collections.collections.isEmpty {
                ContentUnavailableView("No Collections", systemImage: "square.stack",
                                       description: Text("Series in your library appear here, or make your own."))
            }
        }
        .navigationTitle("Collections")
        .toolbar {
            Button("New Collection", systemImage: "plus") { creating = true }
        }
        .sheet(isPresented: $creating) {
            CollectionGamePicker(title: "New Collection", confirmTitle: "Create", naming: "Collection Name") { name, games in
                collections.create(named: name, games: games)
            }
        }
    }

    @ViewBuilder private func link(_ collection: LibraryCollection) -> some View {
        if opensPages {
            NavigationLink(value: LibraryRoute.collection(collection.id)) { row(collection) }
        } else {
            NavigationLink { CollectionEditor(collectionID: collection.id) } label: { row(collection) }
        }
    }

    private func row(_ collection: LibraryCollection) -> some View {
        let lead = collection.inReleaseOrder.first.flatMap { appID in steam.library.first { $0.appID == appID } }
        var detail = "\(collection.allGames.count) game\(collection.allGames.count == 1 ? "" : "s")"
        if !collection.subgroups.isEmpty {
            detail += " · \(collection.subgroups.count) sub-group\(collection.subgroups.count == 1 ? "" : "s")"
        }
        if !collection.isSuggested { detail += " · Yours" }
        return HStack(spacing: 12) {
            Group {
                if let lead { CapsuleArt(game: lead) } else { ArtworkPlaceholder(title: collection.name).aspectRatio(2 / 3, contentMode: .fit) }
            }
            .frame(width: 36)
            .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
