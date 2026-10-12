#if os(iOS)
import SwiftUI

/// A grid of games, sorted and filtered: the Visual Novels and Installed tabs, and on iPad's
/// sidebar Recently Played and each engine.
struct LibraryGridScreen: View {
    let section: LibrarySection
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility
    @Environment(ShellModel.self) private var shell
    @AppStorage private var sort: LibrarySort
    @State private var filters: LibraryFilters
    @State private var path: [LibraryGame] = []

    init(section: LibrarySection) {
        self.section = section
        _sort = AppStorage(wrappedValue: section == .recentlyPlayed ? .recent : .name, "librarySort.\(section.storageKey)")
        _filters = State(initialValue: LibraryFilters.load(section))
    }

    /// The section's games, before filtering, in the chosen order.
    private var entries: [LibraryEntry] {
        let history = PlayHistory.shared
        var traitsCache: [UInt32: GameTraits] = [:]
        func traits(_ game: LibraryGame) -> GameTraits {
            if let known = traitsCache[game.appID] { return known }
            let found = GameTraits(game, games: games, engineScans: engineScans, compatibility: compatibility)
            traitsCache[game.appID] = found
            return found
        }
        let inSection = steam.library.filter { game in
            section.contains(game, traits: traits(game), games: games, curation: curation, history: history)
        }
        // Recently Played is always newest first.
        let order = section == .recentlyPlayed ? .recent : sort
        return order.sorted(inSection, lastActivity: { history.lastActivity($0)?.date }, size: size(of:)).map { game in
            LibraryEntry(game: game, traits: traits(game), isDownloaded: games.status(for: game.appID) != .notInstalled)
        }
    }

    private func size(of game: LibraryGame) -> UInt64 {
        if case let .installed(record) = games.status(for: game.appID) { return record.sizeBytes }
        return game.estimatedSize ?? 0
    }

    var body: some View {
        let entries = entries
        let shown = entries.filter { filters.admits($0.traits, isDownloaded: $0.isDownloaded) }.map(\.game)
        BookHandoffStack(path: $path, tab: section.shellTab) {
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
                if shown.isEmpty {
                    if filters.isActive, !entries.isEmpty {
                        LibraryFilteredEmpty(filters: $filters, total: entries.count)
                    } else {
                        LibraryGridPlaceholder(section: section)
                    }
                }
            }
            .refreshable { await steam.loadLibrary() }
            .navigationTitle(section.title)
            .navigationSubtitle(subtitle(shown: shown.count, total: entries.count))
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibraryFilterMenu(filters: $filters, entries: entries, showsDownload: section != .installed)
                    if section != .recentlyPlayed {
                        Menu("Sort", systemImage: "arrow.up.arrow.down") {
                            Picker("Sort By", selection: $sort) {
                                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                            }
                        }
                    }
                    if section == .visualNovels {
                        Button("Add to Visual Novels", systemImage: "plus", action: shell.addGame)
                    }
                    SettingsButton()
                }
            }
            .onChange(of: filters) { _, filters in filters.save(section) }
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
