#if os(iOS)
import SwiftUI

/// What the shell's screens ask of it: open Settings or Add Game, or switch tab.
struct ShellActions {
    var showSettings: () -> Void = {}
    var addGame: () -> Void = {}
    var select: (ShellTab) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var shell = ShellActions()
}

/// A capsule with the game's name and state under it, opening its page.
struct LibraryCell: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        let status = games.status(for: game.appID)
        NavigationLink(value: game) {
            VStack(alignment: .leading, spacing: 6) {
                ShowcaseCapsule(game: game, status: status)
                Text(game.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(libraryStatusLine(for: game, status: status, games: games, history: .shared, engineScans: engineScans))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu { LibraryGameMenuItems(game: game) }
        .accessibilityElement(children: .combine)
    }
}

/// An adaptive grid of capsules.
struct LibraryGrid: View {
    let games: [LibraryGame]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: sizeClass == .regular ? 160 : 104), spacing: 16, alignment: .top)],
                  spacing: 22) {
            ForEach(games) { LibraryCell(game: $0) }
        }
        .padding(.horizontal, 20)
    }
}

/// How a library list is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently Played"
    case size = "Size"
    var id: Self { self }
}

/// The Visual Novels or Installed tab: a grid of the games in it.
struct LibraryGridScreen: View {
    let list: LibraryFilter
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.shell) private var shell
    @AppStorage private var sort: LibrarySort
    @State private var path: [LibraryGame] = []

    init(list: LibraryFilter) {
        self.list = list
        _sort = AppStorage(wrappedValue: .name, "librarySort.\(list == .visualNovels ? "visualNovels" : "installed")")
    }

    private var shown: [LibraryGame] {
        let history = PlayHistory.shared
        let filtered = steam.library.filter { game in
            switch list {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.status(for: game.appID) != .notInstalled
            }
        }
        switch sort {
        case .name:
            return filtered
        case .recent:
            return filtered.enumerated().sorted { a, b in
                let x = history.lastActivity(a.element.appID)?.date, y = history.lastActivity(b.element.appID)?.date
                switch (x, y) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        case .size:
            return filtered.sorted { size(of: $0) > size(of: $1) }
        }
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
                    Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal, 20)
                }
                LibraryGrid(games: shown)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .overlay { placeholder(isEmpty: shown.isEmpty) }
            .refreshable { await steam.loadLibrary() }
            .navigationTitle(list.rawValue)
            .navigationSubtitle(shown.isEmpty ? "" : "\(shown.count) game\(shown.count == 1 ? "" : "s")")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")
                }
                if list == .visualNovels {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { shell.addGame() } label: { Image(systemName: "plus") }
                            .accessibilityLabel("Add a game to Visual Novels")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
        }
    }

    @ViewBuilder private func placeholder(isEmpty: Bool) -> some View {
        if isEmpty {
            if steam.isLoadingLibrary, steam.library.isEmpty {
                ProgressView("Loading library…")
            } else if list == .installed {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Open a game and tap Download."))
            } else if !steam.library.isEmpty {
                ContentUnavailableView("No visual novels", systemImage: "books.vertical",
                                       description: Text("None of your games has Steam's Visual Novel tag. Tap + to add games."))
            } else if steam.isLoggedOn, steam.libraryError == nil {
                ContentUnavailableView("No games", systemImage: "books.vertical")
            }
        }
    }
}

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
                    .padding(.top, 8)
                    .padding(.bottom, 24)
            }
            .overlay {
                if query.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                           description: Text("Every game you own on Steam, by name or app ID, visual novels first."))
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Your Steam games")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
        }
    }
}

/// Settings, from the toolbar of the library's screens (a sidebar item on iPad later).
struct SettingsButton: View {
    @Environment(\.shell) private var shell

    var body: some View {
        Button { shell.showSettings() } label: { Image(systemName: "gearshape") }
            .accessibilityLabel("Settings")
    }
}
#endif
