#if os(iOS)
import SwiftUI

/// The one prominent action a game's state calls for: Play, Download, Pause, Resume.
/// Sized by the surrounding `controlSize`; `compact` shows the icon alone (VoiceOver still
/// reads the title).
struct PrimaryGameButton: View {
    let game: LibraryGame
    var compact = false
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    var body: some View {
        let appID = game.appID
        switch games.status(for: appID) {
        case .notInstalled:
            action("Download", "arrow.down.circle.fill", .blue, perform: download)
                .disabled(!steam.isLoggedOn)
        case .queued:
            action("Queued", "clock", .gray, perform: pause)
        case .preparing, .downloading:
            action("Pause", "pause.fill", .orange, perform: pause)
        case .paused, .failed:
            action("Resume", "arrow.down.circle.fill", .blue, perform: resume)
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
                }
                .accessibilityLabel(phase.label)
                .buttonStyle(.glassProminent)
                .tint(.green)
                .disabled(true)
            } else if games.playBlocker(appID: appID) == nil {
                action("Play", "play.fill", .green, perform: play)
            } else {
                action("Not Playable", "exclamationmark.triangle", .gray) {}
                    .disabled(true)
            }
        }
    }

    private func action(_ title: String, _ symbol: String, _ tint: Color, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            GameActionLabel(title: title, systemImage: symbol, iconOnly: compact)
                .padding(.horizontal, compact ? 0 : 8)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(compact ? .circle : .capsule)
        .tint(tint)
    }

    private func download() { games.download(game) }
    private func pause() { games.pause(appID: game.appID) }
    private func resume() { games.resume(appID: game.appID, name: game.name) }
    private func play() { games.play(appID: game.appID) }
}
#endif
