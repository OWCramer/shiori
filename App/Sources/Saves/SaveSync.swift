import Foundation

/// Mirrors a game's `saves/` folder with a remote folder (the iCloud container).
///
/// Rules from the spec: per file, the newer modification time wins; the losing copy is
/// kept as a timestamped conflict file under `saves/conflicts/` (Ren'Py only reads the
/// top level, so conflicts never appear in-game); a remote file is never deleted
/// because it's missing locally. Files that match are left alone.
///
/// All access to the remote side goes through `NSFileCoordinator`, which is what makes
/// iCloud download a file before it's read and pick up a write for upload.
enum SaveSync {
    struct Result: Equatable, Sendable {
        var pulled: [String] = []
        var pushed: [String] = []
        var conflicts: [String] = []
        var unchanged = 0

        var summary: String {
            if pulled.isEmpty, pushed.isEmpty, conflicts.isEmpty { return "Up to date" }
            var parts: [String] = []
            if !pulled.isEmpty { parts.append("\(pulled.count) downloaded") }
            if !pushed.isEmpty { parts.append("\(pushed.count) uploaded") }
            if !conflicts.isEmpty { parts.append("\(conflicts.count) conflict\(conflicts.count == 1 ? "" : "s") kept") }
            return parts.joined(separator: ", ")
        }
    }

    enum Direction: Sendable {
        /// Bring newer remote files down (before playing).
        case pull
        /// Send newer local files up (after playing).
        case push
        case both
    }

    enum Error: Swift.Error, LocalizedError {
        case unavailable

        var errorDescription: String? {
            "iCloud isn't available. Sign in to iCloud and turn on iCloud Drive for Shiori."
        }
    }

    static let containerIdentifier = "iCloud.com.owencramer.vnhub"
    static let conflictsFolder = "conflicts"
    /// Modification times within this many seconds count as the same; filesystems
    /// round differently and iCloud preserves seconds, not nanoseconds.
    static let tolerance: TimeInterval = 2

