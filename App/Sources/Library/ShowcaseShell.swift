#if os(iOS)
import SteamKit
import SwiftUI

enum ShellTab: String, Hashable {
    case home, visualNovels, installed, downloads, search
}

/// The library on iPhone and iPad (design A, "Showcase", Phase 18): a Liquid Glass tab bar
/// (Home, Visual Novels, Installed, Downloads, Search) that minimises as you scroll, with
/// the active download riding above it like Music's mini player.
struct ShowcaseShell: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(PatchInstaller.self) private var patchInstaller
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("shellTab") private var tab: ShellTab = .home
    @State private var showingSettings = false
    @State private var showingAddGame = false


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
    private var installedFolders: [UInt32: URL] {
        var folders: [UInt32: URL] = [:]
        for (appID, status) in games.statuses {
            if case let .installed(record) = status { folders[appID] = games.folder(appID: appID, name: record.name) }
        }
        return folders
    }

    var body: some View {
        TabView(selection: $tab) {
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
                DownloadsView(library: steam.library, isTab: true)
            }
            .badge(games.downloadItems.count + patchInstaller.jobs.count)
            Tab(value: ShellTab.search, role: .search) {
                LibrarySearchScreen()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(DownloadAccessory(game: accessoryGame) { tab = .downloads })
        .environment(\.shell, ShellActions(
            showSettings: { showingSettings = true },
            addGame: { showingAddGame = true },
            select: { tab = $0 }
        ))
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingAddGame) { AddVisualNovelView() }
        .preferredColorScheme(.dark)
        .task(id: installedFolders.keys.sorted()) { PlayHistory.shared.refreshSaves(installedFolders) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { PlayHistory.shared.refreshSaves(installedFolders) }
        }
        #if DEBUG
        // `-ShioriTab home|visualNovels|installed|downloads|search` opens on that tab.
        .onAppear {
            if let name = UserDefaults.standard.string(forKey: "ShioriTab"), let start = ShellTab(rawValue: name) { tab = start }
        }
        #endif
    }
}

/// The mini player: the download in progress in the tab bar's accessory slot (iOS 26.1's
/// `isEnabled`, so it goes away with nothing downloading). Tapping it opens Downloads.
private struct DownloadAccessory: ViewModifier {
    let game: LibraryGame?
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: game != nil) {
                if let game { MiniDownload(game: game, open: open) }
            }
        } else {
            content
        }
    }
}

private struct MiniDownload: View {
    let game: LibraryGame
    let open: () -> Void
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var status: GameLibrary.Status { games.status(for: game.appID) }

    private var fraction: Double? {
        switch status {
        case let .downloading(progress): progress.fraction
        case let .paused(progress?): progress.fraction
        default: nil
        }
    }

    private var detail: String {
        switch status {
        case .preparing: "Preparing…"
        case .queued: "Queued"
        case let .downloading(progress): progress.phase == .finishing ? "Finishing…" : "Downloading"
        case .paused: "Paused"
        case .failed: "Download failed"
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    CapsuleArt(game: game)
                        .frame(width: 24)
                        .clipShape(.rect(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.name).font(.footnote.weight(.semibold)).lineLimit(1)
                        if placement != .inline {
                            if let fraction {
                                ProgressView(value: fraction).tint(.white)
                            } else {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(game.name), \(detail)")
            .accessibilityHint("Opens Downloads")
            control
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var control: some View {
        switch status {
        case .downloading, .preparing, .queued:
            Button { games.pause(appID: game.appID) } label: { Image(systemName: "pause.fill") }
                .accessibilityLabel("Pause")
        case .paused, .failed:
            Button { games.resume(appID: game.appID, name: game.name) } label: { Image(systemName: "arrow.down") }
                .disabled(!steam.isLoggedOn)
                .accessibilityLabel("Resume")
        default:
            EmptyView()
        }
    }
}
#endif
