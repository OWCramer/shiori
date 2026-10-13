import GameController
import UIKit

/// Keeping a KiriKiri player's place between sessions, for both KiriKiri engines (Standard
/// and Shiori's own).
///
/// NEKO WORKs' KAG games (NEKOPARA, KARAKARA…) resume from an "emergency" bookmark at
/// start-up, the one the game itself writes when it runs out of memory on the PC. Shiori used
/// to write its leave-the-game place there, so every launch jumped straight back into the
/// story. Now Shiori keeps its place in a file of its own beside the game's saves
/// (`shiori-resume.bkm`, which the game never reads), and when one is waiting, asks once at
/// launch "Resume where you left off?". On Resume it's copied into the emergency bookmark just
/// before the engine starts, so the game's own start-up recovery loads it (the game then
/// empties that bookmark as it always does). An emergency bookmark the game wrote itself is
/// left alone, as the game expects.
@MainActor
enum KiriKiriResume {
    static let fileName = "shiori-resume.bkm"

    private static func key(_ name: String, _ gameFolder: URL) -> String {
        "kirikiriResume.\(name).\(gameFolder.lastPathComponent)"
    }

    private static func saves(_ gameFolder: URL) -> URL {
        gameFolder.appendingPathComponent("saves", isDirectory: true)
    }

    static func resumeURL(gameFolder: URL) -> URL { saves(gameFolder).appendingPathComponent(fileName) }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
    }

    /// The game's emergency bookmark's file name (learned from the game when Shiori saves;
    /// NEKO WORKs games call it `data_emergency.ksd`).
    private static func emergencyName(_ gameFolder: URL) -> String {
        UserDefaults.standard.string(forKey: key("emergencyName", gameFolder)) ?? "data_emergency.ksd"
    }

    /// Before the engine starts: the place to offer, if a resume save newer than the last one
    /// offered here is waiting. The first time, an emergency bookmark left by an earlier
    /// Shiori (which wrote its place there) becomes the resume save instead.
    static func offer(gameFolder: URL) -> Date? {
        let defaults = UserDefaults.standard
        let fileManager = FileManager.default
        let resume = resumeURL(gameFolder: gameFolder)
        if !defaults.bool(forKey: key("migrated", gameFolder)) {
            defaults.set(true, forKey: key("migrated", gameFolder))
            let emergency = saves(gameFolder).appendingPathComponent(emergencyName(gameFolder))
            // A real bookmark (the game empties it to a few bytes once resumed).
            if size(emergency) > 64, (modified(resume) ?? .distantPast) < (modified(emergency) ?? .distantPast) {
                try? fileManager.removeItem(at: resume)
                if (try? fileManager.moveItem(at: emergency, to: resume)) != nil {
                    defaults.set((modified(resume) ?? .now).timeIntervalSince1970 - 1, forKey: key("offered", gameFolder))
                }
            }
            // The temporary name an earlier Shiori wrote through.
            try? fileManager.removeItem(at: saves(gameFolder).appendingPathComponent("data_emergency-shiori.ksd"))
        }
        guard size(resume) > 64, let date = modified(resume) else { return nil }
        return date.timeIntervalSince1970 > defaults.double(forKey: key("offered", gameFolder)) ? date : nil
    }

    /// The question has been asked for this resume save: not again on this device.
    static func markOffered(_ date: Date, gameFolder: URL) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: key("offered", gameFolder))
    }

    /// The player chose Resume: the place goes where the game's start-up recovery reads it.
    /// Never over a bookmark the game wrote itself.
    static func useOnStart(gameFolder: URL) {
        let emergency = saves(gameFolder).appendingPathComponent(emergencyName(gameFolder))
        guard size(emergency) <= 64 else { return }
        try? FileManager.default.removeItem(at: emergency)
        try? FileManager.default.copyItem(at: resumeURL(gameFolder: gameFolder), to: emergency)
    }

    /// Whether the game can keep its place now: KAG games with NEKO WORKs' emergency resume,
    /// in the story (not the title or a scene replay) where the game allows a bookmark.
    static let canKeepPlaceTJS = """
        (typeof global.kag == "Object" && typeof global.checkEmergencySaveData == "Object" \
        && typeof global.inGameState == "Object" && typeof kag.getBookMarkFileNameBySystem == "Object" \
        && inGameState(kag) && (typeof kag.canStore != "Object" || kag.canStore())) ? 1 : 0
        """

    /// TJS that keeps the place in Shiori's resume save (in the story) and writes KAG's
    /// system data (settings, read text, the bookmark index) in every KAG game. Returns
    /// "kept\t<emergency file name>", "outside", "failed" or "system"/"none".
    static let saveTJS = """
        (function() {
            if (typeof global.kag != "Object" || !isvalid kag) return "none";
            var result = "system";
            if (\(canKeepPlaceTJS)) {
                var emergency = kag.getBookMarkFileNameBySystem("emergency");
                var file = Storages.extractStoragePath(emergency) + "\(fileName)";
                result = kag.saveBookMarkToFile(file) ? "kept\\t" + Storages.extractStorageName(emergency) : "failed";
            } else if (typeof global.checkEmergencySaveData == "Object") {
                result = "outside";
            }
            if (typeof kag.saveSystemVariables == "Object") kag.saveSystemVariables();
            return result;
        })()
        """

    /// After saveTJS ran: remembers the emergency bookmark's name, and that this device's own
    /// place is to be offered at the next launch. Returns a line for the log.
    static func saved(_ result: String, gameFolder: URL) -> String {
        let parts = result.components(separatedBy: "\t")
        switch parts.first {
        case "kept":
            if parts.count == 2, !parts[1].isEmpty {
                UserDefaults.standard.set(parts[1], forKey: key("emergencyName", gameFolder))
            }
            if let date = modified(resumeURL(gameFolder: gameFolder)) {
                UserDefaults.standard.set(date.timeIntervalSince1970 - 1, forKey: key("offered", gameFolder))
            }
            return "Kept the place (Shiori's resume save) and system data"
        case "failed":
            return "The game couldn't write Shiori's resume save"
        case "outside":
            return "Wrote the system data (no place outside the story)"
        default:
            return "Wrote the system data (\(result))"
        }
    }

    /// Asks "Resume where you left off?" over `controller`; `answer(true)` for Resume.
    static func ask(_ date: Date, over controller: UIViewController, answer: @escaping (Bool) -> Void) -> UIAlertController {
        let when = date.formatted(.relative(presentation: .named))
        let alert = UIAlertController(title: "Resume where you left off?",
                                      message: "Saved \(when)."
                                          + (GCController.current?.extendedGamepad != nil ? " Ⓐ Resume, Ⓑ Not Now." : ""),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel) { _ in answer(false) })
        alert.addAction(UIAlertAction(title: "Resume", style: .default) { _ in answer(true) })
        controller.present(alert, animated: true)
        return alert
    }
}
