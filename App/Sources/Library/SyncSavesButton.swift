#if os(iOS)
import SwiftUI

/// Sync Now for a downloaded game's saves (iCloud and Steam Cloud), spinning while a sync
/// it started runs. The background syncs Shiori runs on its own (at launch, on returning to
/// the foreground) don't spin it, or the button flickered every time the app opened.
/// A circular glass button sized by the surrounding `controlSize`, for rows of actions.
struct SyncSavesButton: View {
    let appID: UInt32
    @Environment(GameLibrary.self) private var games

    @State private var requested = false

    private var syncing: Bool { games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing }
    private var spinning: Bool { requested && syncing }

    var body: some View {
        Button(action: sync) {
            if spinning {
                ProgressView()
                    .tint(.white)
                    .frame(minWidth: 22, minHeight: 22)
            } else {
                GameActionLabel(title: "Sync Saves Now", systemImage: "arrow.triangle.2.circlepath.icloud", iconOnly: true)
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .disabled(spinning)
        .accessibilityLabel(spinning ? "Syncing saves" : "Sync Saves Now")
        .onChange(of: syncing) { _, now in if !now { requested = false } }
    }

    private func sync() {
        requested = true
        Task {
            await games.syncAllSaveLocations(appID: appID)
            requested = false
        }
    }
}
#endif
