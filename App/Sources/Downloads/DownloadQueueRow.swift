#if os(iOS)
import SteamKit
import SwiftUI

/// A download waiting, paused or stopped: its art, name, state and progress, and Pause or
/// Resume. The row opens the game's page.
struct DownloadQueueRow: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    private var status: GameLibrary.Status { games.status(for: game.appID) }

    private var fraction: Double? {
        switch status {
        case let .downloading(progress): progress.fraction
        case let .paused(progress?): progress.fraction
        default: nil
        }
    }

    private var detail: String {
        switch status {
        case .queued: "Queued"
        case .preparing: "Preparing…"
        case let .downloading(progress):
            "Downloading · \(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
        case let .paused(progress?):
            "Paused · \(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
        case .paused: "Paused"
        case let .failed(message, _): message
        default: ""
        }
    }

    private var isFailed: Bool { if case .failed = status { true } else { false } }

    var body: some View {
        let _ = RenderProbe.hit("DownloadQueueRow")
        GamePageRow {
            HStack(spacing: 12) {
                GameLink(game: game) {
                    HStack(spacing: 12) {
                        CapsuleArt(game: game)
                            .frame(width: 44)
                            .clipShape(.rect(cornerRadius: 6))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(game.name).font(.headline).lineLimit(1)
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                                .lineLimit(2)
                            if let fraction { GlassProgressBar(fraction: fraction, tint: .orange) }
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                Spacer(minLength: 0)
                DownloadQueueControl(game: game, status: status)
            }
        }
    }
}
#endif
