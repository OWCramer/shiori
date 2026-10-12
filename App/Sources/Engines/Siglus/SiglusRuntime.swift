import Foundation
import OSLog

/// Prepares a Siglus game for siglus_rs (MPL-2.0, linked as ShioriSiglus.framework).
///
/// The engine reads and writes its game root: `savedata/` beside the scripts, and `key.toml`,
/// where it caches the secondary key it recovers from the game's data. Shiori keeps `base/` as
/// Steam delivered it, so the engine runs on a runner folder in Caches instead: links to
/// everything in `base/` with `patch/` laid over it, `savedata` pointing at the game's
/// `saves/`, and the engine's own `key.toml`.
enum SiglusRuntime {
    static let log = Logger(subsystem: "com.owencramer.vnhub", category: "Siglus")

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// Files the engine writes into its root, kept in the runner between launches.
    private static let engineFiles: Set<String> = ["key.toml"]

    /// The runner folder for `gameFolder` (one holding `base/`, `patch/` and `saves/`).
    static func prepareRoot(gameFolder: URL) throws -> URL {
        let fileManager = FileManager.default
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        let baseNames = (try? fileManager.contentsOfDirectory(atPath: base.path)) ?? []
        let language = languageSuffix(in: baseNames)
        guard baseNames.contains(where: { $0.lowercased() == "scene.pck" }) || language != nil else {
            throw Failure(errorDescription: "This game's Scene.pck is missing. Verify the game from its page.")
        }
        let saves = gameFolder.appendingPathComponent("saves", isDirectory: true)
        try fileManager.createDirectory(at: saves, withIntermediateDirectories: true)
        let root = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Siglus/\(gameFolder.lastPathComponent)/game", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        // Fresh links each launch (patches may have changed), keeping what the engine wrote.
        for name in try fileManager.contentsOfDirectory(atPath: root.path) where !engineFiles.contains(name) {
            try fileManager.removeItem(at: root.appendingPathComponent(name))
        }
        let patch = gameFolder.appendingPathComponent("patch", isDirectory: true)
        try LayeredGameRoot.overlay(base: base, patch: fileManager.fileExists(atPath: patch.path) ? patch : nil, into: root,
                    skipping: engineFiles.union(["savedata"]))
        try fileManager.createSymbolicLink(at: root.appendingPathComponent("savedata"), withDestinationURL: saves)
        // Games ask for MS Gothic, a Windows font, and lay text out in its fixed half-width
        // cells; siglus_rs falls back to a proportional font that leaves gaps between narrow
        // letters. BIZ UDGothic is made to stand in for it. The engine looks in font/ first.
        if !baseNames.contains(where: { ["font", "fonts"].contains($0.lowercased()) }),
           let fonts = Bundle.main.url(forResource: "SiglusFonts", withExtension: nil) {
            try fileManager.createSymbolicLink(at: root.appendingPathComponent("font"), withDestinationURL: fonts)
        }
        // Multilingual Steam builds name their scripts and settings by language, and their
        // launcher picks one; the engine reads Scene.pck and Gameexe.dat.
        // The game asks the engine which language it runs in (SYSTEM.GET_LANGUAGE) and picks
        // its menu art by it (S_TT_MENU00_EN.g00 ...); siglus_rs answers SIGLUS_LANGUAGE.
        setenv("SIGLUS_LANGUAGE", (language ?? "JP").uppercased(), 1)
        if let language {
            for (plain, suffixed) in [("Scene.pck", "Scene\(language).pck"), ("Gameexe.dat", "Gameexe\(language).dat")]
            where !baseNames.contains(where: { $0.lowercased() == plain.lowercased() }) {
                if let match = baseNames.first(where: { $0.lowercased() == suffixed.lowercased() }) {
                    try fileManager.createSymbolicLink(at: root.appendingPathComponent(plain),
                                                       withDestinationURL: root.appendingPathComponent(match))
                }
            }
            log.notice("Playing the \(language, privacy: .public) scripts of \(gameFolder.lastPathComponent, privacy: .public)")
        }
        return root
    }

    /// The language to play when the game has no plain Scene.pck, only Scene<language>.pck
    /// files: English first, then the device's language, then the first there is.
    private static func languageSuffix(in names: [String]) -> String? {
        let available = names.compactMap { name -> String? in
            let lower = name.lowercased()
            guard lower.hasPrefix("scene"), lower.hasSuffix(".pck"), lower != "scene.pck" else { return nil }
            return String(name.dropFirst(5).dropLast(4))
        }
        guard !available.isEmpty else { return nil }
        let preferred = ["EN"] + Locale.preferredLanguages.map { String($0.prefix(2)).uppercased() }
        for code in preferred {
            if let match = available.first(where: { $0.uppercased() == code }) { return match }
        }
        return available.sorted().first
    }
}
