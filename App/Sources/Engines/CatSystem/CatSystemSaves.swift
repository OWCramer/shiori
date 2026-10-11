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

/// Per-game choices that outlive a session (`saves/shiori-settings.json`).
struct CatSystemSettings: Codable {
    static let fileName = "shiori-settings.json"
    /// The game's language picker was answered once; later launches go straight to the title.
    var languageChosen = false

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
