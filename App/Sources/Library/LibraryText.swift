// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SteamKit
import SwiftUI
import UIKit

/// Opens a folder in our Documents in the Files app (the shareddocuments scheme).
@MainActor func openInFiles(_ folder: URL) {
    var components = URLComponents()
    components.scheme = "shareddocuments"
    components.path = folder.path
    if let url = components.url { UIApplication.shared.open(url) }
}

/// One line on a game's state for under its art: "Played yesterday", "Downloading · 42%".
@MainActor func libraryStatusLine(for game: LibraryGame, status: GameLibrary.Status, games: GameLibrary,
                                  history: PlayHistory, engineScans: EngineScanStore) -> String {
    switch status {
    case let .installed(record):
        if let activity = history.lastActivity(game.appID) { return activity.description }
        if games.playBlocker(appID: game.appID) != nil { return "Not playable" }
        return Playability.badge(record.engine, appID: game.appID)
    case let .downloading(progress):
        if progress.phase == .finishing { return "Finishing…" }
        return "Downloading · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
    case .preparing: return "Preparing…"
    case .queued: return "Queued"
    case let .paused(progress):
        return progress.map { "Paused · \($0.fraction.formatted(.percent.precision(.fractionLength(0))))" } ?? "Paused"
    case .failed: return "Download failed"
    case .verifying: return "Verifying…"
    case .notInstalled:
        let size = engineScans.result(for: game.appID).flatMap { $0.installSize > 0 ? $0.installSize : nil } ?? game.estimatedSize
        return size.map { $0.formatted(.byteCount(style: .file)) } ?? "Not downloaded"
    }
}
#endif
