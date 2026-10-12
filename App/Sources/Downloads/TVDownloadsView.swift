#if os(tvOS)
// Apple TV's download queue, a sheet over its library. iPhone and iPad have the Downloads
// tab (`DownloadsScreen`).
import SteamKit
import SwiftUI

/// The download queue: the active download, then queued, paused and failed ones.
struct DownloadsView: View {
    let library: [LibraryGame]
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(PatchInstaller.self) private var patches
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
                if !patches.jobs.isEmpty {
                    Section("Patches") {
                        ForEach(patches.jobs.keys.sorted(), id: \.self) { appID in
                            if let job = patches.jobs[appID], let game = game(appID) {
                                PatchJobRow(game: game, job: job)
                            }
                        }
                    }
                }
            }
            .overlay {
                if games.downloadItems.isEmpty && patches.jobs.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Games you download appear here while they're in progress."))
                }
            }
            .navigationTitle("Downloads")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if games.isDownloading {
                    Text("Downloads keep going in the background while iOS allows it; if iOS stops one, it resumes when you come back to Shiori.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        }
    }
}

/// A patch from the patch list downloading or installing (PatchInstaller).
private struct PatchJobRow: View {
    let game: LibraryGame
    let job: PatchInstaller.Job
    @Environment(PatchInstaller.self) private var patches

    var body: some View {
        HStack(spacing: 12) {
            CapsuleArt(game: game)
                .frame(width: 44)
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.headline).lineLimit(1)
                Text(game.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                switch job.phase {
                case let .downloading(written, total, _, _):
                    if total > 0 { ProgressView(value: Double(written), total: Double(max(total, written))) }
                    Text(total > 0 ? "\(written.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
                                   : written.formatted(.byteCount(style: .file)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                case .checking:
                    Text("Checking…").font(.caption).foregroundStyle(.secondary)
                case let .installing(fraction):
                    ProgressView(value: fraction)
                    Text("Installing…").font(.caption).foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
                }
            }
            Spacer()
            if job.isFailure {
                Button("Dismiss", systemImage: "xmark.circle") { patches.dismissFailure(appID: game.appID) }
                    .labelStyle(.iconOnly)
            } else {
                Button("Cancel", systemImage: "xmark.circle") { patches.cancel(appID: game.appID) }
                    .labelStyle(.iconOnly)
            }
        }
        .padding(.vertical, 2)
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
#endif
