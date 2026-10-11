#if os(iOS)
import SteamKit
import SwiftUI

/// The download in progress, in the tab bar's accessory slot: art, name, progress, and
/// Pause or Resume. Tapping it opens Downloads.
struct MiniDownload: View {
    let game: LibraryGame
    let open: () -> Void
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

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
        case .preparing: "Preparing…"
        case .queued: "Queued"
        case let .downloading(progress): progress.phase == .finishing ? "Finishing…" : "Downloading"
        case .paused: "Paused"
        case .failed: "Download failed"
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    CapsuleArt(game: game)
                        .frame(width: 24)
                        .clipShape(.rect(cornerRadius: 4))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(game.name)
                            .font(.footnote)
                            .bold()
                            .lineLimit(1)
                        if placement != .inline {
                            if let fraction {
                                ProgressView(value: fraction).tint(.white)
                            } else {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if let fraction {
                        Text(fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(game.name), \(detail)")
            .accessibilityHint("Opens Downloads")
            MiniDownloadControl(game: game, status: status)
        }
        .padding(.horizontal, 14)
    }
}
#endif
