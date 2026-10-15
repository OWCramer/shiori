// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CatSystemKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A CatSystem2 save: Shiori's own JSON in the game's `saves/` (the PC's saves come from
/// its executable's save code, which Shiori doesn't run), so iCloud syncs it but Steam Cloud
/// doesn't. It holds where the story is, the screen and the line shown. The game's own save
/// and load screens show them in its numbered slots (`CatSystemSlots`), with a thumbnail of
/// the screen (a JPEG beside the JSON).
struct CatSystemSave: Codable, Identifiable {
    var id: String { file }
    /// The file's name in `saves/` (not stored: filled in when listed).
    var file = ""
    var date: Date
    var snapshot: ScenePlayer.Snapshot
    var speaker: String?
    var text: String
    var voice: String?
    var messageIndex: Int
    var scene: String
    /// The speaker's name picture (`nametable.csv`), if the speaker has one.
    var nameID: Int?

    private enum CodingKeys: String, CodingKey { case date, snapshot, speaker, text, voice, messageIndex, scene, nameID }

    static let autosaveName = "shiori-auto.json"
    static let quickName = "shiori-quick.json"

    var isAutosave: Bool { file == Self.autosaveName }

    static func read(_ url: URL) -> CatSystemSave? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var save = try? decoder.decode(CatSystemSave.self, from: data) else { return nil }
        save.file = url.lastPathComponent
        return save
    }

    static func list(in folder: URL) -> [CatSystemSave] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("shiori-") && $0.pathExtension == "json" && $0.lastPathComponent != CatSystemSettings.fileName }
            .compactMap(read)
            .sorted { $0.date > $1.date }
    }

    func write(to folder: URL, name: String? = nil) throws -> String {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let stamp = ISO8601DateFormatter.string(from: date, timeZone: .current,
                                                formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let file = name ?? "shiori-save-\(stamp).json"
        try encoder.encode(self).write(to: folder.appendingPathComponent(file), options: .atomic)
        return file
    }
}

/// The game's save slots over Shiori's files: slots 0–79 (ten pages of eight) are
/// `shiori-slot-NNN.json`; the load screen's quick-save page (slots 400–407) shows
/// `shiori-quick.json` first, its autosave page (480–487) `shiori-auto.json`. Saves from
/// before there were slots (`shiori-save-<date>.json`) fill the free slots from No.01,
/// oldest first, and stay where they are until overwritten or deleted in the game.
struct CatSystemSlots {
    let folder: URL

    static let quickSlot = 400
    static let autoSlot = 480

    static func slotName(_ slot: Int) -> String { String(format: "shiori-slot-%03d.json", slot) }

