// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The iPhone Duo opened flat (iOS 27.1), as Claude's app is: a sidebar of the library's
/// sections in place of the tab bar, and the section across the rest of the screen, where
/// games open as they do anywhere else. The fold is ignored: the screen is one surface.
struct DuoPanes: View {
    @Environment(ShellModel.self) private var shell
    @SceneStorage("duoSidebar") private var showsSidebar = true

    var body: some View {
        HStack(spacing: 0) {
            if showsSidebar {
                DuoSectionsPane(hide: toggle)
                    .frame(width: 320)
                    .transition(.move(edge: .leading))
            }
            DuoSectionScreen(tab: shell.tab)
                .id(shell.tab)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) {
                    if !showsSidebar {
                        Button("Show Sidebar", systemImage: "sidebar.left", action: toggle)
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(.leading, 16)
                            .padding(.top, 6)
                            .transition(.opacity)
                    }
                }
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    private func toggle() {
        withAnimation(.smooth(duration: 0.3)) { showsSidebar.toggle() }
    }
}

/// The library's sections as a list: the tab bar's place on the opened Duo.
private struct DuoSectionsPane: View {
    let hide: () -> Void
    @Environment(ShellModel.self) private var shell
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(PatchInstaller.self) private var patchInstaller
    @Environment(LibraryCuration.self) private var curation
    @Environment(LibraryCollections.self) private var collections
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility

    var body: some View {
        @Bindable var shell = shell
        let engines = SidebarEngines(library: steam.library, games: games, curation: curation,
                                     engineScans: engineScans, compatibility: compatibility)
        NavigationStack {
            List(selection: Binding(get: { shell.tab }, set: { if let tab = $0 { shell.select(tab) } })) {
                Section {
                    row("Home", "play.rectangle.on.rectangle.fill", .home)
                    row("Visual Novels", "books.vertical.fill", .visualNovels)
                    row("Installed", "checkmark.circle.fill", .installed)
                    row("Recently Played", "clock.fill", .recentlyPlayed)
                    row("Downloads", "arrow.down.circle.fill", .downloads,
                        badge: games.downloadItems.count + patchInstaller.jobs.count)
                    row("Search", "magnifyingglass", .search)
                }
                if !collections.collections.isEmpty {
                    Section("Collections") {
                        ForEach(collections.collections) { collection in
                            row(collection.name, "square.stack", .collection(collection.id), badge: collection.allGames.count)
                        }
                    }
                }
                if !engines.items.isEmpty {
                    Section("Engines") {
                        ForEach(engines.items) { engine in
                            row(engine.title, engine.systemImage, .engine(engine.key), badge: engine.count)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Shiori")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Hide Sidebar", systemImage: "sidebar.left", action: hide)
                }
            }
        }
    }

    private func row(_ title: String, _ symbol: String, _ tab: ShellTab, badge: Int = 0) -> some View {
        Label(title, systemImage: symbol)
            .badge(badge)
            .tag(tab)
    }
}

/// The screen for one section, as its tab shows it.
private struct DuoSectionScreen: View {
    let tab: ShellTab

    var body: some View {
        switch tab {
        case .home: HomeView()
        case .visualNovels: LibraryGridScreen(section: .visualNovels)
        case .installed: LibraryGridScreen(section: .installed)
        case .recentlyPlayed: LibraryGridScreen(section: .recentlyPlayed)
        case .downloads: DownloadsScreen()
        case .search: LibrarySearchScreen()
        case let .engine(key): LibraryGridScreen(section: .engine(key))
        case .collections: CollectionsTab()
        case let .collection(id): CollectionTab(collectionID: id)
        case .settings: HomeView()
        }
    }
}

/// The fold down the middle of an opened Duo, if the window has one.
enum DuoFold {
    static func vertical(in proxy: GeometryProxy) -> CGRect? {
        #if DEBUG
        // `-ShioriFold <points>`: a simulated fold that wide down the middle (with
        // `-ShioriCanvas 951x669`), for laying out the opened Duo in a simulator.
        let simulated = UserDefaults.standard.double(forKey: "ShioriFold")
        if simulated > 0 {
            return CGRect(x: (proxy.size.width - simulated) / 2, y: 0, width: simulated, height: proxy.size.height)
        }
        #endif
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        if #available(iOS 27.1, *) {
            // Opened flat the Duo reports its fold as an inactive division, so those count.
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            let ordered = regions.filter(\.isActive) + regions.filter { !$0.isActive }
            return ordered.lazy.map(\.frame).first { frame in
                frame.height >= frame.width && frame.minX >= 320 && proxy.size.width - frame.maxX >= 320
            }
        }
        return nil
    }
}

#endif
