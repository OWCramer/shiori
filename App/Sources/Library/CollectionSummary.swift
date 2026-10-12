#if os(iOS)
import Foundation

/// A collection's games counted up: how many are downloaded or downloading, what's left to
/// download and how much it all weighs.
@MainActor
struct CollectionSummary {
    let total: Int
    let downloaded: Int
    let downloading: Int
    /// Not downloaded, paused or failed: what Download All starts.
    let toDownload: [LibraryGame]
    let totalSize: UInt64
    let downloadSize: UInt64

    init(games: [LibraryGame], library: GameLibrary, engineScans: EngineScanStore) {
        var downloaded = 0, downloading = 0
        var toDownload: [LibraryGame] = []
        var totalSize: UInt64 = 0, downloadSize: UInt64 = 0
        for game in games {
            // The stage and record, not the status: a summary doesn't follow download progress.
            let size = Self.size(of: game, record: library.record(for: game.appID), engineScans: engineScans)
            totalSize += size
            switch library.stage(for: game.appID) {
            case .installed, .verifying: downloaded += 1
            case .queued, .preparing, .downloading: downloading += 1
            case .notInstalled, .paused, .failed:
                toDownload.append(game)
                downloadSize += size
            }
        }
        total = games.count
        self.downloaded = downloaded
        self.downloading = downloading
        self.toDownload = toDownload
        self.totalSize = totalSize
        self.downloadSize = downloadSize
    }

    /// Downloaded size, else what Steam's manifests say it weighs.
    static func size(of game: LibraryGame, record: GameRecord?, engineScans: EngineScanStore) -> UInt64 {
        if let record { return record.sizeBytes }
        return engineScans.result(for: game.appID).flatMap { $0.installSize > 0 ? $0.installSize : nil } ?? game.estimatedSize ?? 0
    }

    var gamesText: String { "\(total) game\(total == 1 ? "" : "s")" }

    /// For under a stacked tile: "6 games · 2 downloaded", "Downloading 1 of 6".
    var line: String {
        if downloading > 0 { return "Downloading \(downloading) of \(total)" }
        if downloaded == total { return "\(gamesText) · All downloaded" }
        if downloaded > 0 { return "\(gamesText) · \(downloaded) downloaded" }
        return totalSize > 0 ? "\(gamesText) · \(totalSize.formatted(.byteCount(style: .file)))" : gamesText
    }
}
#endif
