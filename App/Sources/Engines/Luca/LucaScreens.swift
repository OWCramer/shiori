import LucaKit
import Foundation

/// Shiori's saves for Luca System games: `saves/luca-NN.json` (the player's state, the line
/// on screen and the date) with `luca-NN.jpg`. Slot 0 is the autosave made on leaving; the
/// quick save is `luca-quick.json`.
enum LucaSaves {
    struct Save: Codable {
        var date: Date
        var text: String
        var state: LucaPlayer.State
    }

    static func url(slot: Int, in folder: URL, ext: String = "json") -> URL {
        if slot == quickSlot { return folder.appendingPathComponent("luca-quick.\(ext)") }
        return folder.appendingPathComponent(String(format: "luca-%02d.%@", slot, ext))
    }

    static func write(_ state: LucaPlayer.State, slot: Int, thumbnail: Data?, in folder: URL) throws {
        let text = state.message.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text } ?? ""
        let data = try JSONEncoder().encode(Save(date: .now, text: text, state: state))
        try data.write(to: url(slot: slot, in: folder), options: .atomic)
        if let thumbnail { try? thumbnail.write(to: url(slot: slot, in: folder, ext: "jpg"), options: .atomic) }
    }

    static func read(slot: Int, in folder: URL) -> Save? {
        guard let data = try? Data(contentsOf: url(slot: slot, in: folder)) else { return nil }
        return try? JSONDecoder().decode(Save.self, from: data)
    }

    static func latest(in folder: URL) -> Save? {
        ((0...slotCount) + [quickSlot]).compactMap { read(slot: $0, in: folder) }.max { $0.date < $1.date }
    }

    /// 15 pages of 8 on the save screen.
    static let slotCount = 120
    /// Q.SAVE / Q.LOAD's slot, apart from the numbered ones (its own file, `luca-quick.json`).
    /// Until 2026-10-11 it was slot 99, which is also No.099 on the save screen, and nothing
    /// recorded which wrote `luca-99.json`; such a file stays where it is and shows as No.099,
    /// and the quick save starts empty.
    static let quickSlot = -1
}
