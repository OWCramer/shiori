// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CryptoKit
import Foundation
import os
import SteamKit

private let log = Logger(subsystem: "com.owencramer.vnhub", category: "steamcloud")

/// Brings a game's Steam Cloud saves into its `saves/` folder. Read-only towards Steam:
/// this never uploads or deletes anything in the cloud.
///
/// Which cloud files are saves comes from the app's PICS `ufs` rules. For Ren'Py the PC
/// build keeps saves in `game/saves` (and mirrors them to `%APPDATA%/RenPy/<game>`), and
/// Shiori runs the game with `--savedir <game>/saves`, so both map onto `saves/`. KiriKiri PC
/// builds keep saves in `savedata/` beside the exe, which Shiori points at `saves/`
/// (the engine's `savedata/` is linked to it). Siglus keeps them in `savedata/` too.
///
/// A folder is often listed once per pattern (Harmonia: `savedata` with `*.sav`, `*.bmp`,
/// `*.ini`), so rules are grouped by folder (`UFSConfig.saveFolders`) and a file belongs to
/// the save folder if it matches any of its patterns, both ways.
enum SteamCloudSync {
    struct Result: Equatable, Sendable {
        var downloaded: [String] = []
        /// Same contents on both sides.
        var unchanged = 0
        /// Local copy is newer than Steam's; it would be uploaded once uploads are enabled.
        var newerLocally: [String] = []
        /// Local copies replaced by newer cloud ones, kept in `saves/conflicts`.
        var backedUp: [String] = []
        /// Cloud files outside the save rules Shiori knows how to place.
        var unmapped: [String] = []

        var summary: String {
            var parts: [String] = []
            if !downloaded.isEmpty { parts.append("\(downloaded.count) downloaded") }
            if !newerLocally.isEmpty { parts.append("\(newerLocally.count) newer here") }
            if !backedUp.isEmpty { parts.append("\(backedUp.count) local cop\(backedUp.count == 1 ? "y" : "ies") kept") }
            return parts.isEmpty ? "Up to date (\(unchanged) save\(unchanged == 1 ? "" : "s"))" : parts.joined(separator: ", ")
        }
    }

    /// Whether a save rule's files are Ren'Py, KiriKiri or Siglus saves that belong in `saves/`.
    static func mapsToSaves(_ rule: UFSConfig.SaveRule) -> Bool {
        mapsToSaves(root: rule.root, path: rule.path)
    }

    static func mapsToSaves(_ folder: UFSConfig.SaveFolder) -> Bool {
        mapsToSaves(root: folder.root, path: folder.path)
    }

    static func mapsToSaves(root: String, path: String) -> Bool {
        let root = root.lowercased()
        let path = path.lowercased()
        if root == "gameinstall" { return path == "game/saves" || path == "savedata" }
        if root.hasPrefix("winappdata") { return path.hasPrefix("renpy/") }
        return false
    }

