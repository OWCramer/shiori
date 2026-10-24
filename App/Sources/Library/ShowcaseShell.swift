// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The library on iPhone and iPad (design A, "Showcase", Phase 18): a Liquid Glass tab bar
/// (Home, Visual Novels, Installed, Downloads, Search) that minimises as you scroll, with
/// the active download riding above it like Music's mini player. On a wide iPad window the
/// same tabs are a sidebar (`sidebarAdaptable`), which adds Recently Played, an Engines
/// section with counts, and Settings; narrower windows fall back to the tab bar, where
/// those stay reachable through the sort and filter menus and the toolbar's Settings.
struct ShowcaseShell: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(PatchInstaller.self) private var patchInstaller
    @Environment(LibraryCuration.self) private var curation
    @Environment(LibraryCollections.self) private var collections
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("shellTab") private var savedTab: ShellTab = .home
    @State private var shell = ShellModel()
    /// The fold down an opened iPhone Duo, which lays the library out as panes.
    @State private var duoFold: CGRect?

    /// The download the mini player shows: the running one, else the next in the queue.
    private var accessoryGame: LibraryGame? {
        #if DEBUG
        // `-ShioriPreviewAccessory <appid>`: the mini player's layout without a download.
        let preview = UInt32(exactly: UserDefaults.standard.integer(forKey: "ShioriPreviewAccessory")) ?? 0
        if preview != 0, let game = steam.library.first(where: { $0.appID == preview }) { return game }
        #endif
        guard let appID = games.downloadItems.first else { return nil }
        return steam.library.first { $0.appID == appID }
    }

    /// Installed games' folders, whose saves Home's shelves read.
    private var installedFolders: [UInt32: (folder: URL, engine: String?)] {
        var folders: [UInt32: (folder: URL, engine: String?)] = [:]
        for (appID, record) in games.installedRecords {
            folders[appID] = (games.folder(appID: appID, name: record.name), record.engine?.engine)
        }
        return folders
    }

    @AppStorage("tabViewCustomization") private var tabCustomization = TabViewCustomization()

    /// Whether the tab view carries the iPad sidebar's own sections (Recently Played, the
    /// Engines section, Settings): only on an iPad at regular width. A phone stays a phone,
    /// whatever its width says: the unfolded iPhone Duo (951 points, regular) and a large
    /// iPhone in landscape keep the five tabs, with the rest in the sort and filter menus
    /// and the toolbar's Settings.
    private var usesSidebar: Bool {
        sizeClass == .regular && !Self.isPhone
    }

    /// A phone, iPhone Duo included (folded or open). The device, not the window: a size
    /// class can't tell an unfolded Duo from an iPad.
    private static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    var body: some View {
        let _ = RenderProbe.hit("ShowcaseShell")
        @Bindable var shell = shell
        let engines = usesSidebar
            ? SidebarEngines(library: steam.library, games: games, curation: curation,
                             engineScans: engineScans, compatibility: compatibility)
            : SidebarEngines.none
        Group {
            if let duoFold {
                DuoPanes(fold: duoFold)
            } else {
                tabs(engines: engines)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: DuoFold.vertical(in: proxy), initial: true) { _, fold in duoFold = fold }
            }
            .ignoresSafeArea()
        }
        .environment(shell)
        .focusedSceneValue(shell)
        .sheet(isPresented: $shell.showingSettings) { SettingsScreen().environment(shell) }
        .sheet(isPresented: $shell.showingAddGame) { AddVisualNovelView().environment(shell) }
        .sheet(item: $shell.collectionSheet) { sheet in
            // Sheets don't reliably carry the shell's environment; Add to Collection reads
            // the shell (its New Collection… swaps sheets), which crashed without it.
            Group {
            switch sheet {
            case let .addTo(games): AddToCollectionView(games: games)
            case let .new(games):
                CollectionGamePicker(title: "New Collection", confirmTitle: "Create", naming: "Collection Name",
                                     selected: Set(games)) { name, picked in
                    collections.create(named: name, games: picked)
                }
            case let .edit(id): CollectionEditorSheet(collectionID: id)
            }
            }
            .environment(shell)
        }
        .preferredColorScheme(.dark)
        .task(id: games.installedRecords.keys.sorted()) { refreshSaves() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSaves() }
        }
        .onAppear(perform: restoreTab)
        .onChange(of: shell.tab) { _, tab in savedTab = tab }
        .onChange(of: usesSidebar, initial: true) { _, sidebar in sidebarChanged(sidebar) }
        // A sidebar item that went away (an engine no game uses any more) goes back Home.
        .onChange(of: engines) { _, engines in
            if case let .engine(key) = shell.tab, !engines.items.contains(where: { $0.key == key }) { shell.select(.home) }
        }
        // …as does a collection hidden, deleted or merged away.
        .onChange(of: collections.collections.map(\.id)) { _, ids in
            if case let .collection(id) = shell.tab, !ids.contains(id) { shell.select(.collections) }
        }
    }

    /// The tab bar (or the iPad sidebar): everywhere but the opened Duo.
    private func tabs(engines: SidebarEngines) -> some View {
        @Bindable var shell = shell
        return TabView(selection: $shell.tab) {
            Tab("Home", systemImage: "play.rectangle.on.rectangle.fill", value: ShellTab.home) {
                HomeView()
            }
            .customizationID("home")
            Tab("Visual Novels", systemImage: "books.vertical.fill", value: ShellTab.visualNovels) {
                LibraryGridScreen(section: .visualNovels)
            }
            .customizationID("visualNovels")
            Tab("Installed", systemImage: "checkmark.circle.fill", value: ShellTab.installed) {
                LibraryGridScreen(section: .installed)
            }
            .customizationID("installed")
            if usesSidebar {
                Tab("Recently Played", systemImage: "clock.fill", value: ShellTab.recentlyPlayed) {
                    LibraryGridScreen(section: .recentlyPlayed)
                }
                .customizationID("recentlyPlayed")
                .defaultVisibility(.hidden, for: .tabBar)
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: ShellTab.downloads) {
                DownloadsScreen()
            }
            .badge(games.downloadItems.count + patchInstaller.jobs.count)
            .customizationID("downloads")
            // The sidebar's own sections: in the tab bar they'd push Search into More.
            if usesSidebar {
                TabSection("Engines") {
                    ForEach(engines.items) { engine in
                        Tab(engine.title, systemImage: engine.systemImage, value: ShellTab.engine(engine.key)) {
                            LibraryGridScreen(section: .engine(engine.key))
                        }
                        .badge(engine.count)
                        .customizationID("engine-\(engine.key)")
                    }
                }
                .customizationID("engines")
                .defaultVisibility(.hidden, for: .tabBar)
                // Collections: each one's page, and All Collections to look after them. A
                // capsule dragged onto one joins it.
                TabSection("Collections") {
                    Tab("All Collections", systemImage: "square.stack.3d.up.fill", value: ShellTab.collections) {
                        CollectionsTab()
                    }
                    .customizationID("collections")
                    ForEach(collections.collections) { collection in
                        Tab(collection.name, systemImage: "square.stack", value: ShellTab.collection(collection.id)) {
                            CollectionTab(collectionID: collection.id)
                        }
                        .badge(collection.allGames.count)
                        .customizationID("collection-\(collection.id)")
                        .dropDestination(for: String.self) { items in
                            let games = items.compactMap(GameDrag.appID)
                            if !games.isEmpty { withAnimation { collections.add(games, to: collection.id) } }
                        }
                    }
                }
                .customizationID("collectionsSection")
                .defaultVisibility(.hidden, for: .tabBar)
                Tab("Settings", systemImage: "gearshape.fill", value: ShellTab.settings) {
                    SettingsScreen(isTab: true)
                }
                .customizationID("settings")
                .defaultVisibility(.hidden, for: .tabBar)
            }
            Tab(value: ShellTab.search, role: .search) {
                LibrarySearchScreen()
            }
            .customizationID("search")
        }
        .tabViewStyle(.sidebarAdaptable)
        // `defaultVisibility(.hidden, for: .tabBar)` only takes effect with a customization:
        // without one, iPad's top tab bar showed every sidebar item and scrolled.
        .tabViewCustomization($tabCustomization)
        .tabViewSidebarHeader {
            Label("Shiori", systemImage: "bookmark.fill")
                .font(.title2)
                .bold()
                .foregroundStyle(.pink)
                .padding(.vertical, 6)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(DownloadAccessory(game: accessoryGame, open: openDownloads))
    }

    /// The sidebar's own sections have no tab in the tab bar: a window narrowing to compact
    /// width (Stage Manager, Split View) goes from them to the nearest tab.
    private func sidebarChanged(_ sidebar: Bool) {
        shell.usesSidebar = sidebar
        guard !sidebar else { return }
        switch shell.tab {
        case .recentlyPlayed: shell.select(.home)
        case .engine, .collections, .collection: shell.select(.visualNovels)
        case .settings:
            shell.select(.home)
            shell.showingSettings = true
        default: break
        }
    }

    private func openDownloads() {
        shell.select(.downloads)
    }

    private func refreshSaves() {
        PlayHistory.shared.refreshSaves(installedFolders)
    }

    /// The tab this window was on; `-ShioriTab <name>` (debug) picks one for screenshots.
    private func restoreTab() {
        shell.tab = savedTab
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "ShioriTab"), let start = ShellTab(rawValue: name) {
            // Settings is a sheet on iPhone.
            if start == .settings { shell.showSettings() } else { shell.tab = start }
        }
        // `-ShioriEditCollection <id>` opens a collection's editor.
        if let id = UserDefaults.standard.string(forKey: "ShioriEditCollection") { shell.collectionSheet = .edit(id) }
        // `-ShioriOrientation landscape|portrait` turns the window (simulators only turn from
        // Device Hub otherwise).
        if let orientation = UserDefaults.standard.string(forKey: "ShioriOrientation") {
            Task {
                try? await Task.sleep(for: .seconds(1))
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                OrientationLock.set(orientation == "landscape" ? .landscape : .portrait, in: scene)
            }
        }
        #endif
    }
}
#endif
