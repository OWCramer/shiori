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

        let libPython = pythonGeneration(root: gameRoot)
        let (version, source) = readVersion(renpy: renpy, game: game, python: libPython)
        var details: [String: String] = [:]
        if let source { details["versionSource"] = source }
        if let python = libPython ?? pythonGeneration(version: version) { details["python"] = python }
        if let launcher = launcherScript(root: gameRoot) { details["launcher"] = launcher }
        return EngineMatch(engine: id, version: version, details: details)
    }

    /// `version_tuple = (7, 3, 5, vc_version)` in `renpy/__init__.py` (Ren'Py 6–7), or
    /// `VersionTuple(8, 1, 3, vc_version)` (8.x), with the build number from `renpy/vc_version.py`.
    /// Ren'Py 7.5+ and 8.0+ share one engine source with a tuple for each Python
    /// (`if PY2: (7, 6, 0) else: (8, 1, 0)`); `python` picks the one the game ships with.
    static func readVersion(renpy: URL, game: URL, python: String? = nil) -> (String?, String?) {
        let vcVersion = (try? String(contentsOf: renpy.appendingPathComponent("vc_version.py"), encoding: .utf8))
            .flatMap { firstMatch(#"vc_version\s*=\s*(\d+)"#, in: $0) }
        if let vcFile = try? String(contentsOf: renpy.appendingPathComponent("vc_version.py"), encoding: .utf8),
           let full = firstMatch(#"(?m)^version\s*=\s*u?['"]([0-9][0-9.]*)['"]"#, in: vcFile)
        {
            return (full, "renpy/vc_version.py")
        }
        if let initFile = try? String(contentsOf: renpy.appendingPathComponent("__init__.py"), encoding: .utf8) {
            let tuples = allMatches(#"version_tuple\s*=\s*(?:VersionTuple)?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)"#, in: initFile, groups: 3)
            let preferred = tuples.first { tuple in
                switch python {
                case "3": Int(tuple[0]).map { $0 >= 8 } ?? false
                case "2": Int(tuple[0]).map { $0 < 8 } ?? false
                default: false
                }
            }
            if let tuple = preferred ?? tuples.first {
                return ((tuple + [vcVersion].compactMap { $0 }).joined(separator: "."), "renpy/__init__.py")
            }
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
    static func pythonGeneration(root: URL) -> String? {
        let lib = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("lib").path)) ?? []
        if lib.contains(where: { $0.hasPrefix("py3-") || $0.hasPrefix("python3") }) { return "3" }
        if lib.contains(where: { $0.hasPrefix("py2-") || $0.hasPrefix("python2") || $0.hasPrefix("windows-") }) { return "2" }
        return nil
    }

    /// Without a `lib/` folder, Ren'Py 8 means Python 3.
    static func pythonGeneration(version: String?) -> String? {
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

    private static func allMatches(_ pattern: String, in text: String, groups: Int) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1 ... groups).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        }
    }

    private static func firstMatch(_ pattern: String, in text: String, groups: Int) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1 ... groups).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

// MARK: - Runtime

/// A Ren'Py runtime VN Hub ships (Scripts/build-renpy-runtimes.sh): one per Python.
struct RenPyRuntime: Equatable, Sendable {
    /// Framework name in the app bundle.
    let framework: String
    let version: String
    let python: String

    /// Ren'Py 8.1.3 on CPython 3.9, Highway Blossoms' version. Runs Ren'Py 8 games with the
    /// game's own engine code.
    static let renpy8 = RenPyRuntime(framework: "RenPy8", version: "8.1.3", python: "3")
    /// Ren'Py 7.8.7 on CPython 2.7. Runs Ren'Py 6.99 and 7.x games with its own engine code
    /// (bundled as RenPy7Base), since the games' older engine can't load its compiled modules.
    static let renpy7 = RenPyRuntime(framework: "RenPy7", version: "7.8.7", python: "2")

    static let all = [renpy8, renpy7]

    /// Whether the game runs on its own `renpy/` folder or on the runtime's.
    var usesGameEngine: Bool { python == "3" }
}

extension RenPyEngine {
    /// Shown in Settings.
    static var runtimeVersion: String { RenPyRuntime.all.map(\.version).joined(separator: ", ") }

    /// The runtime a game runs on, or nil.
    static func runtime(for match: EngineMatch) -> RenPyRuntime? {
        guard let version = match.version, let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        let python = match.details["python"] ?? (major >= 8 ? "3" : "2")
        switch (major, python) {
        case (8, "3"): return .renpy8
        case (6 ... 7, "2"): return .renpy7
        default: return nil
        }
    }

    /// True when the game runs on the same Ren'Py as on PC: its own engine (Ren'Py 8), or a
    /// 7.8 game on the 7.8.7 runtime. Saves are then safe to hand back to the PC.
    static func savesMatchPC(_ match: EngineMatch) -> Bool {
        guard match.engine == id, let runtime = runtime(for: match) else { return true }
        if runtime.usesGameEngine { return true }
        let minor = { (v: String) in v.split(separator: ".").prefix(2).joined(separator: ".") }
        return minor(match.version ?? "") == minor(runtime.version)
    }

    /// Why this game can't run on an embedded runtime, or nil if it can (spec: Ren'Py engine).
    static func incompatibility(_ match: EngineMatch) -> String? {
        guard let version = match.version, let major = version.split(separator: ".").first.flatMap({ Int($0) }) else {
            return "Couldn't read this game's Ren'Py version."
        }
        let python = match.details["python"]
        if runtime(for: match) == nil {
            if let python { return "This game uses Ren'Py \(version) on Python \(python), which VN Hub can't run." }
            return "This game uses Ren'Py \(version), which VN Hub can't run."
        }
        // Ren'Py 7.8 keeps compatibility back to 6.99; older games are refused rather than
        // left to fail halfway through.
        if major == 6, let minor = version.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), minor < 99 {
            return "This game uses Ren'Py \(version); VN Hub runs Ren'Py 6.99 and newer."
        }
        return nil
    }

    /// Runs the game in this process until it quits, then exits the app: CPython can't be
    /// restarted cleanly in-process, so returning to the hub means relaunching VN Hub.
    ///
    /// Ren'Py's launcher is pointed at a runner folder whose `base/main.py` is VN Hub's
    /// bootstrap and whose `base/lib` is the Python library: the game's own for Ren'Py 8
    /// (`vnhub_main.py`, which then runs the game's launcher), VN Hub's Ren'Py 7.8.7 for
    /// older games (`vnhub_main2.py`, which runs 7.8.7's `renpy.py` on the game's folder).
    /// Either way the bootstrap keeps caches out of the game's `base/`.
    @MainActor
    static func launch(gameFolder: URL, match: EngineMatch, saves: URL, cache: URL, afterGame: () -> Void) -> Never {
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        var status: Int32 = 1
        if let runtime = runtime(for: match) {
            do {
                let runner = try prepareRunner(runtime, cache: cache, gameBase: base)
                setenv("VNHUB_GAME_BASE", base.path, 1)
                setenv("VNHUB_LAUNCHER", match.details["launcher"] ?? "main.py", 1)
                setenv("VNHUB_CACHE", cache.path, 1)
                setenv("VNHUB_PATCH_GAME", gameFolder.appendingPathComponent("patch/game", isDirectory: true).path, 1)
                NSLog("VN Hub: running Ren'Py %@ game on %@", match.version ?? "?", runtime.framework)
                status = vnhub_renpy_run(runtime.framework, runner.path, "main", saves.path)
            } catch {
                NSLog("VN Hub: couldn't prepare the Ren'Py runner: %@", String(describing: error))
            }
        }
        NSLog("VN Hub: Ren'Py exited with status %d", status)
        afterGame()
        exit(status == 0 ? 0 : 1)
    }

    private static func prepareRunner(_ runtime: RenPyRuntime, cache: URL, gameBase: URL) throws -> URL {
        let fm = FileManager.default
        let runner = cache.appendingPathComponent("runner", isDirectory: true)
        let runnerBase = runner.appendingPathComponent("base", isDirectory: true)
        try? fm.removeItem(at: runner)
        try fm.createDirectory(at: runnerBase, withIntermediateDirectories: true)
        let bootstrapName: String
        if runtime.usesGameEngine {
            bootstrapName = "vnhub_main"
            try fm.createSymbolicLink(at: runnerBase.appendingPathComponent("lib"), withDestinationURL: gameBase.appendingPathComponent("lib"))
        } else {
            bootstrapName = "vnhub_main2"
            guard let engine = Bundle.main.url(forResource: "RenPy7Base", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            for name in ["lib", "renpy", "renpy.py"] {
                try fm.createSymbolicLink(at: runnerBase.appendingPathComponent(name), withDestinationURL: engine.appendingPathComponent(name))
            }
        }
        guard let bootstrap = Bundle.main.url(forResource: bootstrapName, withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fm.copyItem(at: bootstrap, to: runnerBase.appendingPathComponent("main.py"))
        return runner
    }
}