    static func pull(session: SteamSession, appID: UInt32, saves: URL, now: Date = .now) async throws -> Result {
        guard let app = try await session.appInfo([appID]).first else { return Result() }
        // Every pattern the rules give the save folder (Harmonia's `.sav`, `.bmp` and `.ini`).
        let folders = UFSConfig(app: app).saveFolders.filter(mapsToSaves)
        let (_, files) = try await session.cloudFiles(appID: appID)
        let fm = FileManager.default
        try fm.createDirectory(at: saves, withIntermediateDirectories: true)

        var result = Result()
        for file in files where !file.isDeleted {
            guard folders.contains(where: { $0.holds(file) }),
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

    // MARK: - Uploads (off until the user switches them on)

    /// Global switch for writing to Steam Cloud (Settings). On by default since the user enabled
    /// uploads on 2026-10-07; every replaced cloud file is backed up locally first.
    /// Never in the simulator: it's signed in to the user's real account, and test saves made
    /// there must not replace his PC saves (dry runs still work there).
    static var uploadsEnabled: Bool {
        get {
            #if targetEnvironment(simulator)
            #if DEBUG
            // Shown as on a device for screenshots; that library has no Steam session to upload with.
            ScreenshotLibrary.isOn
            #else
            false
            #endif
            #else
            UserDefaults.standard.object(forKey: "steamCloudUploads") as? Bool ?? true
            #endif
        }
        set { UserDefaults.standard.set(newValue, forKey: "steamCloudUploads") }
    }

    /// Debug and automation builds: `-ShioriSteamCloudUploadsDryRun YES` turns every upload into
    /// a dry run (what would go up is logged, nothing is written to Steam) and lets the
    /// upload paths run even with `steamCloudUploads` off, so they can be tested on a real
    /// account without touching its cloud files. Always false in shipped builds.
    static var dryRunUploads: Bool {
        #if DEBUG || SHIORI_AUTOMATION
        UserDefaults.standard.bool(forKey: "ShioriSteamCloudUploadsDryRun")
        #else
        false
        #endif
    }

    /// Stable per-install id Steam uses to tell this device's app sessions apart.
    static var clientID: UInt64 {
        let key = "steamCloudClientID"
        if let stored = UserDefaults.standard.string(forKey: key), let id = UInt64(stored) { return id }
        let id = UInt64.random(in: 1 ... UInt64.max)
        UserDefaults.standard.set(String(id), forKey: key)
        return id
    }

    struct PushResult: Equatable, Sendable {
        var uploaded: [String] = []
        var failed: [String] = []
        var backupFolder: URL?
        /// Nothing was written: `uploaded` is what would have gone up, `failed` the remote
        /// copies that would have been backed up first.
        var dryRun = false

        var summary: String {
            if dryRun {
                return uploaded.isEmpty ? "Dry run: nothing to upload"
                    : "Dry run: would upload \(uploaded.joined(separator: ", "))"
                        + (failed.isEmpty ? "" : "; would back up the cloud copies of \(failed.joined(separator: ", "))")
            }
            if uploaded.isEmpty, failed.isEmpty { return "Nothing to upload" }
            var parts: [String] = []
            if !uploaded.isEmpty { parts.append("\(uploaded.count) uploaded") }
            if !failed.isEmpty { parts.append("\(failed.count) failed") }
            return parts.joined(separator: ", ")
        }
    }

    /// Where remote copies are saved before Shiori replaces them.
    static func backupsDirectory(appID: UInt32) -> URL {
        URL.shioriSupport.appendingPathComponent("SteamCloudBackups/\(appID)", isDirectory: true)
    }

    /// Uploads save files that are newer here than in Steam Cloud. Backs up every remote
    /// copy it's about to replace first. Does nothing unless uploads are enabled.
    /// With `dryRun`, reports what would upload (as `uploaded`) and writes nothing anywhere.
    static func push(session: SteamSession, appID: UInt32, saves: URL, now: Date = .now, dryRun: Bool = false) async throws -> PushResult {
        let dryRun = dryRun || dryRunUploads
        guard uploadsEnabled || dryRun else { return PushResult() }
        guard let app = try await session.appInfo([appID]).first else { return PushResult(dryRun: dryRun) }
        let ufs = UFSConfig(app: app)
        // Every pattern the rules give the save folder (Harmonia's `.sav`, `.bmp` and `.ini`).
        guard let folder = ufs.saveFolders.first(where: mapsToSaves) else { return PushResult(dryRun: dryRun) }
        let (_, remoteFiles) = try await session.cloudFiles(appID: appID)
        let remote = Dictionary(
            remoteFiles.filter { !$0.isDeleted && folder.holds($0) }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // Reuse the prefix exactly as Steam already stores it for this folder, if it has one.
        let prefix = remote.values.first?.prefix ?? canonicalPrefix(for: folder.rules[0])

        let fm = FileManager.default
        var uploads: [CloudUpload] = []
        var toBackUp: [CloudFile] = []
        for name in ((try? fm.contentsOfDirectory(atPath: saves.path)) ?? []).sorted() {
            // Ren'Py's _reload saves are scratch files; folders (sync/, conflicts/) aren't saves.
            guard !name.hasPrefix("_"), !name.hasPrefix("."), folder.matches(name: name) else { continue }
            let url = saves.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let data = fm.contents(atPath: url.path) else { continue }
            let modified = values?.contentModificationDate ?? now
            if let existing = remote[name] {
                if Data(Insecure.SHA1.hash(data: data)) == existing.sha { continue }
                if existing.timestamp.timeIntervalSince(modified) > SaveSync.tolerance { continue } // cloud is newer
                toBackUp.append(existing)
            }
            uploads.append(CloudUpload(path: prefix + name, data: data, timestamp: modified))
        }
        guard !uploads.isEmpty else { return PushResult(dryRun: dryRun) }
        // Steam limits each app's cloud by files (`maxnumfiles`) and bytes (`quota`). An upload
        // that would go over either is refused whole, never sent in part.
        let check = ufs.checkUpload(remote: remoteFiles, uploads: uploads.map { ($0.path, $0.data.count) })
        guard check.isAllowed else {
            let error = QuotaExceeded(check: check)
            log.error("Steam Cloud upload \(appID) refused\(dryRun ? " (dry run)" : "", privacy: .public): \(uploads.count) files, \(error.description, privacy: .public)")
            throw error
        }
        if dryRun {
            return PushResult(uploaded: uploads.map { String($0.path.dropFirst(prefix.count)) }, failed: toBackUp.map(\.name), dryRun: true)
        }

        // Spec: every upload is preceded by a local backup of the remote copy.
        var result = PushResult()
        if !toBackUp.isEmpty {
            let folder = backupsDirectory(appID: appID).appendingPathComponent(stamp(now), isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in toBackUp {
                let data = try await session.cloudDownload(appID: appID, file: file)
                try data.write(to: folder.appendingPathComponent(file.name), options: .atomic)
            }
            result.backupFolder = folder
        }

        // The build the game was installed from (a beta, if one was picked on the game page).
        let branch = UserDefaults.standard.string(forKey: "steamBranch.\(appID)") ?? "public"
        let buildID = app.keyValues[path: "depots", "branches", branch, "buildid"]?.uint64
            ?? app.keyValues[path: "depots", "branches", "public", "buildid"]?.uint64 ?? 0
        let committed = try await session.cloudUpload(appID: appID, clientID: clientID, buildID: buildID, files: uploads)
        result.uploaded = uploads.map(\.path).filter(committed.contains).map { String($0.dropFirst(prefix.count)) }
        result.failed = uploads.map(\.path).filter { !committed.contains($0) }.map { String($0.dropFirst(prefix.count)) }
        return result
    }

    /// `%GameInstall%game/saves/`, with the root spelled the way the Steam client does.
    static func canonicalPrefix(for rule: UFSConfig.SaveRule) -> String {
        let roots = ["gameinstall": "GameInstall", "winappdataroaming": "WinAppDataRoaming",
                     "winappdatalocal": "WinAppDataLocal", "winappdatalocallow": "WinAppDataLocalLow",
                     "winmydocuments": "WinMyDocuments", "winsavedgames": "WinSavedGames"]
        let root = roots[rule.root.lowercased()] ?? rule.root
        return "%\(root)%" + (rule.path.isEmpty ? "" : rule.path + "/")
    }

    /// An upload refused because it would take the game's Steam Cloud over its file count or
    /// byte quota. Nothing was sent.
    struct QuotaExceeded: LocalizedError, CustomStringConvertible {
        var check: UFSConfig.QuotaCheck

        var errorDescription: String? {
            if check.exceedsFileCount, let max = check.maxFiles {
                return "Not uploaded: Steam Cloud keeps at most \(max) files for this game, and this would make \(check.filesAfter)"
            }
            let quota = ByteCountFormatter.string(fromByteCount: Int64(check.quota ?? 0), countStyle: .file)
            return "Not uploaded: over this game's Steam Cloud space (\(quota))"
        }

        var description: String {
            "over Steam Cloud limits: files \(check.filesBefore) -> \(check.filesAfter) of \(check.maxFiles.map(String.init) ?? "any"), bytes \(check.bytesBefore) -> \(check.bytesAfter) of \(check.quota.map(String.init) ?? "any")"
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
    }
}
