#if os(iOS)
import SwiftUI

/// The library on iPhone and iPad (design A, "Showcase", Phase 18): a Liquid Glass tab bar
/// (Home, Visual Novels, Installed, Downloads, Search) that minimises as you scroll, with
/// the active download riding above it like Music's mini player.
struct ShowcaseShell: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(PatchInstaller.self) private var patchInstaller
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("shellTab") private var savedTab: ShellTab = .home
    @State private var shell = ShellModel()

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
        for (appID, status) in games.statuses {
            if case let .installed(record) = status {
                folders[appID] = (games.folder(appID: appID, name: record.name), record.engine?.engine)
            }
        }
        return folders
    }

    var body: some View {
        @Bindable var shell = shell
        TabView(selection: $shell.tab) {
            Tab("Home", systemImage: "play.rectangle.on.rectangle.fill", value: ShellTab.home) {
                HomeView()
            }
            Tab("Visual Novels", systemImage: "books.vertical.fill", value: ShellTab.visualNovels) {
                LibraryGridScreen(list: .visualNovels)
            }
            Tab("Installed", systemImage: "checkmark.circle.fill", value: ShellTab.installed) {
                LibraryGridScreen(list: .installed)
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: ShellTab.downloads) {
                DownloadsScreen()
            }
            .badge(games.downloadItems.count + patchInstaller.jobs.count)
            Tab(value: ShellTab.search, role: .search) {
                LibrarySearchScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(DownloadAccessory(game: accessoryGame, open: openDownloads))
        .environment(shell)
        .sheet(isPresented: $shell.showingSettings) { SettingsScreen() }
        .sheet(isPresented: $shell.showingAddGame) { AddVisualNovelView() }
        .preferredColorScheme(.dark)
        .task(id: installedFolders.keys.sorted()) { refreshSaves() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshSaves() }
        }
        .onAppear(perform: restoreTab)
        .onChange(of: shell.tab) { _, tab in savedTab = tab }
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
        if let name = UserDefaults.standard.string(forKey: "ShioriTab"), let start = ShellTab(rawValue: name) { shell.tab = start }
        #endif
    }
}
#endif