    /// `<iCloud container>/Saves`, or a test folder from `-ShioriSaveSyncRoot` in debug builds.
    /// Can block while iCloud sets the container up, so call it off the main thread.
    static func remoteRoot() -> URL? {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ShioriSaveSyncRoot") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Saves", isDirectory: true)
    }

    /// Syncs `local` (a game's `saves/`) with `remote` (`Saves/<appid>/`).
    static func sync(local: URL, remote: URL, direction: Direction, now: Date = .now) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try coordinate(writing: remote, options: []) { try fm.createDirectory(at: $0, withIntermediateDirectories: true) }

        let localFiles = files(in: local)
        let remoteFiles = remoteFileList(remote)
        var result = Result()

        for name in Set(localFiles.keys).union(remoteFiles.keys).sorted() {
            let localDate = localFiles[name]
            let remoteDate = remoteFiles[name]
            let localURL = local.appendingPathComponent(name)
            let remoteURL = remote.appendingPathComponent(name)

            switch (localDate, remoteDate) {
            case let (nil, remoteDate?):
                // Only on the remote side: bring it down. (Never delete remotely.)
                guard direction != .push else { continue }
                try download(remoteURL, to: localURL, modified: remoteDate)
                result.pulled.append(name)

            case let (localDate?, nil):
                guard direction != .pull else { continue }
                try upload(localURL, to: remoteURL, modified: localDate)
                result.pushed.append(name)

            case let (localDate?, remoteDate?):
                if abs(localDate.timeIntervalSince(remoteDate)) <= tolerance {
                    result.unchanged += 1
                } else if remoteDate > localDate {
                    guard direction != .push else { continue }
                    if keepsConflicts(name), try contentsDiffer(localURL, remoteURL) {
                        try keepConflict(localURL, in: local, now: now)
                        result.conflicts.append(name)
                    }
                    try download(remoteURL, to: localURL, modified: remoteDate)
                    result.pulled.append(name)
                } else {
                    guard direction != .pull else { continue }
                    if keepsConflicts(name), try contentsDiffer(localURL, remoteURL) {
                        try download(remoteURL, to: conflictURL(for: name, in: local, now: now), modified: remoteDate)
                        result.conflicts.append(name)
                    }
                    try upload(localURL, to: remoteURL, modified: localDate)
                    result.pushed.append(name)
                }

            case (nil, nil):
                break
            }
        }
        return result
    }

    /// Ren'Py rewrites `persistent` on every run and merges copies itself, so keeping its
    /// losing versions would only pile up files; for it, the newer copy simply wins.
    private static func keepsConflicts(_ name: String) -> Bool {
        (name as NSString).lastPathComponent != "persistent"
    }

    // MARK: - Listing

    /// Relative path → modification date for every regular file, skipping conflicts and
    /// hidden files.
    static func files(in root: URL) -> [String: Date] {
        let rootPath = root.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [:] }
        var result: [String: Date] = [:]
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            let relative = String(path.dropFirst(rootPath.count + 1))
            if relative == conflictsFolder || relative.hasPrefix(conflictsFolder + "/") { continue }
            result[relative] = date
        }
        return result
    }

    /// Like `files(in:)`, but also counts iCloud items that aren't downloaded yet (older
    /// systems show those as hidden `.name.icloud` placeholders).
    private static func remoteFileList(_ root: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        coordinateQuietly(reading: root) { root in
            result = files(in: root)
            let rootPath = root.resolvingSymlinksInPath().path
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey, .contentModificationDateKey]
            ) else { return }
            for case let url as URL in enumerator where url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" {
                let name = String(url.deletingPathExtension().lastPathComponent.dropFirst())
                let directory = url.deletingLastPathComponent().resolvingSymlinksInPath().path
                let relative = directory == rootPath ? name : String(directory.dropFirst(rootPath.count + 1)) + "/" + name
                if result[relative] == nil {
                    result[relative] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                }
            }
        }
        return result
    }

    // MARK: - Copying

    private static func download(_ remote: URL, to local: URL, modified: Date) throws {
        try? FileManager.default.startDownloadingUbiquitousItem(at: remote)
        try coordinate(reading: remote) { source in
            try replace(local, with: source, modified: modified)
        }
    }

    private static func upload(_ local: URL, to remote: URL, modified: Date) throws {
        try coordinate(writing: remote) { destination in
            try replace(destination, with: local, modified: modified)
        }
    }

    private static func replace(_ destination: URL, with source: URL, modified: Date) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).shiori-tmp")
        try? fm.removeItem(at: temporary)
        try fm.copyItem(at: source, to: temporary)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path)
        _ = try fm.replaceItemAt(destination, withItemAt: temporary)
    }

    private static func contentsDiffer(_ a: URL, _ b: URL) throws -> Bool {
        var differ = true
        try coordinate(reading: b) { b in
            differ = !FileManager.default.contentsEqual(atPath: a.path, andPath: b.path)
        }
        return differ
    }

    private static func conflictURL(for name: String, in local: URL, now: Date) -> URL {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.standard))
            .replacingOccurrences(of: ":", with: "")
        return local.appendingPathComponent(conflictsFolder).appendingPathComponent("\(stamp) \(name)")
    }

    private static func keepConflict(_ file: URL, in local: URL, now: Date) throws {
        let name = String(file.path.dropFirst(local.resolvingSymlinksInPath().path.count + 1))
        let destination = conflictURL(for: name, in: local, now: now)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: file, to: destination)
    }

    // MARK: - Coordination

    private static func coordinate(reading url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Swift.Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }

    private static func coordinateQuietly(reading url: URL, _ body: (URL) -> Void) {
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &error, byAccessor: body)
    }

    private static func coordinate(writing url: URL, options: NSFileCoordinator.WritingOptions = [.forReplacing], _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Swift.Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: options, error: &coordinationError) { url in
            do { try body(url) } catch { bodyError = error }
        }
        if let error = coordinationError ?? bodyError { throw error }
    }
}