    /// Slot → file, worked out from the folder each time it is asked (saves come and go
    /// through iCloud too).
    func files() -> [Int: String] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }
        var map: [Int: String] = [:]
        for name in names where name.hasPrefix("shiori-slot-") {
            if let n = Int(name.dropFirst("shiori-slot-".count).prefix(3)) { map[n] = name }
        }
        if names.contains(CatSystemSave.quickName) { map[Self.quickSlot] = CatSystemSave.quickName }
        if names.contains(CatSystemSave.autosaveName) { map[Self.autoSlot] = CatSystemSave.autosaveName }
        // Older saves, oldest first, into the free slots (their names sort by date).
        var free = (0..<80).filter { map[$0] == nil }.makeIterator()
        for name in names.filter({ $0.hasPrefix("shiori-save-") }).sorted() {
            guard let slot = free.next() else { break }
            map[slot] = name
        }
        return map
    }

    func save(in slot: Int) -> CatSystemSave? {
        files()[slot].flatMap { CatSystemSave.read(folder.appendingPathComponent($0)) }
    }

    func thumbnailURL(_ file: String) -> URL {
        folder.appendingPathComponent((file as NSString).deletingPathExtension + ".jpg")
    }

    /// The thumbnail as straight RGBA.
    func thumbnail(for file: String) -> (rgba: [UInt8], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(thumbnailURL(file) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
        return (rgba, w, h)
    }

    /// Writes a save into a slot (replacing whatever was there, an older save included) with
    /// its thumbnail.
    func write(_ save: CatSystemSave, slot: Int, thumbnail: CGImage?) throws {
        let name = slot == Self.quickSlot ? CatSystemSave.quickName : slot == Self.autoSlot ? CatSystemSave.autosaveName : Self.slotName(slot)
        if let old = files()[slot], old != name { delete(slot) }
        _ = try save.write(to: folder, name: name)
        let jpeg = thumbnailURL(name)
        if let thumbnail, let dest = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, thumbnail, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            CGImageDestinationFinalize(dest)
        } else {
            try? FileManager.default.removeItem(at: jpeg)
        }
    }

    func delete(_ slot: Int) {
        guard let file = files()[slot] else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(file))
        try? FileManager.default.removeItem(at: thumbnailURL(file))
    }

    // MARK: The place kept on leaving

    /// Which slot holds the place Shiori saved last on leaving, and that file's SHA-256:
    /// the slot is reused only while it still holds that save, so a save the player made
    /// over it is never overwritten. In `saves/`, so it travels with the saves through iCloud.
    private struct PlaceRecord: Codable {
        var slot: Int
        var sha256: String
        var saved: Date
    }

    static let placeRecordName = "shiori-place.json"

    /// The slot Shiori kept the place in last, if that save is still there unchanged.
    var ownedPlaceSlot: Int? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(Self.placeRecordName)),
              let record = try? JSONDecoder().decode(PlaceRecord.self, from: data),
              files()[record.slot] == Self.slotName(record.slot),
              let file = try? Data(contentsOf: folder.appendingPathComponent(Self.slotName(record.slot))),
              Self.sha256(file) == record.sha256 else { return nil }
        return record.slot
    }

    /// Where the place goes on leaving: Shiori's slot from last time while unchanged, else
    /// the first free numbered slot (the one the Load screen shows first; its page opens on
    /// the newest save). With every slot taken, the autosave.
    func placeSlot() -> Int {
        if let owned = ownedPlaceSlot { return owned }
        let map = files()
        return (0..<80).first { map[$0] == nil } ?? Self.autoSlot
    }

    /// Keeps the place in a normal slot the game's Load screen lists (`placeSlot`). Skipped
    /// when Shiori's slot already holds this line. Returns the slot, nil when skipped.
    @discardableResult
    func savePlace(_ save: CatSystemSave, thumbnail: CGImage?) throws -> Int? {
        if let owned = ownedPlaceSlot, let kept = self.save(in: owned),
           kept.scene == save.scene, kept.messageIndex == save.messageIndex, kept.text == save.text { return nil }
        let slot = placeSlot()
        try write(save, slot: slot, thumbnail: thumbnail)
        if slot != Self.autoSlot, let file = try? Data(contentsOf: folder.appendingPathComponent(Self.slotName(slot))) {
            let record = PlaceRecord(slot: slot, sha256: Self.sha256(file), saved: .now)
            try? JSONEncoder().encode(record).write(to: folder.appendingPathComponent(Self.placeRecordName), options: .atomic)
        }
        return slot
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Per-game choices that outlive a session (`saves/shiori-settings.json`): the game's own
/// CONFIG (text and auto speed, window opacity, volumes, the per-character voice volumes,
/// skip and auto behaviour, languages, chest bounciness) and the scripts' lasting variables.
/// The speeds and the four volumes Shiori had before are kept in their old form (sliders
/// 0…1), so older files read the same.
struct CatSystemSettings: Codable, Equatable {
    static let fileName = "shiori-settings.json"
    /// The game's language picker was answered once; later launches go straight to the title.
    var languageChosen = false
    /// Letters a second from 10 (0) to 300 (just under 1); 1 shows each line at once.
    var textSpeed = 0.527
    /// The CONFIG's auto speed, 0 (fastest) … 10 over 10, from 1 down.
    var autoSpeed = 0.6
    var music = 0.8
    var voice = 1.0
    var effects = 0.9
    /// The title and menu screens' own sounds.
    var system = 0.8
    var master = 1.0
    /// Voice Settings: Chocola, Vanilla, Maple, Cinnamon, Azuki, Coconut, Shigure, then
    /// everyone else, 0…1.
    var characterVoices: [Double] = Array(repeating: 1, count: 8)
    /// The rest of the game's CONFIG (`getconf` names), as the game keeps them.
    var game: [String: Int] = [:]
    /// The scripts' lasting `$n` (help balloons, which questions to confirm …), first set by
    /// `flow.fes`'s `INIT_GLOBAL`.
    var globals: [Int: Int] = [:]

    init() {}

    /// Settings added later keep their defaults in an older file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CatSystemSettings()
        languageChosen = try c.decodeIfPresent(Bool.self, forKey: .languageChosen) ?? d.languageChosen
        textSpeed = try c.decodeIfPresent(Double.self, forKey: .textSpeed) ?? d.textSpeed
        autoSpeed = try c.decodeIfPresent(Double.self, forKey: .autoSpeed) ?? d.autoSpeed
        music = try c.decodeIfPresent(Double.self, forKey: .music) ?? d.music
        voice = try c.decodeIfPresent(Double.self, forKey: .voice) ?? d.voice
        effects = try c.decodeIfPresent(Double.self, forKey: .effects) ?? d.effects
        system = try c.decodeIfPresent(Double.self, forKey: .system) ?? d.system
        master = try c.decodeIfPresent(Double.self, forKey: .master) ?? d.master
        characterVoices = try c.decodeIfPresent([Double].self, forKey: .characterVoices) ?? d.characterVoices
        if characterVoices.count < 8 { characterVoices += Array(repeating: 1, count: 8 - characterVoices.count) }
        game = try c.decodeIfPresent([String: Int].self, forKey: .game) ?? d.game
        globals = try c.decodeIfPresent([Int: Int].self, forKey: .globals) ?? d.globals
    }

    /// The CONFIG's defaults (its Reset Settings) for what Shiori didn't have before.
    static let gameDefaults: [String: Int] = [
        "fullskip": 0, "ctrlmode": 0, "autoleft": 0, "contvoice": 1, "screen": 1, "dragwnd": 0,
        "lang_ui": 0, "lang_text_main": 0, "lang_text_sub": -1, "effcut": 0, "enable_sceneanm": 1,
        "wndcolor_a": 80, "m2_iner_lv_bust": 100, "stillread": 0,
    ]

    func value(_ name: String) -> Int { game[name] ?? Self.gameDefaults[name] ?? 0 }

    /// The game's text speed: half frames a letter takes (`startup.xml`'s `strframe_frame`
    /// 5), 1…10, or 0 for a whole line at once.
    var messageSpeed: Int {
        get { lettersPerSecond.map { max(1, min(10, Int((120 / $0).rounded()))) } ?? 0 }
        set { textSpeed = newValue <= 0 ? 1 : log(120 / Double(newValue) / 10) / log(30) }
    }

    /// Letters a second, nil for a whole line at once.
    var lettersPerSecond: Double? { textSpeed >= 0.99 ? nil : 10 * pow(30, textSpeed) }

    /// The game's auto speed, 0 (fastest) … 10.
    var autoLevel: Int {
        get { max(0, min(10, Int(((1 - autoSpeed) * 10).rounded()))) }
        set { autoSpeed = 1 - Double(max(0, min(10, newValue))) / 10 }
    }

    /// `startup.xml`'s `autopriset`: for each auto speed, the wait after a line in tenths of
    /// a second and the hundredths each letter adds.
    static let autoPresets: [(base: Int, char: Int)] = [(0, 0), (3, 5), (6, 7), (12, 7), (15, 5), (16, 9), (17, 12), (21, 11), (25, 12), (29, 16), (35, 20)]

    /// Seconds Auto waits once a line of `count` letters is shown (after its voice, only the
    /// line's base wait).
    func autoWait(letters count: Int, voiced: Bool) -> Double {
        let p = Self.autoPresets[autoLevel]
        return Double(p.base) / 10 + (voiced ? 0 : Double(p.char) / 100 * Double(count))
    }

    /// The message window's opacity (`wndcolor`'s alpha, in percent).
    var windowOpacity: Int {
        get { value("wndcolor_a") }
        set { game["wndcolor_a"] = max(0, min(100, newValue)) }
    }

    /// The voice volume (0…1) for a voice file: its letter picks the character
    /// (`soundconf.xml`: A_ is Chocola … G_ Shigure; everyone else shares the last).
    func voiceLevel(_ name: String) -> Double {
        guard let first = name.uppercased().first, let ascii = first.asciiValue, first >= "A", first <= "G", name.dropFirst().first == "_" else {
            return characterVoices[7]
        }
        return characterVoices[Int(ascii - Character("A").asciiValue!)]
    }

    static func load(from folder: URL) -> CatSystemSettings {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
              let settings = try? JSONDecoder().decode(CatSystemSettings.self, from: data) else { return CatSystemSettings() }
        return settings
    }

    func save(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// The lines read in any session (`saves/shiori-read.json`), so Skip can stop at new text as
/// the game's "Read Text" skip does.
struct CatSystemReadLines {
    static let fileName = "shiori-read.json"
    private(set) var lines: Set<String> = []
    private var changed = false

    static func load(from folder: URL) -> CatSystemReadLines {
        var read = CatSystemReadLines()
        if let data = try? Data(contentsOf: folder.appendingPathComponent(fileName)),
           let list = try? JSONDecoder().decode([String].self, from: data) { read.lines = Set(list) }
        return read
    }

    func contains(scene: String, index: Int) -> Bool { lines.contains("\(scene):\(index)") }

    mutating func insert(scene: String, index: Int) {
        if lines.insert("\(scene):\(index)").inserted { changed = true }
    }

    mutating func save(to folder: URL) {
        guard changed else { return }
        changed = false
        try? JSONEncoder().encode(lines.sorted()).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// A line of the story as shown: speaker, text, voice, the speaker's name picture.
struct CatSystemLine {
    var speaker: String?
    var text: String
    var voice: String?
    var nameID: Int?
    /// The story as it was when the line showed, for the backlog's jump back.
    var save: CatSystemSave?
}
