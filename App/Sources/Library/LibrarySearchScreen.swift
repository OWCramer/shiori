#if os(iOS)
import SwiftUI

/// The Search tab: every game you own on Steam, by name or app ID, visual novels first and
/// then the rest of the library. Before typing, the games played most recently.
struct LibrarySearchScreen: View {
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @State private var query = ""
    @State private var path: [LibraryRoute] = []

    private var matches: [LibraryGame] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        return steam.library.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.appID) == query }
    }

    /// Played or saved, newest first: a start before typing.
    private var recent: [LibraryGame] {
        let history = PlayHistory.shared
        return steam.library
            .compactMap { game in history.lastActivity(game.appID).map { (game, $0.date) } }
            .sorted { $0.1 > $1.1 }
            .prefix(12)
            .map(\.0)
    }

    var body: some View {
        let matches = matches
        let visualNovels = matches.filter { curation.isVisualNovel($0) }
        let others = matches.filter { !curation.isVisualNovel($0) }
        let recent = query.isEmpty ? recent : []
        BookHandoffStack(path: $path, tab: .search) {
            ScrollView {
                VStack(alignment: .leading, spacing: ShowcaseMetrics.shelfSpacing) {
                    if !recent.isEmpty {
                        LibrarySearchGroup(title: "Recently Played", games: recent)
                    }
                    if !visualNovels.isEmpty {
                        LibrarySearchGroup(title: "Visual Novels", games: visualNovels)
                    }
                    if !others.isEmpty {
                        LibrarySearchGroup(title: "Other Games", games: others)
                    }
                }
                .padding(.vertical, 8)
            }
            .overlay {
                if query.isEmpty, recent.isEmpty {
                    ContentUnavailableView("Search Your Library", systemImage: "magnifyingglass",
                                           description: Text("Every game you own on Steam, by name or app ID."))
                } else if !query.isEmpty, matches.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Your Steam games")
            .libraryDestinations()
        }
    }
}
#endif
