// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Files earlier Shiori builds wrote to keep the player's place ("pick up where you left off",
/// removed 2026-10-13), removed once from each game's `saves/` and its iCloud copy. iCloud
/// never deletes a file remotely because it is gone locally, so the copies go too, or the next
/// pull would bring them back. Never the game's own saves.
///
/// KiriKiri emergency bookmarks an earlier Shiori wrote are emptied before every KiriKiri
/// launch instead (`KiriKiriSaves`): an emptied file is what the game itself leaves, and as the
/// newer copy it replaces the stale ones in iCloud and Steam Cloud.
enum ResumeLeftovers {
    static let names = [
        "shiori-resume.bkm", // KiriKiri, 2026-10-12
        "data_emergency-shiori.ksd", // KiriKiri, the temporary name written through before that
        "shiori-resume.dat", // Artemis
        "shiori-resume.dat.png",
        "shiori-resume.png",
    ]

    private static func doneKey(_ appID: UInt32) -> String { "ResumeLeftoversRemoved.\(appID)" }

    /// Once per game on this device: deletes the leftovers in `local` and `remote` (either may
    /// be nil). Safe off the main thread. Returns the names it deleted.
    @discardableResult
    static func removeOnce(appID: UInt32, local: URL?, remote: URL?) -> [String] {
        guard !UserDefaults.standard.bool(forKey: doneKey(appID)) else { return [] }
        var removed: [String] = []
        for folder in [local, remote].compactMap(\.self) {
            for name in names {
                let url = folder.appendingPathComponent(name)
                if folder == remote {
                    var deleted = false
                    NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: nil) { url in
                        deleted = (try? FileManager.default.removeItem(at: url)) != nil
                    }
                    if deleted { removed.append("iCloud/\(name)") }
                } else if (try? FileManager.default.removeItem(at: url)) != nil {
                    removed.append(name)
                }
            }
        }
        UserDefaults.standard.set(true, forKey: doneKey(appID))
        return removed
    }
}
