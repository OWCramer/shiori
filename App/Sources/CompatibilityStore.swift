// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// The public compatibility list (github.com/OWCramer/shiori-compatibility): one JSON file per
/// engine, each game's status, notes and how it was tested. Fetched from GitHub's raw files
/// (no account, nothing sent but the request), kept in Caches for offline use, and refreshed
/// at most every six hours.
@MainActor
@Observable
final class CompatibilityStore {
    struct Entry: Decodable, Sendable {
        var appID: UInt32
        var name: String
        var status: Status
        var tested: String?
        var source: String?
        var devices: [String]?
        var branch: String?
        var profile: String?
        var notes: String?
        /// The game's title in GARbro's database, for KiriKiri games whose archives use CxDec.
        var garbro: String?
    }

    enum Status: String, Decodable, Sendable {
        case unsupported, boots, plays, complete
    }

    private struct EngineFile: Decodable {
        var engine: String
        var name: String
        var games: [Entry]
    }

    static let repository = URL(string: "https://github.com/OWCramer/shiori-compatibility")!
    private static let raw = URL(string: "https://raw.githubusercontent.com/OWCramer/shiori-compatibility/main/engines/")!
    private static let engines = ["renpy", "kirikiri", "artemis", "siglus", "luca"]
    private static let refreshInterval: TimeInterval = 6 * 3600

    /// Entries by Steam app id, with the engine file's display name.
    private(set) var entries: [UInt32: (entry: Entry, engine: String)] = [:]
    private var refreshing = false

    private let folder = CompatibilityStore.cachesDirectory.appendingPathComponent("compatibility", isDirectory: true)

    nonisolated private static var cachesDirectory: URL {
        #if DEBUG
        ScreenshotLibrary.cachesDirectory()
        #else
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #endif
    }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for engine in Self.engines {
            if let data = try? Data(contentsOf: file(engine)) { absorb(data) }
        }
    }

    func entry(for appID: UInt32) -> (entry: Entry, engine: String)? { entries[appID] }

    /// An engine's entry for a game from the cached copy on disk, for callers off the main actor.
    nonisolated static func cachedEntry(appID: UInt32, engine: String) -> Entry? {
        let file = cachesDirectory.appendingPathComponent("compatibility/\(engine).json")
        guard let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode(EngineFile.self, from: data) else { return nil }
        return list.games.first { $0.appID == appID }
    }

    /// Fetches the list again when the cached copy is older than six hours (or `force`).
    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        #if DEBUG
        if ScreenshotLibrary.isOn { return }
        #endif
        let stamp = (try? file("renpy").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force, let stamp, Date().timeIntervalSince(stamp) < Self.refreshInterval { return }
        refreshing = true
        defer { refreshing = false }
        for engine in Self.engines {
            var request = URLRequest(url: Self.raw.appendingPathComponent("\(engine).json"))
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONDecoder().decode(EngineFile.self, from: data)) != nil else { continue }
            try? data.write(to: file(engine), options: .atomic)
            absorb(data)
        }
    }

    private func file(_ engine: String) -> URL { folder.appendingPathComponent("\(engine).json") }

    private func absorb(_ data: Data) {
        guard let file = try? JSONDecoder().decode(EngineFile.self, from: data) else { return }
        for game in file.games { entries[game.appID] = (game, file.name) }
    }
}
