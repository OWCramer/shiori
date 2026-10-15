import Foundation

/// What Shiori does with a KiriKiri game's saves. The game's own bookmarks are the player's;
/// Shiori writes none of them.
///
/// NEKO WORKs' KAG games (NEKOPARA, KARAKARA…) load an "emergency" bookmark by themselves at
/// start-up (`checkEmergencySaveData`, from the `first.init` hook: whenever
/// `savedata/data_emergency.ksd` holds a bookmark, the game jumps straight into it and then
/// empties the file). The PC game writes one only when it runs out of bitmap memory. Earlier
/// Shiori builds wrote the player's place there on leaving, and those files outlive the
/// builds: iCloud never deletes a file remotely because it is gone locally, so a moved or
/// deleted one came back with the next pull (Steam Cloud likewise), and every launch then
/// opened an old place by itself. So before the engine starts, Shiori empties any emergency
/// bookmark, as the game does once it has read one: an empty file is newer than the stale
/// copies, goes up in their place, and is read by the game as nothing to load.
enum KiriKiriSaves {
    /// TJS that writes KAG's system data (settings, read text, the bookmark list) in every KAG
    /// game. Returns "system", or "none" outside KAG.
    static let systemDataTJS = """
        (function() {
            if (typeof global.kag != "Object" || !isvalid kag) return "none";
            if (typeof kag.saveSystemVariables != "Object") return "none";
            kag.saveSystemVariables();
            return "system";
        })()
        """

    /// Empties every emergency bookmark (`*_emergency.ksd`) in the game's `saves/`, so the game
    /// never loads one by itself at start-up. Returns the names it emptied.
    @discardableResult
    static func clearEmergencyBookmarks(saves: URL) -> [String] {
        let fileManager = FileManager.default
        let names = (try? fileManager.contentsOfDirectory(atPath: saves.path)) ?? []
        var cleared: [String] = []
        for name in names where name.lowercased().hasSuffix("_emergency.ksd") {
            let url = saves.appendingPathComponent(name)
            let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            guard size > 0, (try? Data().write(to: url)) != nil else { continue }
            cleared.append(name)
        }
        return cleared
    }

    /// Before the engine starts: emergency bookmarks emptied (see above), and the resume files
    /// earlier Shiori builds kept beside them deleted (ResumeLeftovers; the game never reads
    /// them). Returns a line for the log, or nil when there was nothing to do.
    static func prepareForStart(gameFolder: URL) -> String? {
        let saves = gameFolder.appendingPathComponent("saves", isDirectory: true)
        let cleared = clearEmergencyBookmarks(saves: saves)
        let removed = ["shiori-resume.bkm", "data_emergency-shiori.ksd"].filter {
            (try? FileManager.default.removeItem(at: saves.appendingPathComponent($0))) != nil
        }
        var parts: [String] = []
        if !cleared.isEmpty { parts.append("emptied \(cleared.joined(separator: ", ")) so the game doesn't load it by itself") }
        if !removed.isEmpty { parts.append("removed \(removed.joined(separator: ", "))") }
        return parts.isEmpty ? nil : "Saves: " + parts.joined(separator: "; ")
    }
}
