import Foundation

/// The user's files in a game's `patch/` folder, which engines layer over `base/`.
/// For Ren'Py, `patch/game/` mirrors the game's own `game/` folder.
enum PatchStore {
    struct PatchFile: Identifiable, Hashable {
        /// Path relative to `patch/`, e.g. `game/images/bg.png`.
        var path: String
        var size: UInt64
        /// True when a file at the same path in `base/` is hidden by this one.
        var overridesBase: Bool
        var id: String { path }
    }

    static func patchFolder(_ gameFolder: URL) -> URL {
        gameFolder.appendingPathComponent("patch", isDirectory: true)
    }

    /// Every file under `patch/`, sorted by path.
    static func list(gameFolder: URL) -> [PatchFile] {
        let patch = patchFolder(gameFolder)
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        let rootPath = patch.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: patch, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [PatchFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(rootPath + "/") else { continue }
            let relative = String(full.dropFirst(rootPath.count + 1))
            let overrides = FileManager.default.fileExists(atPath: base.appendingPathComponent(relative).path)
            files.append(PatchFile(path: relative, size: UInt64(values?.fileSize ?? 0), overridesBase: overrides))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Empties `patch/`, leaving the empty `patch/game/` folder in place.
    static func removeAll(gameFolder: URL) throws {
        let patch = patchFolder(gameFolder)
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: patch, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: item)
        }
        try fm.createDirectory(at: patch.appendingPathComponent("game", isDirectory: true), withIntermediateDirectories: true)
    }

    /// Imports a zip or folder into `patch/`. If it contains a `game/` folder (at its top
    /// level, or inside a single wrapper folder) that structure is kept; otherwise its
    /// contents are treated as files for `game/` when `base/` has one (Ren'Py), else for
    /// the game's own folder. Existing patch files are replaced.
    /// Returns the number of files imported.
    @discardableResult
    static func importItem(at source: URL, gameFolder: URL, progress: ZipExtractor.Progress? = nil) throws -> Int {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("patch-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var isDirectory: ObjCBool = false
        fm.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            try fm.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
        } else if source.pathExtension.lowercased() == "zip" {
            try ZipExtractor.extract(source, to: staging, progress: progress)
        } else if ArchiveExtractor.archiveExtensions.contains(source.pathExtension.lowercased()) {
            try ArchiveExtractor.extract(source, to: staging) { written, total, file in
                progress?(UInt64(written), UInt64(max(total, 0)), file)
            }
        } else {
            // A single loose file, such as an .rpa: it belongs in game/.
            try fm.createDirectory(at: staging.appendingPathComponent("game"), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: staging.appendingPathComponent("game").appendingPathComponent(source.lastPathComponent))
        }

        return try place(staging, gameFolder: gameFolder).count
    }

    /// Moves an unpacked patch from `staging` into `patch/`, placed as Import Patch does
    /// (`into` forces the game's folder, "root", or Ren'Py's "game"; `strip` steps into a
    /// named wrapper folder). Returns the paths written, relative to `patch/`.
    static func place(_ staging: URL, gameFolder: URL, into: String? = nil, strip: String? = nil) throws -> [String] {
        let fm = FileManager.default
        var root = contentRoot(of: staging)
        if let strip, let inner = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
            .first(where: { $0.lastPathComponent.lowercased() == strip.lowercased() }) { root = inner }
        let patch = patchFolder(gameFolder)
        let hasGame = (try? fm.contentsOfDirectory(atPath: root.path))?.contains { $0.lowercased() == "game" } ?? false
        // Only Ren'Py keeps its files in `game/`; other engines' patches mirror `base/` itself.
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        let baseHasGame = (try? fm.contentsOfDirectory(atPath: base.path))?.contains { $0.lowercased() == "game" } ?? true
        let intoGame: Bool
        switch into {
        case "game": intoGame = !hasGame
        case "root": intoGame = false
        default: intoGame = !(hasGame || !baseHasGame)
        }
        let destination = intoGame ? patch.appendingPathComponent("game", isDirectory: true) : patch
        let prefix = intoGame ? "game/" : ""
        var written: [String] = []
        try merge(root, into: destination, relative: "", written: &written)
        return written.map { prefix + $0 }
    }

    /// Steps into a lone wrapper folder (e.g. `MyPatch-v2/`) unless it's `game` itself.
    private static func contentRoot(of folder: URL) -> URL {
        var root = folder
        while true {
            let items = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent != "__MACOSX" }
            guard items.count == 1, let only = items.first,
                  (try? only.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  only.lastPathComponent.lowercased() != "game"
            else { return root }
            root = only
        }
    }

    private static func merge(_ source: URL, into destination: URL, relative: String, written: inout [String]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let name = item.lastPathComponent
            if name.hasPrefix(".") || name == "__MACOSX" { continue }
            // Match an existing folder's case ("Game" vs "game") so layers line up.
            let existing = (try? fm.contentsOfDirectory(atPath: destination.path))?.first { $0.lowercased() == name.lowercased() }
            let target = destination.appendingPathComponent(existing ?? name)
            let path = relative + (existing ?? name)
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                try merge(item, into: target, relative: path + "/", written: &written)
            } else {
                // The staging folder is Shiori's own, so its files move into place rather than
                // being written a second time (a 5 GB patch would need 10 GB free otherwise).
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.moveItem(at: item, to: target)
                written.append(path)
            }
        }
    }
}
