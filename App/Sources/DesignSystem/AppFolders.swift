import Foundation

/// Where Shiori keeps things. On iOS: games in Documents (visible in the Files app) and
/// state in Application Support. Apple TV gives apps no permanent storage, only caches the
/// system may clear when space runs low, so both live there; a cleared game re-downloads,
/// and saves are kept off the box (iCloud, Steam Cloud). See spec, Apple TV.
extension URL {
    static var shioriDocuments: URL {
        #if os(tvOS)
        URL.cachesDirectory.appendingPathComponent("Documents", isDirectory: true)
        #else
        URL.documentsDirectory
        #endif
    }

    static var shioriSupport: URL {
        #if os(tvOS)
        URL.cachesDirectory.appendingPathComponent("Application Support", isDirectory: true)
        #else
        URL.applicationSupportDirectory
        #endif
    }
}

/// A game's files as an engine that reads its game root sees them: `patch/` laid over `base/`
/// (spec, Game folders and patching). Engines that take one folder (KiriKiri, Siglus) run on
/// a runner folder in Caches holding links to `base/`'s entries, with `patch/`'s in their
/// place where both have one and `patch/`'s extra files (archives such as `patch2.xp3`) beside
/// them. iOS only: tvOS apps can't make symbolic links in their containers.
enum LayeredGameRoot {
    /// Links `base`'s entries into `destination`, with `patch`'s entries in their place where
    /// both have one (names compared ignoring case; folders present in both are merged further
    /// down). Names in `skipping` (lowercased) are left out at the top level.
    static func overlay(base: URL, patch: URL?, into destination: URL, skipping: Set<String> = []) throws {
        let fileManager = FileManager.default
        func entries(_ folder: URL?) -> [String: URL] {
            guard let folder, let names = try? fileManager.contentsOfDirectory(atPath: folder.path) else { return [:] }
            var result: [String: URL] = [:]
            for name in names where !name.hasPrefix(".") {
                result[name.lowercased()] = folder.appendingPathComponent(name)
            }
            return result
        }
        func isFolder(_ url: URL) -> Bool {
            var folder: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &folder) && folder.boolValue
        }
        let baseEntries = entries(base)
        let patchEntries = entries(patch)
        for (key, baseURL) in baseEntries where !skipping.contains(key) {
            let target = destination.appendingPathComponent(baseURL.lastPathComponent)
            if let patchURL = patchEntries[key] {
                if isFolder(baseURL), isFolder(patchURL) {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                    try overlay(base: baseURL, patch: patchURL, into: target)
                } else {
                    try fileManager.createSymbolicLink(at: target, withDestinationURL: patchURL)
                }
            } else {
                try fileManager.createSymbolicLink(at: target, withDestinationURL: baseURL)
            }
        }
        for (key, patchURL) in patchEntries where baseEntries[key] == nil && !skipping.contains(key) {
            try fileManager.createSymbolicLink(at: destination.appendingPathComponent(patchURL.lastPathComponent),
                                               withDestinationURL: patchURL)
        }
    }
}
