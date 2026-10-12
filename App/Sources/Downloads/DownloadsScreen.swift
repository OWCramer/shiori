#if os(iOS)
import SwiftUI

/// The Downloads tab (design A): the download under way large over its art, then the rest
/// of the queue and patches being installed, with Pause All or Resume All.
struct DownloadsScreen: View {
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(PatchInstaller.self) private var patches
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [LibraryGame] = []

    private func game(_ appID: UInt32) -> LibraryGame? { steam.library.first { $0.appID == appID } }

    /// The download running now (or preparing), shown large.
    private var active: LibraryGame? {
        #if DEBUG
        // `-ShioriPreviewDownloadCard <appid>`: the large card's layout without a download.
        let preview = UInt32(exactly: UserDefaults.standard.integer(forKey: "ShioriPreviewDownloadCard")) ?? 0
        if preview != 0, let game = game(preview) { return game }
        #endif
        guard let appID = games.downloadItems.first else { return nil }
        switch games.status(for: appID) {
        case .downloading, .preparing: return game(appID)
        default: return nil
        }
    }

    private var canPauseAll: Bool {
        games.downloadItems.contains { appID in
            switch games.status(for: appID) {
            case .downloading, .preparing, .queued: true
            default: false
            }
        }
    }

    private var canResumeAll: Bool {
        games.downloadItems.contains { appID in
            switch games.status(for: appID) {
            case .paused, .failed: true
            default: false
            }
        }
    }

    var body: some View {
        let active = active
        let upNext = games.downloadItems.filter { $0 != active?.appID }.compactMap(game)
        let patchJobs = patches.jobs.keys.sorted().compactMap { appID in patches.jobs[appID].flatMap { job in game(appID).map { (game: $0, job: job) } } }
        BookHandoffStack(path: $path, tab: .downloads) {
            ScrollView {
                VStack(alignment: .leading, spacing: GamePageMetrics.sectionSpacing) {
                    if let active { ActiveDownloadCard(game: active) }
                    if !upNext.isEmpty {
                        GamePageSection(title: active == nil ? "Queue" : "Up Next") {
                            ForEach(upNext) { DownloadQueueRow(game: $0) }
                        }
                    }
                    if !patchJobs.isEmpty {
                        GamePageSection(title: "Patches") {
                            ForEach(patchJobs, id: \.game.appID) { PatchJobRow(game: $0.game, job: $0.job) }
                        }
                    }
                    if !games.downloadItems.isEmpty {
                        Label("Downloads keep going in the background while iOS allows it; if iOS stops one, it picks up where it left off when you come back to Shiori.",
                              systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: GamePageMetrics.readableWidth)
                .padding(.horizontal, ShowcaseMetrics.margin)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if games.downloadItems.isEmpty && patches.jobs.isEmpty {
                    ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                           description: Text("Games and patches you download appear here while they're on their way."))
                }
            }
            .navigationTitle("Downloads")
            .navigationSubtitle(subtitle)
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if canPauseAll {
                        Button("Pause All", systemImage: "pause.circle", action: pauseAll)
                    } else if canResumeAll {
                        Button("Resume All", systemImage: "arrow.down.circle", action: resumeAll)
                            .disabled(!steam.isLoggedOn)
                    }
                    SettingsButton()
                }
            }
        }
    }

    /// "3 in the queue", and patches.
    private var subtitle: String {
        var parts: [String] = []
        let count = games.downloadItems.count
        if count > 0 { parts.append("\(count) in the queue") }
        let patchCount = patches.jobs.count
        if patchCount > 0 { parts.append("\(patchCount) patch\(patchCount == 1 ? "" : "es")") }
        return parts.joined(separator: " · ")
    }

    private func pauseAll() {
        // The queued ones first, so pausing the running one doesn't start the next.
        for appID in games.downloadItems.reversed() {
            switch games.status(for: appID) {
            case .downloading, .preparing, .queued: games.pause(appID: appID)
            default: break
            }
        }
    }

    private func resumeAll() {
        for appID in games.downloadItems {
            switch games.status(for: appID) {
            case .paused, .failed:
                if let game = game(appID) { games.resume(appID: appID, name: game.name) }
            default: break
            }
        }
    }
}
#endif
