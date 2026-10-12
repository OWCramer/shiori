#if os(iOS)
import SwiftUI

/// The Visual Novels or Installed tab: a grid of the games in it, sorted and filtered.
struct LibraryGridScreen: View {
    let list: LibraryFilter
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility
    @Environment(ShellModel.self) private var shell
    @AppStorage private var sort: LibrarySort
    @State private var filters: LibraryFilters
    @State private var path: [LibraryGame] = []

    init(list: LibraryFilter) {
        self.list = list
        _sort = AppStorage(wrappedValue: .name, "librarySort.\(list == .visualNovels ? "visualNovels" : "installed")")
        _filters = State(initialValue: LibraryFilters.load(list))
    }

    /// The tab's games, before filtering, in the chosen order.
    private var entries: [LibraryEntry] {
        let inTab = steam.library.filter { game in
            switch list {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.status(for: game.appID) != .notInstalled
            }
        }
        let history = PlayHistory.shared
        return sort.sorted(inTab, lastActivity: { history.lastActivity($0)?.date }, size: size(of:)).map { game in
            LibraryEntry(game: game,
                         traits: GameTraits(game, games: games, engineScans: engineScans, compatibility: compatibility),
                         isDownloaded: games.status(for: game.appID) != .notInstalled)
        }
    }

    private func size(of game: LibraryGame) -> UInt64 {
        if case let .installed(record) = games.status(for: game.appID) { return record.sizeBytes }
        return game.estimatedSize ?? 0
    }

    var body: some View {
        let entries = entries
        let shown = entries.filter { filters.admits($0.traits, isDownloaded: $0.isDownloaded) }.map(\.game)
        NavigationStack(path: $path) {
            ScrollView {
                if let error = steam.libraryError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, ShowcaseMetrics.margin)
                }
                if filters.isActive, !shown.isEmpty {
                    LibraryFilterSummary(filters: $filters, shown: shown.count, total: entries.count)
                }
                LibraryGrid(games: shown)
                    .padding(.vertical, 8)
            }
            .overlay {
                if shown.isEmpty {
                    if filters.isActive, !entries.isEmpty {
                        LibraryFilteredEmpty(filters: $filters, total: entries.count)
                    } else {
                        LibraryGridPlaceholder(list: list)
                    }
                }
            }
            .refreshable { await steam.loadLibrary() }
            .navigationTitle(list.rawValue)
            .navigationSubtitle(subtitle(shown: shown.count, total: entries.count))
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibraryFilterMenu(filters: $filters, entries: entries, showsDownload: list == .visualNovels)
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
            .onChange(of: filters) { _, filters in filters.save(list) }
        }
    }

    /// "80 games", or "12 of 80 games" while filtered.
    private func subtitle(shown: Int, total: Int) -> String {
        guard total > 0 else { return "" }
        let games = "\(total) game\(total == 1 ? "" : "s")"
        return filters.isActive ? "\(shown) of \(games)" : games
    }
}
#endif
