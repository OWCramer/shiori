#if os(iOS)
import SwiftUI

/// The top of the page's content, only when there's something to say: download progress,
/// why the game won't play, what its engine is before download, and another Steam version
/// that plays.
struct GamePageNotices: View {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility

    private var appID: UInt32 { game.appID }

    var body: some View {
        let stage = games.stage(for: appID)
        DownloadStatusPanel(appID: appID)
        if stage == .installed, let blocker = games.playBlocker(appID: appID) {
            GamePageCallout(title: "Not playable yet", systemImage: "info.circle", tint: .orange, message: blocker)
        }
        if stage == .notInstalled {
            if let scan = engineScans.result(for: appID) {
                if let error = scan.error {
                    GamePageCallout(title: "Couldn't check the engine", systemImage: "questionmark.circle", message: error)
                } else {
                    let playability = Playability(scan.engine, appID: appID)
                    if playability == .playable {
                        GamePageCallout(title: "Plays in Shiori", systemImage: "checkmark.circle.fill", tint: .green,
                                        message: "\(engineLine(scan)), read from Steam's files.")
                    } else {
                        GamePageCallout(title: "Doesn't play in Shiori yet", systemImage: "exclamationmark.triangle", tint: .orange,
                                        message: "\(engineLine(scan)). \(GameText.playability(playability, engine: scan.engine, appID: appID))")
                    }
                }
            } else if engineScans.scanning == appID {
                GamePageCallout(title: "Checking the engine…", systemImage: "magnifyingglass")
            }
        }
        if let hint = BranchHint.find(for: game, games: games, engineScans: engineScans, compatibility: compatibility) {
            GamePageCallout(title: hint.scanned ? "Another version of this game plays in Shiori" : "Another version may work",
                            systemImage: "arrow.triangle.branch", tint: .orange,
                            message: "\(hint.detail) Saves and patches stay if you switch.") {
                Button("Use This Version") { model.chooseBranch(hint.branch, game: game, games: games) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }

    /// "Ren'Py 7.4.11 · 803.7 MB", what the manifests say before download.
    private func engineLine(_ scan: EngineScanResult) -> String {
        var engine = GameText.engine(scan.engine)
        if OnlineGames.contains(appID) { engine = scan.engine == nil ? OnlineGames.badge : "\(OnlineGames.badge) · \(engine)" }
        return scan.installSize > 0 ? "\(engine) · \(scan.installSize.formatted(.byteCount(style: .file)))" : engine
    }
}
#endif
