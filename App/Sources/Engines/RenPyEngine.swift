import Foundation

/// Ren'Py detection. A Ren'Py PC build has `renpy/` (the engine) and `game/` (scripts and
/// archives) at its root. The version comes from the engine's own source where it ships,
/// falling back to `game/script_version.txt`.
enum RenPyEngine: VNEngine {
    static let id = "renpy"
    static let displayName = "Ren'Py"

    static func detect(gameRoot: URL) -> EngineMatch? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let renpy = gameRoot.appendingPathComponent("renpy")
        let game = gameRoot.appendingPathComponent("game")
        guard fm.fileExists(atPath: renpy.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.fileExists(atPath: game.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }

        let (version, source) = readVersion(renpy: renpy, game: game)
        var details: [String: String] = [:]
        if let source { details["versionSource"] = source }
        if let python = pythonGeneration(root: gameRoot, version: version) { details["python"] = python }
        if let launcher = launcherScript(root: gameRoot) { details["launcher"] = launcher }
        return EngineMatch(engine: id, version: version, details: details)
    }

    /// `version_tuple = (7, 3, 5, vc_version)` in `renpy/__init__.py` (Ren'Py 6–7), or
    /// `VersionTuple(8, 1, 3, vc_version)` (8.x), with the build number from `renpy/vc_version.py`.
    static func readVersion(renpy: URL, game: URL) -> (String?, String?) {
        let vcVersion = (try? String(contentsOf: renpy.appendingPathComponent("vc_version.py"), encoding: .utf8))
            .flatMap { firstMatch(#"vc_version\s*=\s*(\d+)"#, in: $0) }
        if let vcFile = try? String(contentsOf: renpy.appendingPathComponent("vc_version.py"), encoding: .utf8),
           let full = firstMatch(#"(?m)^version\s*=\s*u?['"]([0-9][0-9.]*)['"]"#, in: vcFile)
        {
            return (full, "renpy/vc_version.py")
        }
        if let initFile = try? String(contentsOf: renpy.appendingPathComponent("__init__.py"), encoding: .utf8),
           let tuple = firstMatch(#"version_tuple\s*=\s*(?:VersionTuple)?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#, in: initFile, groups: 3)
        {
            return ((tuple + [vcVersion].compactMap { $0 }).joined(separator: "."), "renpy/__init__.py")
        }
        if let script = try? String(contentsOf: game.appendingPathComponent("script_version.txt"), encoding: .utf8),
           let tuple = firstMatch(#"\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#, in: script, groups: 3)
        {
            return (tuple.joined(separator: "."), "game/script_version.txt")
        }
        return (nil, nil)
    }

    /// Ren'Py 8 runs on Python 3, earlier versions on Python 2. The bundled `lib/` folder
    /// names say so directly (`py3-windows-x86_64` vs `py2-…` or the older `windows-i686`).
    static func pythonGeneration(root: URL, version: String?) -> String? {
        let lib = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("lib").path)) ?? []
        if lib.contains(where: { $0.hasPrefix("py3-") || $0.hasPrefix("python3") }) { return "3" }
        if lib.contains(where: { $0.hasPrefix("py2-") || $0.hasPrefix("python2") || $0.hasPrefix("windows-") }) { return "2" }
        guard let major = version?.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        return major >= 8 ? "3" : "2"
    }

    /// The `<name>.py` next to `<name>.exe` that starts the game on PC.
    static func launcherScript(root: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".py") }
            .first { names.contains(String($0.dropLast(3)) + ".exe") }
            ?? names.first { $0.hasSuffix(".py") }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text, groups: 1)?.first
    }

    private static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1 ... groups).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

// MARK: - Runtime

extension RenPyEngine {
    /// The embedded runtime (Scripts/fetch-renios.sh), pinned to Highway Blossoms' Ren'Py.
    static let runtimeVersion = "8.1.3"
    static let runtimePython = "3"

    /// Why this game can't run on the embedded runtime, or nil if it can. Games are refused
    /// when the Ren'Py major version or the Python generation differs (spec: Ren'Py engine).
    static func incompatibility(_ match: EngineMatch) -> String? {
        guard let version = match.version, let major = version.split(separator: ".").first else {
            return "Couldn't read this game's Ren'Py version."
        }
        let runtimeMajor = runtimeVersion.split(separator: ".").first!
        if major != runtimeMajor {
            return "This game uses Ren'Py \(version); VN Hub runs Ren'Py \(runtimeVersion)."
        }
        if let python = match.details["python"], python != runtimePython {
            return "This game needs Python \(python); VN Hub's Ren'Py uses Python \(runtimePython)."
        }
        return nil
    }

    /// Runs the game in this process until it quits, then exits the app: CPython can't be
    /// restarted cleanly in-process, so returning to the hub means relaunching VN Hub.
    @MainActor
    static func launch(gameFolder: URL, match: EngineMatch, saves: URL) -> Never {
        let launcher = (match.details["launcher"] ?? "main.py").replacingOccurrences(of: ".py", with: "")
        let status = vnhub_renpy_run(gameFolder.path, launcher, saves.path)
        exit(status == 0 ? 0 : 1)
    }
}
