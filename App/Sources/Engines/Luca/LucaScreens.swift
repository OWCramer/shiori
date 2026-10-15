import CryptoKit
import Foundation
import LucaKit

/// Shiori's saves for Luca System games: `saves/luca-NN.json` (the player's state, the line
/// on screen and the date) with `luca-NN.jpg`. Slot 0 is the autosave (the Load screen's page
/// A); the quick save is `luca-quick.json`. Leaving keeps the place in a numbered slot
/// (`savePlace`).
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

    // MARK: The place kept on leaving

    /// Which slot holds the place Shiori saved last on leaving, and that file's SHA-256: the
    /// slot is reused only while it still holds that save, so a save the player made over it
    /// is never overwritten. In `saves/`, so it travels with the saves through iCloud.
    private struct PlaceRecord: Codable {
        var slot: Int
        var sha256: String
        var saved: Date
    }

    static let placeRecordName = "shiori-place.json"

    /// The slot Shiori kept the place in last, if that save is still there unchanged.
    static func ownedPlaceSlot(in folder: URL) -> Int? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(placeRecordName)),
              let record = try? JSONDecoder().decode(PlaceRecord.self, from: data), (1...slotCount).contains(record.slot),
              let file = try? Data(contentsOf: url(slot: record.slot, in: folder)), sha256(file) == record.sha256 else { return nil }
        return record.slot
    }

    /// Keeps the place in a numbered slot the Load screen lists (and opens on, as the newest):
    /// Shiori's slot from last time while unchanged, else the first free one; with every slot
    /// taken, the autosave (slot 0, the Load screen's page A). Skipped when Shiori's slot
    /// already holds this line. Returns the slot, nil when skipped.
    @discardableResult
    static func savePlace(_ state: LucaPlayer.State, thumbnail: Data?, in folder: URL) throws -> Int? {
        let owned = ownedPlaceSlot(in: folder)
        let text = state.message.map { ($0.speaker.map { "\($0): " } ?? "") + $0.text } ?? ""
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let owned, let kept = read(slot: owned, in: folder), kept.text == text,
           (try? encoder.encode(kept.state)) == (try? encoder.encode(state)) { return nil }
        let slot = owned ?? (1...slotCount).first { !FileManager.default.fileExists(atPath: url(slot: $0, in: folder).path) } ?? 0
        try write(state, slot: slot, thumbnail: thumbnail, in: folder)
        if slot != 0, let file = try? Data(contentsOf: url(slot: slot, in: folder)) {
            let record = PlaceRecord(slot: slot, sha256: sha256(file), saved: .now)
            try? JSONEncoder().encode(record).write(to: folder.appendingPathComponent(placeRecordName), options: .atomic)
        }
        return slot
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
