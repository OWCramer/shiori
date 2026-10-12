#if os(iOS)
import SwiftUI

/// Under the hero: the state's main action across the width, Sync Now once downloaded,
/// and More, on Liquid Glass (controls floating over the art, as on Home), all one size.
struct GamePageActionRow: View {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    private var isInstalled: Bool {
        if case .installed = games.status(for: game.appID) { true } else { false }
    }

    /// Whether the main action needs Steam (download, resume) while it can't be reached.
    private var showsOfflineNote: Bool {
        switch games.status(for: game.appID) {
        case .notInstalled, .paused, .failed: steam.offlineReason != nil
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    PrimaryGameButton(game: game, fillsWidth: true)
                    if isInstalled { SyncSavesButton(appID: game.appID) }
                    GamePageMoreMenu(game: game, model: model)
                }
            }
            .controlSize(.large)
            if showsOfflineNote, let reason = steam.offlineReason {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
#endif
