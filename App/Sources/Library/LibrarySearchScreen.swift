#if os(iOS)
import SwiftUI

/// The Search tab: every game you own on Steam, by name or app ID.
struct LibrarySearchScreen: View {
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @State private var query = ""
    @State private var path: [LibraryGame] = []

    private var results: [LibraryGame] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        let matches = steam.library.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.appID) == query }
        // Visual novels first, then the rest of the library.
        return matches.filter { curation.isVisualNovel($0) } + matches.filter { !curation.isVisualNovel($0) }
    }

    var body: some View {
        let results = results
        NavigationStack(path: $path) {
            ScrollView {
                LibraryGrid(games: results)
                    .padding(.vertical, 8)
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                           description: Text("Every game you own on Steam, by name or app ID, visual novels first."))
                } else if results.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Your Steam games")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
        }
    }
}
#endif
