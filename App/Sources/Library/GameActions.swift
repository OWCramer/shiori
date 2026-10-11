#if os(iOS)
import SteamKit
import SwiftUI
import UIKit

/// The one prominent action a game's state calls for: Play, Download, Pause, Resume.
/// Shared by Home's hero, the game page and the library's menus.
struct PrimaryGameButton: View {
    let game: LibraryGame
    /// Icon-only labels where a full one doesn't fit (the Duo's cover screen).
    var compact = false
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    var body: some View {
        let appID = game.appID
        switch games.status(for: appID) {
        case .notInstalled:
            action("Download", "arrow.down.circle.fill", .blue) { games.download(game) }
                .disabled(!steam.isLoggedOn)
        case .queued:
            action("Queued", "clock", .gray) { games.pause(appID: appID) }
        case .preparing, .downloading:
            action("Pause", "pause.fill", .orange) { games.pause(appID: appID) }
        case .paused, .failed:
            action("Resume", "arrow.down.circle.fill", .blue) { games.resume(appID: appID, name: game.name) }
                .disabled(!steam.isLoggedOn)
        case .verifying:
            action("Verifying…", "checkmark.shield", .gray) {}
                .disabled(true)
        case .installed:
            if let phase = games.launchPhase(for: appID) {
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        if !compact { Text(phase.label).lineLimit(1) }
                    }
                    .font(.headline)
                    .padding(.horizontal, compact ? 8 : 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(true)
                .accessibilityLabel(phase.label)
            } else if games.playBlocker(appID: appID) == nil {
                action("Play", "play.fill", .green) { games.play(appID: appID) }
            } else {
                action("Not Playable", "exclamationmark.triangle", .gray) {}
                    .disabled(true)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Group {
                if compact {
                    Image(systemName: symbol)
                } else {
                    Label(title, systemImage: symbol).fixedSize()
                }
            }
            .font(.headline)
            .padding(.horizontal, compact ? 8 : 22)
            .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(tint)
        .accessibilityLabel(title)
    }
}

/// Sync Now for a downloaded game's saves (iCloud and Steam Cloud), spinning while it runs.
struct SyncSavesButton: View {
    let appID: UInt32
    @Environment(GameLibrary.self) private var games

    private var syncing: Bool { games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing }

    var body: some View {
        Button {
            Task { await games.syncAllSaveLocations(appID: appID) }
        } label: {
            Group {
                if syncing {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                }
            }
            .font(.headline)
            .frame(width: 22, height: 22)
            .padding(6)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(syncing)
        .accessibilityLabel(syncing ? "Syncing saves" : "Sync Saves Now")
    }
}

/// The menu items a game offers wherever it's shown in the library (context menus, Home's
/// "More" button): play or download, the folder, and the Visual Novels list.
struct LibraryGameMenuItems: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation

    var body: some View {
        let appID = game.appID
        switch games.status(for: appID) {
        case .installed:
            if games.playBlocker(appID: appID) == nil {
                Button("Play", systemImage: "play.fill") { games.play(appID: appID) }
                    .disabled(games.launchPhase(for: appID) != nil)
            }
            Button("Sync Saves Now", systemImage: "arrow.triangle.2.circlepath.icloud") {
                Task { await games.syncAllSaveLocations(appID: appID) }
            }
            Button("Open Folder in Files", systemImage: "folder") {
                openInFiles(games.folder(appID: appID, name: game.name))
            }
        case .notInstalled:
            Button("Download", systemImage: "arrow.down.circle") { games.download(game) }
                .disabled(!steam.isLoggedOn)
        case .preparing, .downloading, .queued:
            Button("Pause Download", systemImage: "pause") { games.pause(appID: appID) }
        case .paused, .failed:
            Button("Resume Download", systemImage: "arrow.down.circle") { games.resume(appID: appID, name: game.name) }
                .disabled(!steam.isLoggedOn)
        case .verifying:
            EmptyView()
        }
        Divider()
        Button(curation.isVisualNovel(game) ? "Remove from Visual Novels" : "Add to Visual Novels",
               systemImage: curation.isVisualNovel(game) ? "eye.slash" : "plus.circle") {
            withAnimation { curation.toggle(game) }
        }
    }
}

/// Opens a folder in our Documents in the Files app (the shareddocuments scheme).
@MainActor func openInFiles(_ folder: URL) {
    var components = URLComponents()
    components.scheme = "shareddocuments"
    components.path = folder.path
    if let url = components.url { UIApplication.shared.open(url) }
}

/// One line on a game's state for under its art: "Played yesterday", "Downloading · 42%".
@MainActor func libraryStatusLine(for game: LibraryGame, status: GameLibrary.Status, games: GameLibrary,
                                  history: PlayHistory, engineScans: EngineScanStore) -> String {
    switch status {
    case let .installed(record):
        if let activity = history.lastActivity(game.appID) { return activity.description }
        if games.playBlocker(appID: game.appID) != nil { return "Not playable yet" }
        return Playability.badge(record.engine, appID: game.appID)
    case let .downloading(progress):
        if progress.phase == .finishing { return "Finishing…" }
        return "Downloading · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
    case .preparing: return "Preparing…"
    case .queued: return "Queued"
    case let .paused(progress):
        return progress.map { "Paused · \($0.fraction.formatted(.percent.precision(.fractionLength(0))))" } ?? "Paused"
    case .failed: return "Download failed"
    case .verifying: return "Verifying…"
    case .notInstalled:
        let size = engineScans.result(for: game.appID).flatMap { $0.installSize > 0 ? $0.installSize : nil } ?? game.estimatedSize
        return size.map { $0.formatted(.byteCount(style: .file)) } ?? "Not downloaded"
    }
}
#endif
