// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The mini player's Pause or Resume.
struct MiniDownloadControl: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    var body: some View {
        switch status {
        case .downloading, .preparing, .queued:
            Button("Pause", systemImage: "pause.fill", action: pause)
                .labelStyle(.iconOnly)
                .frame(minWidth: ShowcaseMetrics.minimumTap, minHeight: ShowcaseMetrics.minimumTap)
        case .paused, .failed:
            Button("Resume", systemImage: "arrow.down", action: resume)
                .labelStyle(.iconOnly)
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
