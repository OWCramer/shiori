import Foundation

/// A Windows Unity player build, recognised by its real layout rather than by any name
/// ending in `_data`: `UnityPlayer.dll`, or a `<Name>_Data/` folder holding the player's own
/// files. Shiori can't play Unity games (docs/unity-survey.md); it records which Unity and
/// which scripting backend so the game page can say so.
enum UnityLayout {
    /// Files and folders only a Unity player's `<Name>_Data/` has.
    static let dataMarkers: Set<String> = ["globalgamemanagers", "data.unity3d", "level0", "maindata", "managed", "il2cpp_data"]
    /// Files a version string is read from: the first bytes of each start with it.
    static let versionFiles = ["globalgamemanagers", "data.unity3d", "maindata"]

    /// Where the player is: the game root, or one folder down (WORLD END ECONOMiCA's HD
    /// remasters keep it in `WEE3 HD/`). Nil when this isn't a Unity build.
    struct Found {
        /// The folder holding the player, relative to the game root ("" at the root).
        var folder: String
        /// The `<Name>_Data` folder's name, if there is one.
        var dataFolder: String?
    }

    static func find(in root: URL) -> Found? {
        if let found = look(at: root, relative: "") { return found }
        for name in children(of: root) where isDirectory(root.appendingPathComponent(name)) {
            if let found = look(at: root.appendingPathComponent(name), relative: name) { return found }
        }
        return nil
    }

    private static func look(at folder: URL, relative: String) -> Found? {
        let names = children(of: folder)
        let data = names.first { name in
            name.lowercased().hasSuffix("_data")
                && !Set(children(of: folder.appendingPathComponent(name)).map { $0.lowercased() }).isDisjoint(with: dataMarkers)
        }
        if data != nil || names.contains(where: { $0.lowercased() == "unityplayer.dll" }) {
            return Found(folder: relative, dataFolder: data)
        }
        return nil
    }

    /// The match recorded for a Unity build: its version, read from the player's data
    /// header (plain files only, nothing encrypted is touched), and Mono or IL2CPP.
    static func match(in root: URL) -> EngineMatch? {
        guard let found = find(in: root) else { return nil }
        let base = found.folder.isEmpty ? root : root.appendingPathComponent(found.folder)
        var match = EngineMatch(engine: "unity", version: nil)
        let rootNames = Set(children(of: base).map { $0.lowercased() })
        var dataNames: Set<String> = []
        if let data = found.dataFolder {
            let dataURL = base.appendingPathComponent(data)
            dataNames = Set(children(of: dataURL).map { $0.lowercased() })
            for name in versionFiles {
                guard let actual = children(of: dataURL).first(where: { $0.lowercased() == name }),
                      let version = version(in: dataURL.appendingPathComponent(actual)) else { continue }
                match.version = version
                break
            }
        }
        if rootNames.contains("gameassembly.dll") || dataNames.contains("il2cpp_data") {
            match.details["backend"] = "IL2CPP"
        } else if dataNames.contains("managed") {
            match.details["backend"] = "Mono"
        }
        if !found.folder.isEmpty { match.details["folder"] = found.folder }
        return match
    }

    /// The Unity version at the start of a SerializedFile (`globalgamemanagers`, `mainData`)
    /// or a UnityFS bundle (`data.unity3d`): e.g. `2018.4.0f1`.
    static func version(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 256) else { return nil }
        return version(inHeader: head)
    }

    static func version(inHeader head: Data) -> String? {
        // The header is binary with the version as a NUL-terminated ASCII string inside;
        // UnityFS also has an earlier "5.x.x" player-format string, so prefer a full
        // revision (with its f1/p3 suffix) and fall back to the first dotted number.
        let runs = head.split(separator: 0).compactMap { String(bytes: $0, encoding: .isoLatin1) }
        let full = /\d{1,4}\.\d{1,2}\.\d{1,3}[abfpx]\d{1,3}/
        let plain = /\d{1,4}\.\d{1,2}\.\d{1,3}/
        if let found = runs.lazy.compactMap({ $0.firstMatch(of: full) }).first { return String(found.output) }
        if let found = runs.lazy.compactMap({ $0.firstMatch(of: plain) }).first { return String(found.output) }
        return nil
    }

    private static func children(of folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
