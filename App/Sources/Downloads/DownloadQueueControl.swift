#if os(iOS)
import SwiftUI

/// A queued download's Pause (which takes it out of the queue) or a stopped one's Resume.
struct DownloadQueueControl: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    var body: some View {
        switch status {
        case .downloading, .preparing, .queued:
            Button(status == .queued ? "Remove from Queue" : "Pause", systemImage: "pause.circle.fill", action: pause)
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(minWidth: ShowcaseMetrics.minimumTap, minHeight: ShowcaseMetrics.minimumTap)
        case .paused, .failed:
            Button("Resume", systemImage: "arrow.down.circle.fill", action: resume)
                .labelStyle(.iconOnly)
                .font(.title2)
                .frame(minWidth: ShowcaseMetrics.minimumTap, minHeight: ShowcaseMetrics.minimumTap)
                .disabled(!steam.isLoggedOn)
        default:
            EmptyView()
        }
    }

    private func pause() { games.pause(appID: game.appID) }
    private func resume() { games.resume(appID: game.appID, name: game.name) }
}
#endif
