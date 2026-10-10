import Foundation
import Observation

/// Artwork the user picked from SteamGridDB, per game and kind, kept in iCloud Keychain so his
/// other devices show the same art. Steam's own art is used for anything without a pick.
@MainActor @Observable
final class ArtworkStore {
    private(set) var picks: [UInt32: [SteamGridDB.Kind: URL]] = [:]

    private static let account = "artwork"
    /// Where picks lived before they synced (this device only).
    private static var legacyURL: URL { URL.shioriSupport.appendingPathComponent("artwork.json") }

    init() {
        picks = Self.decode(SyncedKeychain.value([String: [String: URL]].self, account: Self.account) ?? [:])
        // Picks from before syncing join what other devices saved, once; this device's win.
        if let data = try? Data(contentsOf: Self.legacyURL),
           let saved = try? JSONDecoder().decode([String: [String: URL]].self, from: data)
        {
            for (appID, kinds) in Self.decode(saved) { picks[appID, default: [:]].merge(kinds) { _, local in local } }
            save()
            try? FileManager.default.removeItem(at: Self.legacyURL)
        }
    }

    /// Picks up changes made on another device (on returning to the foreground).
    func reload() {
        let synced = Self.decode(SyncedKeychain.value([String: [String: URL]].self, account: Self.account) ?? [:])
        if synced != picks { picks = synced }
    }

    private static func decode(_ saved: [String: [String: URL]]) -> [UInt32: [SteamGridDB.Kind: URL]] {
        var picks: [UInt32: [SteamGridDB.Kind: URL]] = [:]
        for (appID, kinds) in saved {
            guard let appID = UInt32(appID) else { continue }
            picks[appID] = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind, url in
                SteamGridDB.Kind(rawValue: kind).map { ($0, url) }
            })
        }
        return picks
    }

    func pick(_ kind: SteamGridDB.Kind, for appID: UInt32) -> URL? { picks[appID]?[kind] }

    func set(_ url: URL?, kind: SteamGridDB.Kind, for appID: UInt32) {
        reload()
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
        SyncedKeychain.setValue(encodable, account: Self.account)
    }
}
