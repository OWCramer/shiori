import SteamKit
import SwiftUI

/// While a game downloads, waits in the queue, is paused, failed or is being verified:
/// how far it has got, on a plain surface under the actions.
/// It reads the game's status itself, so progress re-evaluates only this panel.
struct DownloadStatusPanel: View {
    let appID: UInt32
    @Environment(GameLibrary.self) private var games

    var body: some View {
        switch games.status(for: appID) {
        case .preparing:
            panel(title: "Preparing download…", fraction: nil, detail: nil, tint: .blue)
        case let .downloading(progress):
            panel(title: progress.phase == .finishing ? "Finishing…" : "Downloading", fraction: progress.fraction,
                  detail: bytes(progress), tint: .blue)
        case let .paused(progress?):
            panel(title: "Paused", fraction: progress.fraction, detail: bytes(progress), tint: .orange)
        case .queued:
            GamePageCallout(title: "Queued", systemImage: "clock")
        case let .failed(message, _):
            GamePageCallout(title: "Download stopped", systemImage: "exclamationmark.triangle.fill", tint: .red, message: message)
        case let .verifying(progress):
            panel(title: "Verifying files", fraction: progress.fraction, detail: nil, tint: .teal)
        default:
            EmptyView()
        }
    }

    private func bytes(_ progress: DownloadProgress) -> String {
        "\(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))"
    }

    private func panel(title: String, fraction: Double?, detail: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.headline.monospacedDigit())
                }
            }
            if let fraction {
                GlassProgressBar(fraction: fraction, tint: tint)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
            if let detail {
                Text(detail)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.fill.quaternary, in: .rect(cornerRadius: GamePageMetrics.sectionRadius))
        .accessibilityElement(children: .combine)
    }
}
