import Foundation

/// A game's save slots: the files in its `saves/` folder that are saves the player made (or
/// the game's auto and quick saves), told apart from settings, read-text records and other
/// state each engine keeps there. Home's "Saved …" and the game page's count both come
/// from here, so they agree.
struct SaveInventory: Codable, Equatable, Sendable {
    /// Save slots in use.
    var slots: Int
    /// When the newest of them was written.
    var latest: Date?

    static let empty = SaveInventory(slots: 0, latest: nil)

    /// Reads `saves/` in a game folder for the given engine (`EngineMatch.engine`). Engines
    /// Shiori doesn't play have no known save files, so nothing counts.
    static func read(gameFolder: URL, engine: String?) -> SaveInventory {
        guard let engine else { return .empty }
        let saves = gameFolder.appendingPathComponent("saves", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: saves, includingPropertiesForKeys: Array(keys),
                                                           options: [.skipsHiddenFiles]) else { return .empty }
        var inventory = SaveInventory.empty
        // A save written as two files (KAG's data and its thumbnail) is one slot.
        var stems: Set<String> = []
        var seen = 0
        for case let url as URL in walker {
            // Shiori's conflict copies and Ren'Py's sync staging aren't the game's saves.
            if [SaveSync.conflictsFolder, "sync"].contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            seen += 1
            if seen > 5000 { break }
            guard isSlot(url.lastPathComponent, engine: engine),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            stems.insert(url.deletingPathExtension().lastPathComponent.lowercased())
            inventory.slots = stems.count
            if let date = values.contentModificationDate, inventory.latest.map({ date > $0 }) ?? true {
                inventory.latest = date
            }
        }
        return inventory
    }

    /// Whether a file in `saves/` is a save slot for this engine.
    static func isSlot(_ name: String, engine: String) -> Bool {
        let lower = name.lowercased()
        switch engine {
        case "renpy":
            // `1-1-LT1.save`, `auto-3-LT1.save`, `quick-1-LT1.save`; not `persistent`, nor
            // the `_reload-*` scratch save Ren'Py writes to reload and on leaving.
            return lower.hasSuffix(".save") && !lower.hasPrefix("_")
        case "artemis":
            // The game's own save files (`save.dat`, `autosave.dat`, numbered ones); not
            // `system.dat` (settings) or Shiori's `global.json` and `read.json`.
            return lower.hasSuffix(".dat") && lower != "system.dat"
        case "kirikiri":
            // KAG's numbered saves (`data0.kdt`, `data12.bmp` with its thumbnail); not the
            // system files `datasc.ksd` and `datasu.ksd`.
            return lower.range(of: #"^[a-z_]*\d+\.(kdt|kds|ksd|bmp|png)$"#, options: .regularExpression) != nil
        case "siglus":
            // `0001.sav`, `save001.sav`; not `global.sav`, `config.sav` or `read.sav`.
            return lower.range(of: #"^(save)?\d+\.sav$"#, options: .regularExpression) != nil
        case "luca":
            // `luca-01.json` (slot 0 is the autosave) and `luca-quick.json`; not settings,
            // extras or read lines.
            return lower.range(of: #"^luca-(\d+|quick)\.json$"#, options: .regularExpression) != nil
        case "catsystem2":
            // Slots, the quick and auto saves, and saves from before there were slots; not
            // `shiori-settings.json` or `shiori-read.json`.
            return lower.hasSuffix(".json")
                && (lower.hasPrefix("shiori-slot-") || lower.hasPrefix("shiori-save-")
                    || lower == "shiori-quick.json" || lower == "shiori-auto.json")
        default:
            return false
        }
    }
}
