#if os(iOS)
import SwiftUI

/// The menu items a game offers wherever it's shown in the library (context menus, Home's
/// More button): play or download, the saves and folder, and the Visual Novels list.
struct LibraryGameMenuItems: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation

    private var isVisualNovel: Bool { curation.isVisualNovel(game) }

    var body: some View {
        let appID = game.appID
        switch games.status(for: appID) {
        case .installed:
            if games.playBlocker(appID: appID) == nil {
                Button("Play", systemImage: "play.fill", action: play)
                    .disabled(games.launchPhase(for: appID) != nil)
            }
            Button("Sync Saves Now", systemImage: "arrow.triangle.2.circlepath.icloud", action: syncSaves)
            Button("Open Folder in Files", systemImage: "folder", action: openFolder)
        case .notInstalled:
            Button("Download", systemImage: "arrow.down.circle", action: download)
                .disabled(!steam.isLoggedOn)
        case .preparing, .downloading, .queued:
            Button("Pause Download", systemImage: "pause", action: pause)
        case .paused, .failed:
            Button("Resume Download", systemImage: "arrow.down.circle", action: resume)
                .disabled(!steam.isLoggedOn)
        case .verifying:
            EmptyView()
        }
        Divider()
        Button(isVisualNovel ? "Remove from Visual Novels" : "Add to Visual Novels",
               systemImage: isVisualNovel ? "eye.slash" : "plus.circle", action: toggleVisualNovel)
    }

    private func play() { games.play(appID: game.appID) }
    private func syncSaves() { Task { await games.syncAllSaveLocations(appID: game.appID) } }
    private func openFolder() { openInFiles(games.folder(appID: game.appID, name: game.name)) }
    private func download() { games.download(game) }
    private func pause() { games.pause(appID: game.appID) }
    private func resume() { games.resume(appID: game.appID, name: game.name) }
    private func toggleVisualNovel() { withAnimation { curation.toggle(game) } }
}
#endif
