import CatSystemKit
import SwiftUI

/// A CatSystem2 save: Shiori's own JSON in the game's `saves/` (the PC's saves come from
/// its executable's save code, which Shiori doesn't run), so iCloud syncs it but Steam Cloud
/// doesn't. It holds where the story is, the screen and the line shown.
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

    private enum CodingKeys: String, CodingKey { case date, snapshot, speaker, text, voice, messageIndex, scene }

    static let autosaveName = "shiori-auto.json"

    var isAutosave: Bool { file == Self.autosaveName }

    static func list(in folder: URL) -> [CatSystemSave] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasPrefix("shiori-") && $0.pathExtension == "json" && $0.lastPathComponent != CatSystemSettings.fileName }
            .compactMap { url -> CatSystemSave? in
                guard let data = try? Data(contentsOf: url), var save = try? decoder.decode(CatSystemSave.self, from: data) else { return nil }
                save.file = url.lastPathComponent
                return save
            }
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

/// Per-game choices that outlive a session (`saves/shiori-settings.json`): the CONFIG
/// screen's text speed, auto speed and volumes (sliders 0…1, as the game's own CONFIG has
/// them), and whether the language picker was answered.
struct CatSystemSettings: Codable, Equatable {
    static let fileName = "shiori-settings.json"
    /// The game's language picker was answered once; later launches go straight to the title.
    var languageChosen = false
    /// Letters a second from 10 (0) to 300 (just under 1); 1 shows each line at once. The
    /// default is the 60 a second the story used before there was a setting.
    var textSpeed = 0.527
    /// Auto mode's wait after a line (and its voice): 3 seconds (0) to a quarter (1).
    var autoSpeed = 0.5
    var music = 0.7
    var voice = 1.0
    var effects = 0.8
    /// The title and menu screens' own sounds.
    var system = 0.8

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
    }

    /// Letters a second, nil for a whole line at once.
    var lettersPerSecond: Double? { textSpeed >= 0.99 ? nil : 10 * pow(30, textSpeed) }

    /// Seconds Auto waits once a line of `count` letters is shown and its voice has ended.
    func autoWait(letters count: Int) -> Double {
        let slow = 1 - autoSpeed
        return 0.25 + 2.75 * slow + 0.03 * slow * Double(count)
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

/// Shiori's CONFIG for a CatSystem2 game: the settings the game's own CONFIG screen has that
/// matter on a phone (text and auto speed, volumes), changed live. The game's screen
/// (`config.fes`) needs FES features Shiori's interpreter doesn't have yet (sliders, virtual
/// planes, the engine's sound settings), so this stands in for it.
struct CatSystemConfig: View {
    @State var settings: CatSystemSettings
    let onChange: (CatSystemSettings) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Text") {
                    slider("Text speed", \.textSpeed, low: "Slow", high: "Instant")
                    slider("Auto speed", \.autoSpeed, low: "Slow", high: "Fast")
                }
                Section("Volume") {
                    slider("Music", \.music)
                    slider("Voices", \.voice)
                    slider("Sound effects", \.effects)
                    slider("System sounds", \.system)
                }
                Section {
                    Button("Reset to Defaults") {
                        let chosen = settings.languageChosen
                        settings = CatSystemSettings()
                        settings.languageChosen = chosen
                    }
                }
            }
            .navigationTitle("Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
            .onChange(of: settings) { _, new in onChange(new) }
        }
    }

    private func slider(_ title: String, _ key: WritableKeyPath<CatSystemSettings, Double>, low: String? = nil, high: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(key == \CatSystemSettings.textSpeed && settings.textSpeed >= 0.99 ? "Instant" : "\(Int((settings[keyPath: key] * 100).rounded()))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(get: { settings[keyPath: key] }, set: { settings[keyPath: key] = $0 }), in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Text(low ?? "").font(.caption)
            } maximumValueLabel: {
                Text(high ?? "").font(.caption)
            }
        }
    }
}

/// Load (and delete) saves: newest first, the autosave marked.
struct CatSystemLoadList: View {
    let folder: URL
    let onPick: (CatSystemSave) -> Void
    let onClose: () -> Void
    @State private var saves: [CatSystemSave] = []

    var body: some View {
        NavigationStack {
            Group {
                if saves.isEmpty {
                    ContentUnavailableView("No Saves", systemImage: "tray",
                                           description: Text("Two-finger tap during the story and choose Save."))
                } else {
                    List {
                        ForEach(saves) { save in
                            Button { onPick(save) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(save.isAutosave ? "Autosave" : save.date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.headline)
                                        Spacer()
                                        Text("Scene \(save.scene)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text((save.speaker.map { "\($0): " } ?? "") + save.text)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            for i in offsets { try? FileManager.default.removeItem(at: folder.appendingPathComponent(saves[i].file)) }
                            saves.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Load")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) }
            }
        }
        .onAppear { saves = CatSystemSave.list(in: folder) }
    }
}

/// A line of the story as shown: speaker, English text, voice.
struct CatSystemLine {
    var speaker: String?
    var text: String
    var voice: String?
}

/// The lines read so far this session, newest at the bottom.
struct CatSystemBacklog: View {
    let lines: [CatSystemLine]
    let onVoice: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            if let speaker = line.speaker {
                                Text(speaker).font(.caption.weight(.semibold)).foregroundStyle(.orange)
                            }
                            Text(line.text).font(.body)
                        }
                        Spacer()
                        if let voice = line.voice {
                            Button { onVoice(voice) } label: { Image(systemName: "speaker.wave.2") }
                                .buttonStyle(.borderless)
                        }
                    }
                    .id(index)
                }
                .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
            }
            .navigationTitle("Backlog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
    }
}
