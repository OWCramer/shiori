// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// Patches being imported (Import Patch, or a file dropped onto a game), per game: unpacked
/// off the main thread into the game's `patch/` folder, with progress and the outcome. Shared
/// so a game's page shows an import started from its capsule in the library, and so an
/// import keeps going when the page closes.
@MainActor @Observable
final class PatchImports {
    static let shared = PatchImports()

    /// An import under way: its file name, how far it has got, the entry being unpacked.
    struct Progress: Equatable {
        var name: String
        var fraction: Double
        var file: String
    }

    private(set) var running: [UInt32: Progress] = [:]
    /// The outcome of each game's last import.
    private(set) var messages: [UInt32: String] = [:]
    /// Counts each game's finished imports, so pages showing it re-read its patch files.
    private(set) var finished: [UInt32: Int] = [:]

    private init() {}

    func isRunning(_ appID: UInt32) -> Bool { running[appID] != nil }

    /// Unpacks `url` (a zip, 7z or rar, a folder, or a loose file) into the game's `patch/`.
    /// `ownsFile`: the file is Shiori's own copy (a drop) and is deleted afterwards.
    func start(appID: UInt32, url: URL, gameFolder: URL, ownsFile: Bool = false) {
        guard running[appID] == nil else { return }
        let name = url.lastPathComponent
        running[appID] = Progress(name: name, fraction: 0, file: "")
        messages[appID] = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                if ownsFile { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            var shown = -1.0
            let outcome: Result<Int, Error> = Result {
                try PatchStore.importItem(at: url, gameFolder: gameFolder) { written, total, file in
                    let fraction = total > 0 ? Double(written) / Double(total) : 0
                    // A few hundred updates at most, not one per megabyte.
                    guard fraction - shown >= 0.002 || fraction >= 1 else { return }
                    shown = fraction
                    Task { @MainActor in self?.running[appID] = Progress(name: name, fraction: fraction, file: file) }
                }
            }
            await self?.finish(appID: appID, name: name, outcome: outcome)
        }
    }

    private func finish(appID: UInt32, name: String, outcome: Result<Int, Error>) {
        running[appID] = nil
        switch outcome {
        case let .success(count):
            messages[appID] = "Imported \(count) file\(count == 1 ? "" : "s") from \(name)."
        case let .failure(error):
            messages[appID] = "Couldn't import the patch: \(error.localizedDescription)"
        }
        finished[appID, default: 0] += 1
    }

    func fail(appID: UInt32, _ message: String) {
        messages[appID] = message
    }
}
