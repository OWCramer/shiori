import CryptoKit
import Foundation
import SteamKit

/// Brings a game's Steam Cloud saves into its `saves/` folder. Read-only towards Steam:
/// this never uploads or deletes anything in the cloud.
///
/// Which cloud files are saves comes from the app's PICS `ufs` rules. For Ren'Py the PC
/// build keeps saves in `game/saves` (and mirrors them to `%APPDATA%/RenPy/<game>`), and
/// VN Hub runs the game with `--savedir <game>/saves`, so both map onto `saves/`.
enum SteamCloudSync {
    struct Result: Equatable, Sendable {
        var downloaded: [String] = []
        /// Same contents on both sides.
        var unchanged = 0
        /// Local copy is newer than Steam's; it would be uploaded once uploads are enabled.
        var newerLocally: [String] = []
        /// Local copies replaced by newer cloud ones, kept in `saves/conflicts`.
        var backedUp: [String] = []
        /// Cloud files outside the save rules VN Hub knows how to place.
        var unmapped: [String] = []

        var summary: String {
            var parts: [String] = []
            if !downloaded.isEmpty { parts.append("\(downloaded.count) downloaded") }
            if !newerLocally.isEmpty { parts.append("\(newerLocally.count) newer here") }
            if !backedUp.isEmpty { parts.append("\(backedUp.count) local cop\(backedUp.count == 1 ? "y" : "ies") kept") }
            return parts.isEmpty ? "Up to date (\(unchanged) save\(unchanged == 1 ? "" : "s"))" : parts.joined(separator: ", ")
        }
    }

    /// Whether a save rule's files are Ren'Py saves that belong in `saves/`.
    static func mapsToSaves(_ rule: UFSConfig.SaveRule) -> Bool {
        let root = rule.root.lowercased()
        let path = rule.path.lowercased()
        if root == "gameinstall" { return path == "game/saves" }
        if root.hasPrefix("winappdata") { return path.hasPrefix("renpy/") }
        return false
    }

    static func pull(session: SteamSession, appID: UInt32, saves: URL, now: Date = .now) async throws -> Result {
        guard let app = try await session.appInfo([appID]).first else { return Result() }
        let ufs = UFSConfig(app: app)
        let (_, files) = try await session.cloudFiles(appID: appID)
        let fm = FileManager.default
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)

        var result = Result()
        for file in files where !file.isDeleted {
            guard let rule = ufs.rule(for: file), mapsToSaves(rule),
                  !file.name.contains("/"), !file.name.hasPrefix(".")
            else {
                result.unmapped.append(file.path)
                continue
            }
            let local = saves.appendingPathComponent(file.name)

            if let data = fm.contents(atPath: local.path) {
                if Data(Insecure.SHA1.hash(data: data)) == file.sha {
                    result.unchanged += 1
                    continue
                }
                let modified = (try? local.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified.timeIntervalSince(file.timestamp) >= -SaveSync.tolerance {
                    result.newerLocally.append(file.name)
                    continue
                }
                // Steam's copy is newer: keep ours before replacing it.
                let backup = saves.appendingPathComponent(SaveSync.conflictsFolder)
                    .appendingPathComponent("\(stamp(now)) steam-replaced \(file.name)")
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: backup)
                result.backedUp.append(file.name)
            }

            let data = try await session.cloudDownload(appID: appID, file: file)
            try data.write(to: local, options: .atomic)
            try fm.setAttributes([.modificationDate: file.timestamp], ofItemAtPath: local.path)
            result.downloaded.append(file.name)
        }
        return result
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
    }
}
