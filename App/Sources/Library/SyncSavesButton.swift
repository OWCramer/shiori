#if os(iOS)
import SwiftUI

/// Sync Now for a downloaded game's saves (iCloud and Steam Cloud), spinning while it runs.
/// A circular glass button sized by the surrounding `controlSize`, for rows of actions.
struct SyncSavesButton: View {
    let appID: UInt32
    @Environment(GameLibrary.self) private var games

    private var syncing: Bool { games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing }

    var body: some View {
        Button(action: sync) {
            if syncing {
                ProgressView()
                    .tint(.white)
                    .frame(minWidth: 22, minHeight: 22)
            } else {
                GameActionLabel(title: "Sync Saves Now", systemImage: "arrow.triangle.2.circlepath.icloud", iconOnly: true)
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(syncing)
        .accessibilityLabel(syncing ? "Syncing saves" : "Sync Saves Now")
    }

    private func sync() {
        Task { await games.syncAllSaveLocations(appID: appID) }
    }
}
#endif
