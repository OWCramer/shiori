// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
    @Environment(LibraryCollections.self) private var collections
    @AppStorage private var sort: LibrarySort
    /// Collections as stacked tiles, or every game on its own.
    @AppStorage private var grouped: Bool
    @State private var filters: LibraryFilters
    @State private var path: [LibraryRoute] = []

    init(section: LibrarySection) {
        self.section = section
        _sort = AppStorage(wrappedValue: section == .recentlyPlayed ? .recent : .name, "librarySort.\(section.storageKey)")
        _grouped = AppStorage(wrappedValue: true, "libraryGrouped.\(section.storageKey)")
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
            LibraryEntry(game: game, traits: traits(game), isDownloaded: games.isOnDevice(game.appID))
        }
    }

    private func size(of game: LibraryGame) -> UInt64 {
        if let record = games.record(for: game.appID) { return record.sizeBytes }
        return game.estimatedSize ?? 0
    }

    /// What a collection opened from here shows: Installed's downloaded games, or a filtered
    /// grid's games; everything otherwise.
    private func collectionScope(shown: [LibraryGame]) -> CollectionScope? {
        if filters.isActive { return .games(Set(shown.map(\.appID))) }
        return section == .installed ? .downloaded : nil
    }

    /// The Visual Novels and Installed tabs can stack collections.
    private var offersGrouping: Bool { section == .visualNovels || section == .installed }

    var body: some View {
        let _ = RenderProbe.hit("LibraryGridScreen")
        let entries = entries
        let shown = entries.filter { filters.admits($0.traits, isDownloaded: $0.isDownloaded) }.map(\.game)
        let items = offersGrouping && grouped ? LibraryGridItem.grouping(shown, collections: collections) : shown.map(LibraryGridItem.game)
        LibraryStack(path: $path) {
            ScrollView {
                if let error = steam.libraryError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, ShowcaseMetrics.margin)
                }
                LibraryGrid(items: items)
                    .padding(.vertical, 8)
                    .environment(\.collectionScope, collectionScope(shown: shown))
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
            .libraryDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    LibraryFilterMenu(filters: $filters, entries: entries, showsDownload: section != .installed)
                    if section != .recentlyPlayed {
                        Menu("Sort", systemImage: "arrow.up.arrow.down") {
                            Picker("Sort By", selection: $sort) {
                                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                            }
                            if offersGrouping {
                                Section {
                                    Toggle("Group Collections", systemImage: "square.stack", isOn: $grouped)
                                }
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
            #if DEBUG
            // `-ShioriOpenCollection <id>` (with -ShioriTab visualNovels) opens a collection's page.
            .task(id: collections.collections.count) {
                if section == .visualNovels, path.isEmpty, let id = UserDefaults.standard.string(forKey: "ShioriOpenCollection"),
                   collections.collection(id: id) != nil {
                    // `-ShioriCollectionScope downloaded` opens it as from Installed.
                    let downloaded = UserDefaults.standard.string(forKey: "ShioriCollectionScope") == "downloaded"
                    path = [.collection(id, scope: downloaded ? .downloaded : nil)]
                }
            }
            #endif
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
