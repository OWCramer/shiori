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

/// A Ren'Py runtime Shiori ships (Scripts/build-renpy-runtimes.sh): one per Python.
struct RenPyRuntime: Equatable, Sendable {
    /// Framework name in the app bundle.
    let framework: String
    let version: String
    let python: String
    /// The runtime's own engine code and Python library in the app bundle, for games whose
    /// own engine code can't run on it; nil when the game runs on its own `renpy/`.
    var bundledEngine: String? = nil

    /// Ren'Py 8.1.3 on CPython 3.9, Highway Blossoms' version. Runs Ren'Py 8 games with the
    /// game's own engine code.
    static let renpy8 = RenPyRuntime(framework: "RenPy8", version: "8.1.3", python: "3")
    /// Ren'Py 7.8.7 on CPython 2.7. Runs Ren'Py 6.10–7.x games with its own engine code
    /// (bundled as RenPy7Base), since the games' older engine can't load its compiled modules.
    static let renpy7 = RenPyRuntime(framework: "RenPy7", version: "7.8.7", python: "2", bundledEngine: "RenPy7Base")
    /// Ren'Py 8.1.3 with its own engine code (bundled as RenPy8Base), for Ren'Py 8.0 games:
    /// their engine code expects 8.0's compiled modules (8.1 renamed and changed some), and
    /// 8.1 plays 8.0 games.
    static let renpy8Bundled = RenPyRuntime(framework: "RenPy8", version: "8.1.3", python: "3", bundledEngine: "RenPy8Base")

    static let all = [renpy8, renpy7]

    /// Whether the game runs on its own `renpy/` folder or on the runtime's.
    var usesGameEngine: Bool { bundledEngine == nil }
}

extension RenPyEngine {
    /// Shown in Settings.
    static var runtimeVersion: String { RenPyRuntime.all.map(\.version).joined(separator: ", ") }

    /// The runtime a game runs on, or nil.
    static func runtime(for match: EngineMatch) -> RenPyRuntime? {
        guard let version = match.version, let major = version.split(separator: ".").first.flatMap({ Int($0) }) else { return nil }
        let python = match.details["python"] ?? (major >= 8 ? "3" : "2")
        switch (major, python) {
        case (8, "3"):
            // 8.1 and newer on their own engine; 8.0 on 8.1.3's.
            let minor = version.split(separator: ".").dropFirst().first.flatMap { Int($0) } ?? 1
            return minor >= 1 ? .renpy8 : .renpy8Bundled
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
        if runtime(for: match) == nil {
            return "This game uses Ren'Py \(version), which Shiori can't run."
        }
        // Ren'Py 7.8 loads compiled scripts back to the 6.1x generation, given the default
        // shiori_main2.py adds for the Translate statement's `alternate` slot (6.17 and 6.18
        // games play: WORLD END ECONOMiCA episode.01's renpy_old beta, Sakura Swim Club).
        // Older formats aren't known to work.
        if major == 6, let minor = version.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), minor < 10 {
            return "This game uses Ren'Py \(version); Shiori runs Ren'Py 6.10 and newer."
        }
        return nil
    }

    /// Whether a game runs with Ren'Py's phone screens ("small", "touch", "mobile"
    /// variants). Off by default: these are PC builds, and most never designed phone
    /// screens, so Ren'Py would fall back to its template's leftovers.
    @MainActor
    static func usesPhoneLayout(appID: UInt32) -> Bool {
        SyncedPreferences.phoneLayout(appID: appID)
    }

    @MainActor
    static func setPhoneLayout(_ enabled: Bool, appID: UInt32) {
        SyncedPreferences.setPhoneLayout(enabled, appID: appID)
    }

    /// Runs the game in this process until it quits and returns Ren'Py's exit status. CPython
    /// can't be restarted cleanly in-process, so the app closes after the game (GameLibrary
    /// syncs saves first); playing again means reopening Shiori.
    ///
    /// Ren'Py's launcher is pointed at a runner folder whose `base/main.py` is Shiori's
    /// bootstrap and whose `base/lib` is the Python library: the game's own for Ren'Py 8
    /// (`shiori_main.py`, which then runs the game's launcher), Shiori's Ren'Py 7.8.7 for
    /// older games (`shiori_main2.py`, which runs 7.8.7's `renpy.py` on the game's folder).
    /// Either way the bootstrap keeps caches out of the game's `base/`.
    /// Statuses for a game that never started (CPython untouched, so the app can stay open):
    /// the runner folder couldn't be made, or the runtime framework didn't load
    /// (`shiori_renpy_run`'s -2).
    static let notStarted: Int32 = -3
    static let runtimeNotLoaded: Int32 = -2

    /// The last session's note (`last-game-session.json`): how it ended, with Ren'Py's error.
    static func lastSessionError() -> String? {
        guard let data = try? Data(contentsOf: URL.shioriSupport.appendingPathComponent("last-game-session.json")),
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = note["error"] as? String, !error.isEmpty else { return nil }
        return error
    }

