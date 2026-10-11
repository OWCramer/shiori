#if os(iOS)
import SwiftUI

/// The Visual Novels or Installed tab: a grid of the games in it.
struct LibraryGridScreen: View {
    let list: LibraryFilter
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(ShellModel.self) private var shell
    @AppStorage private var sort: LibrarySort
    @State private var path: [LibraryGame] = []

    init(list: LibraryFilter) {
        self.list = list
        _sort = AppStorage(wrappedValue: .name, "librarySort.\(list == .visualNovels ? "visualNovels" : "installed")")
    }

    private var shown: [LibraryGame] {
        let filtered = steam.library.filter { game in
            switch list {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.status(for: game.appID) != .notInstalled
            }
        }
        let history = PlayHistory.shared
        return sort.sorted(filtered, lastActivity: { history.lastActivity($0)?.date }, size: size(of:))
    }

    private func size(of game: LibraryGame) -> UInt64 {
        if case let .installed(record) = games.status(for: game.appID) { return record.sizeBytes }
        return game.estimatedSize ?? 0
    }

    var body: some View {
        let shown = shown
        NavigationStack(path: $path) {
            ScrollView {
                if let error = steam.libraryError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, ShowcaseMetrics.margin)
                }
                LibraryGrid(games: shown)
                    .padding(.vertical, 8)
            }
            .overlay {
                if shown.isEmpty { LibraryGridPlaceholder(list: list) }
            }
            .refreshable { await steam.loadLibrary() }
            .navigationTitle(list.rawValue)
            .navigationSubtitle(shown.isEmpty ? "" : "\(shown.count) game\(shown.count == 1 ? "" : "s")")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu("Sort", systemImage: "arrow.up.arrow.down") {
                        Picker("Sort By", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if list == .visualNovels {
                        Button("Add to Visual Novels", systemImage: "plus", action: shell.addGame)
                    }
                    SettingsButton()
                }
            }
        }
    }
}
#endif
