import SteamKit
import SwiftUI

/// The download queue: the active download, then queued, paused and failed ones.
struct DownloadsView: View {
    let library: [LibraryGame]
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(\.dismiss) private var dismiss

    private func game(_ appID: UInt32) -> LibraryGame? { library.first { $0.appID == appID } }

    var body: some View {
        NavigationStack {
            List {
                ForEach(games.downloadItems, id: \.self) { appID in
                    if let game = game(appID) {
                        DownloadRow(game: game, status: games.status(for: appID))
                    }
                }
            }
            .overlay {
                if games.downloadItems.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Games you download appear here while they're in progress."))
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if games.isDownloading {
                    Text("Downloads keep going in the background while iOS allows it; if iOS stops one, it resumes when you come back to VN Hub.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }
}

private struct DownloadRow: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam

    var body: some View {
        HStack(spacing: 12) {
            CapsuleArt(game: game)
                .frame(width: 44)
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name).font(.headline).lineLimit(1)
                detail
            }
            Spacer()
            control
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var detail: some View {
        switch status {
        case let .downloading(progress):
            ProgressView(value: progress.fraction)
            Text("\(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .preparing:
            Text("Preparing…").font(.caption).foregroundStyle(.secondary)
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case let .paused(progress):
            Text(progress.map { "Paused at \($0.fraction.formatted(.percent.precision(.fractionLength(0))))" } ?? "Paused")
                .font(.caption).foregroundStyle(.secondary)
        case let .failed(message, _):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var control: some View {
        switch status {
        case .downloading, .preparing, .queued:
            Button { games.pause(appID: game.appID) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .accessibilityLabel(status == .queued ? "Remove from queue" : "Pause")
        case .paused, .failed:
            Button { games.resume(appID: game.appID, name: game.name) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(!steam.isLoggedOn)
                .accessibilityLabel("Resume")
        default:
            EmptyView()
        }
    }
}
