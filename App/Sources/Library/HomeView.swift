#if os(iOS)
import SwiftUI

/// The Home tab (design A, "Showcase"): the game you last played full-bleed with its
/// actions, then shelves: Continue Playing, Downloading, Ready to Play, games that play in
/// Shiori but aren't downloaded, and the start of your Visual Novels.
struct HomeView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(ShellModel.self) private var shell
    @Environment(LibraryCollections.self) private var collections
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [LibraryRoute] = []
    @State private var overscroll: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        let shelves = HomeShelves(library: steam.library, games: games, curation: curation,
                                  engineScans: engineScans, history: .shared)
        let capsuleWidth = sizeClass == .regular ? ShowcaseMetrics.wideShelfCapsule : ShowcaseMetrics.shelfCapsule
        BookHandoffStack(path: $path, tab: .home) {
            ScrollView {
                VStack(alignment: .leading, spacing: ShowcaseMetrics.shelfSpacing) {
                    if let featured = shelves.featured {
                        HomeHero(game: featured, viewportHeight: viewportHeight, overscroll: overscroll)
                    }
                    if !shelves.continuePlaying.isEmpty {
                        HomeShelf(title: "Continue Playing", subtitle: "Played or saved most recently") {
                            ForEach(shelves.continuePlaying) { ContinueCard(game: $0) }
                        }
                    }
                    if !shelves.downloading.isEmpty {
                        HomeShelf(title: "Downloading", subtitle: "\(shelves.downloading.count) in the queue",
                                  destination: .downloads) {
                            ForEach(shelves.downloading) { LibraryCell(game: $0).frame(width: capsuleWidth) }
                        }
                    }
                    if !shelves.readyToPlay.isEmpty {
                        HomeShelf(title: "Ready to Play", subtitle: "Downloaded, not started yet", destination: .installed) {
                            ForEach(shelves.readyToPlay) { LibraryCell(game: $0).frame(width: capsuleWidth) }
                        }
                    }
                    if !shelves.playsInShiori.isEmpty {
                        HomeShelf(title: "Plays in Shiori",
                                  subtitle: "Checked from Steam's files · \(shelves.playsInShiori.count) not downloaded") {
                            ForEach(shelves.playsInShiori.prefix(30)) { LibraryCell(game: $0).frame(width: capsuleWidth) }
                        }
                    }
                    let series = collectionShelf
                    if !series.isEmpty {
                        HomeShelf(title: "Collections", subtitle: "\(collections.collections.count) series in your library",
                                  destination: shell.usesSidebar ? .collections : nil) {
                            ForEach(series, id: \.collection.id) { entry in
                                CollectionCell(collection: entry.collection, games: entry.games).frame(width: capsuleWidth)
                            }
                        }
                    }
                    if !shelves.visualNovels.isEmpty {
                        HomeVisualNovels(games: shelves.visualNovels)
                    }
                }
                .padding(.top, shelves.featured == nil ? 8 : 0)
                .padding(.bottom, ShowcaseMetrics.shelfSpacing)
            }
            .ignoresSafeArea(edges: shelves.featured == nil ? [] : .top)
            .scrollOverscroll($overscroll)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay {
                if shelves.isEmpty { HomePlaceholder().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background {
                if let featured = shelves.featured { GameBackdrop(game: featured) } else { Color.black.ignoresSafeArea() }
            }
            .navigationTitle(shelves.featured == nil ? "Home" : "")
            .navigationBarTitleDisplayMode(shelves.featured == nil ? .large : .inline)
            .libraryDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Add to Visual Novels", systemImage: "plus", action: shell.addGame)
                    SettingsButton()
                }
            }
            #if DEBUG
            .task(id: steam.library.count) { openRequestedGame() }
            #endif
        }
    }

    /// Collections, the one with the game played or saved most recently first, then by name.
    private var collectionShelf: [(collection: LibraryCollection, games: [LibraryGame])] {
        let byID = Dictionary(steam.library.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        let history = PlayHistory.shared
        return collections.collections
            .map { collection in
                let latest = collection.allGames.compactMap { history.lastActivity($0)?.date }.max()
                return (collection, collection.inReleaseOrder.compactMap { byID[$0] }, latest)
            }
            .filter { $0.1.count > 1 }
            .sorted { a, b in
                switch (a.2, b.2) {
                case let (x?, y?): x > y
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
                }
            }
            .prefix(20)
            .map { (collection: $0.0, games: $0.1) }
    }

    #if DEBUG
    /// `-ShioriOpenGame <appid>` opens that game's screen once the library loads.
    private func openRequestedGame() {
        let appID = UserDefaults.standard.integer(forKey: "ShioriOpenGame")
        if path.isEmpty, let game = steam.library.first(where: { $0.appID == appID }) { path = [.game(game)] }
    }
    #endif
}
#endif