    @MainActor
    static func launch(appID: UInt32, gameFolder: URL, match: EngineMatch, saves: URL, cache: URL) -> Int32 {
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        var status: Int32 = 1
        var setupError = ""
        if let runtime = runtime(for: match) {
            do {
                let runner = try prepareRunner(runtime, cache: cache, gameBase: base)
                setenv("SHIORI_GAME_BASE", base.path, 1)
                setenv("SHIORI_LAUNCHER", match.details["launcher"] ?? "main.py", 1)
                setenv("SHIORI_CACHE", cache.path, 1)
                if usesPhoneLayout(appID: appID) {
                    unsetenv("RENPY_VARIANT")
                } else {
                    // The screen variants Ren'Py picks on a PC.
                    setenv("RENPY_VARIANT", "large pc", 1)
                }
                // SDL drops controller input whenever it thinks no window has keyboard focus,
                // which its iOS backend doesn't always record for our scene-attached window.
                setenv("SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS", "1", 1)
                setenv("SHIORI_PATCH_GAME", gameFolder.appendingPathComponent("patch/game", isDirectory: true).path, 1)
                NSLog("Shiori: running Ren'Py %@ game on %@", match.version ?? "?", runtime.framework)
                status = shiori_renpy_run(runtime.framework, runner.path, "main", saves.path)
            } catch {
                NSLog("Shiori: couldn't prepare the Ren'Py runner: %@", String(describing: error))
                setupError = "Couldn't prepare the game: \((error as NSError).localizedDescription)"
                status = notStarted
            }
        }
        NSLog("Shiori: Ren'Py exited with status %d", status)
        // A game quitting closes the app (v1), which can look like a crash; keep a note of
        // how the last session ended, with Ren'Py's own error if there was one.
        let note: [String: Any] = [
            "appID": appID, "status": Int(status), "ended": ISO8601DateFormatter().string(from: .now),
            "runtime": runtime(for: match)?.framework ?? "none",
            "error": setupError.isEmpty ? (try? String(contentsOf: cache.appendingPathComponent("last_error.txt"), encoding: .utf8)) ?? "" : setupError,
            "exit": (try? String(contentsOf: cache.appendingPathComponent("exit.txt"), encoding: .utf8)) ?? "",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL.shioriSupport.appendingPathComponent("last-game-session.json"))
        }
        return status
    }

    private static func prepareRunner(_ runtime: RenPyRuntime, cache: URL, gameBase: URL) throws -> URL {
        let fm = FileManager.default
        let runner = cache.appendingPathComponent("runner", isDirectory: true)
        let runnerBase = runner.appendingPathComponent("base", isDirectory: true)
        try? fm.removeItem(at: runner)
        try? fm.removeItem(at: cache.appendingPathComponent("last_error.txt"))
        try fm.createDirectory(at: runnerBase, withIntermediateDirectories: true)
        let bootstrapName: String
        if runtime.usesGameEngine {
            bootstrapName = "shiori_main"
            try place(runnerBase.appendingPathComponent("lib"), from: gameBase.appendingPathComponent("lib"),
                      only: { $0.hasPrefix("python") })
        } else {
            bootstrapName = "shiori_main2"
            guard let engine = Bundle.main.url(forResource: runtime.bundledEngine, withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            for name in ["lib", "renpy", "renpy.py"] {
                try place(runnerBase.appendingPathComponent(name), from: engine.appendingPathComponent(name))
            }
        }
        guard let bootstrap = Bundle.main.url(forResource: bootstrapName, withExtension: "py") else {
            throw CocoaError(.fileNoSuchFile)
        }
        try fm.copyItem(at: bootstrap, to: runnerBase.appendingPathComponent("main.py"))
        return runner
    }

    /// Puts `source` at `destination` in the runner: a symbolic link, or where the system
    /// refuses one (tvOS doesn't let apps make links), a copy, which APFS makes as a clone
    /// on the same volume. `only` limits a copied folder to the entries Python needs (the
    /// launcher reads `lib/python*`; a game's `lib/` also carries its PC binaries).
    private static func place(_ destination: URL, from source: URL, only: ((String) -> Bool)? = nil) throws {
        let fm = FileManager.default
        do {
            try fm.createSymbolicLink(at: destination, withDestinationURL: source)
        } catch let error as CocoaError where error.code == .fileWriteNoPermission {
            var isFolder: ObjCBool = false
            if let only, fm.fileExists(atPath: source.path, isDirectory: &isFolder), isFolder.boolValue {
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                for name in try fm.contentsOfDirectory(atPath: source.path) where only(name) {
                    try fm.copyItem(at: source.appendingPathComponent(name), to: destination.appendingPathComponent(name))
                }
            } else {
                try fm.copyItem(at: source, to: destination)
            }
        }
    }
}
