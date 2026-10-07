import Foundation
import Observation

/// Artwork the user picked from SteamGridDB, per game and kind. Steam's own art is used for
/// anything without a pick.
@MainActor @Observable
final class ArtworkStore {
    private(set) var picks: [UInt32: [SteamGridDB.Kind: URL]] = [:]

    private static var url: URL { URL.applicationSupportDirectory.appendingPathComponent("artwork.json") }

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String: [String: URL]].self, from: data)
        {
            for (appID, kinds) in saved {
                guard let appID = UInt32(appID) else { continue }
                picks[appID] = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind, url in
                    SteamGridDB.Kind(rawValue: kind).map { ($0, url) }
                })
            }
        }
    }

    func pick(_ kind: SteamGridDB.Kind, for appID: UInt32) -> URL? { picks[appID]?[kind] }

    func set(_ url: URL?, kind: SteamGridDB.Kind, for appID: UInt32) {
        picks[appID, default: [:]][kind] = url
        if picks[appID]?.isEmpty == true { picks[appID] = nil }
        save()
    }

    /// The game with its picked artwork in place of Steam's.
    func apply(to game: LibraryGame) -> LibraryGame {
        guard let picked = picks[game.appID] else { return game }
        var game = game
        if let grid = picked[.grid] {
            game.capsule = grid
            game.capsuleLarge = grid
        }
        if let hero = picked[.hero] { game.hero = hero }
        if let logo = picked[.logo] { game.logo = logo }
        return game
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: picks.map { appID, kinds in
            (String(appID), Dictionary(uniqueKeysWithValues: kinds.map { ($0.key.rawValue, $0.value) }))
        })
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(encodable).write(to: Self.url, options: .atomic)
    }
}
