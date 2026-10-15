// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if DEBUG
import Foundation
import SteamKit
import UIKit

/// `-ShioriScreenshotLibrary YES` (Debug only): a made-up library for App Store screenshots.
/// Invented visual novels, studios and patches, covers drawn by `ScreenshotArt`, a neutral
/// "Reader" profile, and no network: Steam is never contacted, GitHub's lists and VNDB aren't
/// fetched, iCloud isn't synced, and any other request fails (`OfflineProtocol`).
///
/// Everything lives in its own folder (Caches/ScreenshotLibrary, made afresh each launch):
/// Shiori's Documents and Application Support point there, and the synced settings
/// (iCloud Keychain) are kept in memory, so the device's real library, saves and settings
/// are neither read nor changed.
///
/// Works with the other launch flags: `-ShioriTab`, `-ShioriOpenGame 9100010`,
/// `-ShioriFakeDownload 9100060,9100090`, `-ShioriOpenCollection`, `-ShioriOrientation`.
enum ScreenshotLibrary {
    static let isOn = UserDefaults.standard.bool(forKey: "ShioriScreenshotLibrary")

    static var root: URL { URL.cachesDirectory.appendingPathComponent("ScreenshotLibrary", isDirectory: true) }
    static var documents: URL { root.appendingPathComponent("Documents", isDirectory: true) }
    static var support: URL { root.appendingPathComponent("Application Support", isDirectory: true) }
    static var caches: URL { root.appendingPathComponent("Caches", isDirectory: true) }
    private static var art: URL { root.appendingPathComponent("Art", isDirectory: true) }

    /// The real Caches folder, or the screenshot library's.
    static func cachesDirectory() -> URL {
        isOn ? caches : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static let accountName = "Reader"

    // MARK: Synced settings, in memory

    private static let keychainLock = NSLock()
    nonisolated(unsafe) private static var keychain: [String: Data] = [:]

    static func keychainData(account: String) -> Data? { keychainLock.withLock { keychain[account] } }
    static func setKeychainData(_ data: Data?, account: String) { keychainLock.withLock { keychain[account] = data } }

    // MARK: Fixture

    struct Game {
        var appID: UInt32
        var name: String
        var developer: String
        var franchise: String?
        var year: Int
        var engine: String?
        var version: String?
        var sizeGB: Double
        var installed = false
        /// Hours since it was last started, if it has been.
        var playedHoursAgo: Double?
        var saves = 0
        var style: ScreenshotArt.Style
    }

    private static func rgb(_ r: Double, _ g: Double, _ b: Double) -> UIColor { UIColor(red: r, green: g, blue: b, alpha: 1) }

    private static let cream = rgb(0.97, 0.91, 0.78)
    private static let pink = rgb(0.98, 0.78, 0.84)

    /// Titles, studios and descriptions are invented for these screenshots.
    static let games: [Game] = [
        Game(appID: 9_100_010, name: "Lanterns over Kawasemi", developer: "Kawasemi Works", year: 2024,
             engine: "renpy", version: "8.3.4", sizeGB: 2.4, installed: true, playedHoursAgo: 2, saves: 7,
             style: .init(sky: (rgb(0.11, 0.12, 0.30), rgb(0.36, 0.16, 0.30)), disc: cream, hills: [rgb(0.16, 0.10, 0.22), rgb(0.08, 0.05, 0.12)],
                          motif: .lanterns, accent: rgb(0.96, 0.55, 0.28))),
        Game(appID: 9_100_020, name: "Seven Days of First Snow", developer: "Hollow Pine Studio", year: 2023,
             engine: "artemis", version: nil, sizeGB: 3.1, installed: true, playedHoursAgo: 27, saves: 3,
             style: .init(sky: (rgb(0.48, 0.60, 0.78), rgb(0.80, 0.84, 0.90)), disc: rgb(0.99, 0.97, 0.92), hills: [rgb(0.88, 0.91, 0.96), rgb(0.70, 0.76, 0.86)],
                          motif: .snow, accent: pink, ink: rgb(0.16, 0.18, 0.30))),
        Game(appID: 9_100_030, name: "Starboard Letters", developer: "Saltwind Softworks", year: 2022,
             engine: "renpy", version: "8.2.1", sizeGB: 1.6, installed: true, playedHoursAgo: 75, saves: 12,
             style: .init(sky: (rgb(0.96, 0.66, 0.42), rgb(0.94, 0.84, 0.66)), disc: rgb(0.86, 0.24, 0.20), hills: [rgb(0.15, 0.30, 0.48)],
                          motif: .waves, accent: rgb(0.93, 0.95, 0.96), ink: rgb(0.98, 0.95, 0.88))),
        Game(appID: 9_100_040, name: "Ninefold Bell Tower", developer: "Bellwether Ink", franchise: "Ninefold Bell Tower", year: 2019,
             engine: "siglus", version: nil, sizeGB: 4.8, installed: true, playedHoursAgo: 150, saves: 20,
             style: .init(sky: (rgb(0.05, 0.10, 0.16), rgb(0.12, 0.24, 0.30)), disc: rgb(0.95, 0.90, 0.72), hills: [rgb(0.06, 0.16, 0.16), rgb(0.03, 0.08, 0.09)],
                          motif: .pine, accent: rgb(0.85, 0.75, 0.50))),
        Game(appID: 9_100_041, name: "Ninefold Bell Tower II: Vespers", developer: "Bellwether Ink", franchise: "Ninefold Bell Tower", year: 2021,
             engine: "siglus", version: nil, sizeGB: 5.2, installed: true,
             style: .init(sky: (rgb(0.28, 0.08, 0.14), rgb(0.55, 0.20, 0.18)), disc: rgb(0.98, 0.80, 0.48), crescent: true,
                          hills: [rgb(0.22, 0.06, 0.10), rgb(0.10, 0.03, 0.05)], motif: .pine, accent: rgb(0.95, 0.70, 0.40))),
        Game(appID: 9_100_042, name: "Ninefold Bell Tower: Echoes", developer: "Bellwether Ink", franchise: "Ninefold Bell Tower", year: 2025,
             engine: "siglus", version: nil, sizeGB: 2.2,
             style: .init(sky: (rgb(0.10, 0.20, 0.22), rgb(0.30, 0.42, 0.40)), disc: rgb(0.92, 0.94, 0.86), crescent: true,
                          hills: [rgb(0.08, 0.16, 0.16), rgb(0.04, 0.09, 0.09)], motif: .stars, accent: rgb(0.80, 0.90, 0.85))),
        Game(appID: 9_100_050, name: "Summer at Tsukimi Station", developer: "Mizuhiki House", franchise: "Tsukimi Station", year: 2020,
             engine: "luca", version: nil, sizeGB: 3.6, installed: true,
             style: .init(sky: (rgb(0.30, 0.62, 0.86), rgb(0.70, 0.88, 0.94)), disc: rgb(0.99, 0.93, 0.60), hills: [rgb(0.30, 0.56, 0.36), rgb(0.16, 0.36, 0.24)],
                          motif: .grass, accent: rgb(0.99, 0.96, 0.85), ink: rgb(0.99, 0.98, 0.94))),
        Game(appID: 9_100_051, name: "Winter at Tsukimi Station", developer: "Mizuhiki House", franchise: "Tsukimi Station", year: 2022,
             engine: "luca", version: nil, sizeGB: 3.9,
             style: .init(sky: (rgb(0.20, 0.26, 0.42), rgb(0.56, 0.62, 0.76)), disc: rgb(0.96, 0.96, 0.98), hills: [rgb(0.80, 0.84, 0.92), rgb(0.30, 0.36, 0.52)],
                          motif: .snow, accent: pink, ink: rgb(0.99, 0.98, 0.96))),
        Game(appID: 9_100_060, name: "Cicada Hour", developer: "Little Ember Co.", year: 2021,
             engine: "renpy", version: "7.5.3", sizeGB: 1.1,
             style: .init(sky: (rgb(0.98, 0.78, 0.40), rgb(0.96, 0.52, 0.32)), disc: rgb(0.99, 0.95, 0.80), hills: [rgb(0.36, 0.44, 0.20), rgb(0.18, 0.24, 0.12)],
                          motif: .grass, accent: rgb(0.99, 0.90, 0.60))),
        Game(appID: 9_100_070, name: "Ember & Inkwell", developer: "Little Ember Co.", year: 2023,
             engine: "catsystem2", version: nil, sizeGB: 2.9, installed: true, playedHoursAgo: 240, saves: 4,
             style: .init(sky: (rgb(0.40, 0.10, 0.08), rgb(0.78, 0.30, 0.14)), disc: rgb(0.98, 0.86, 0.56), hills: [rgb(0.28, 0.08, 0.06), rgb(0.14, 0.04, 0.04)],
                          motif: .maple, accent: rgb(0.96, 0.42, 0.18))),
        Game(appID: 9_100_080, name: "Under the Plum Gate", developer: "Mizuhiki House", year: 2018,
             engine: "kirikiri", version: nil, sizeGB: 4.1,
             style: .init(sky: (rgb(0.76, 0.16, 0.18), rgb(0.86, 0.36, 0.30)), disc: cream, hills: [rgb(0.10, 0.07, 0.10)],
                          motif: .plum, accent: rgb(0.99, 0.88, 0.90))),
        Game(appID: 9_100_090, name: "A Kite for Mirei", developer: "Kawasemi Works", year: 2025,
             engine: "renpy", version: "8.3.4", sizeGB: 0.9,
             style: .init(sky: (rgb(0.46, 0.76, 0.92), rgb(0.88, 0.94, 0.96)), disc: rgb(0.99, 0.99, 0.94), hills: [rgb(0.50, 0.74, 0.46), rgb(0.30, 0.56, 0.34)],
                          motif: .sakura, accent: pink, ink: rgb(0.99, 0.99, 0.97))),
        Game(appID: 9_100_100, name: "Petals in the Archive", developer: "Hollow Pine Studio", year: 2024,
             engine: "artemis", version: nil, sizeGB: 2.7,
             style: .init(sky: (rgb(0.76, 0.17, 0.16), rgb(0.62, 0.12, 0.14)), disc: cream, hills: [rgb(0.10, 0.07, 0.10)],
                          motif: .sakura, accent: pink)),
        Game(appID: 9_100_110, name: "Saltwind Diaries", developer: "Saltwind Softworks", year: 2020,
             engine: "renpy", version: "7.4.11", sizeGB: 1.3,
             style: .init(sky: (rgb(0.10, 0.30, 0.44), rgb(0.30, 0.56, 0.66)), disc: rgb(0.99, 0.92, 0.74), hills: [rgb(0.06, 0.18, 0.30)],
                          motif: .waves, accent: rgb(0.86, 0.94, 0.96))),
        Game(appID: 9_100_120, name: "Hollyhock Rooftops", developer: "Bellwether Ink", year: 2025,
             engine: "renpy", version: "8.3.4", sizeGB: 1.8, installed: true,
             style: .init(sky: (rgb(0.52, 0.28, 0.56), rgb(0.92, 0.58, 0.56)), disc: rgb(0.99, 0.90, 0.70), hills: [rgb(0.26, 0.14, 0.30), rgb(0.14, 0.08, 0.18)],
                          motif: .stars, accent: rgb(0.99, 0.80, 0.86))),
        Game(appID: 9_100_130, name: "The Moonlit Ferry Line", developer: "Saltwind Softworks", year: 2019,
             engine: "luca", version: nil, sizeGB: 2.5,
             style: .init(sky: (rgb(0.04, 0.06, 0.14), rgb(0.12, 0.18, 0.34)), disc: rgb(0.96, 0.94, 0.80), crescent: true, hills: [rgb(0.05, 0.10, 0.20)],
                          motif: .waves, accent: rgb(0.70, 0.80, 0.92))),
    ]

    /// Shown on game pages' patch lists.
    private static var patches: [UInt32: [[String: Any]]] { [
        9_100_010: [
            patch(id: "kawasemi-voices", name: "Restored Voice Pack", kind: "content", official: true, by: "Kawasemi Works",
                  page: "https://kawasemi-works.example/patches", size: 412_000_000,
                  notes: "Adds the full voice track to the epilogue chapters."),
            patch(id: "kawasemi-ja", name: "Japanese Script", kind: "translation", official: false, by: "Hoshikuzu Translations",
                  page: "https://hoshikuzu.example/kawasemi", size: 18_500_000, languages: ["ja"], verified: false),
        ],
        9_100_040: [
            patch(id: "ninefold-fixes", name: "Typo and Timing Fixes", kind: "fix", official: false, by: "Belfry Readers",
                  page: "https://belfry-readers.example/ninefold", size: 6_200_000),
        ],
    ] }

    private static func patch(id: String, name: String, kind: String, official: Bool, by: String, page: String, size: Int64,
                              languages: [String] = ["en"], verified: Bool = true, notes: String? = nil) -> [String: Any] {
        var patch: [String: Any] = [
            "id": id, "name": name, "kind": kind, "official": official, "by": by,
            "source": ["site": "other", "page": page], "version": "1.2", "languages": languages, "adult": false, "status": "ok",
            "files": [["host": "direct", "url": page + "/\(id).zip", "name": "\(id).zip", "size": size]],
        ]
        patch["verified"] = verified ? ["by": "Shiori", "date": "2026-10-01"] as [String: Any] : false
        if let notes { patch["notes"] = notes }
        return patch
    }

    // MARK: Preparing

    /// Builds the library's folder afresh: covers, the library, installed games with their
    /// saves, engine scans, the compatibility and patch lists, and the synced play history.
    @MainActor static func prepare() {
        guard isOn else { return }
        URLProtocol.registerClass(OfflineProtocol.self)
        let fm = FileManager.default
        try? fm.removeItem(at: root)
        for folder in [documents, support, caches, art] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        let now = Date()

        var library: [[String: Any]] = []
        var scans: [String: Any] = [:]
        var launches: [[String: Any]] = []
        for game in games {
            let urls = drawArt(for: game)
            var entry: [String: Any] = [
                "appID": game.appID, "name": game.name, "isVisualNovel": true,
                "capsule": urls.capsule.absoluteString, "capsuleLarge": urls.capsule.absoluteString,
                "hero": urls.hero.absoluteString, "logo": urls.logo.absoluteString, "header": urls.header.absoluteString,
                "estimatedSize": UInt64(game.sizeGB * 1_000_000_000), "developer": game.developer, "publisher": game.developer,
                "releaseDate": DateComponents(calendar: .current, year: game.year, month: 4, day: 12).date!.timeIntervalSinceReferenceDate,
            ]
            if let franchise = game.franchise { entry["franchise"] = franchise }
            library.append(entry)
            if let engine = game.engine {
                var match: [String: Any] = ["engine": engine, "details": [String: String]()]
                if let version = game.version { match["version"] = version }
                scans[String(game.appID)] = ["engine": match, "installSize": UInt64(game.sizeGB * 1_000_000_000),
                                             "scannedAt": now.timeIntervalSinceReferenceDate]
            }
            if game.installed { install(game, now: now) }
            if let hours = game.playedHoursAgo {
                launches.append(["appID": game.appID, "date": now.addingTimeInterval(-hours * 3600).timeIntervalSinceReferenceDate])
            }
        }
        write(library, to: support.appendingPathComponent("library.json"))
        write(scans, to: support.appendingPathComponent("engine-scan-8.json"))
        if let data = try? JSONSerialization.data(withJSONObject: launches) { setKeychainData(data, account: "playHistory") }
        writeCompatibility()
        writePatchList()
    }

    private static func drawArt(for game: Game) -> (capsule: URL, header: URL, hero: URL, logo: URL) {
        func draw(_ kind: ScreenshotArt.Kind, _ name: String) -> URL {
            let url = art.appendingPathComponent("\(game.appID)-\(name).png")
            try? ScreenshotArt.png(kind, title: game.name, style: game.style, seed: game.appID)?.write(to: url)
            return url
        }
        return (draw(.capsule, "capsule"), draw(.header, "header"), draw(.hero, "hero"), draw(.logo, "logo"))
    }

    /// An installed game's folder: game.json, a few save slots, and on the leading game a
    /// patch the list offers, installed.
    @MainActor private static func install(_ game: Game, now: Date) {
        let fm = FileManager.default
        let folder = documents.appendingPathComponent("Games/\(game.appID)-\(GameLibrary.slug(game.name))", isDirectory: true)
        let saves = folder.appendingPathComponent("saves", isDirectory: true)
        for sub in ["base", "patch", "saves"] {
            try? fm.createDirectory(at: folder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        let installedAt = now.addingTimeInterval(-Double(game.appID % 100) * 3600 * 5)
        var record: [String: Any] = [
            "appID": game.appID, "name": game.name, "depots": [] as [Any],
            "installedAt": ISO8601DateFormatter().string(from: installedAt), "sizeBytes": UInt64(game.sizeGB * 1_000_000_000),
        ]
        if let engine = game.engine {
            var match: [String: Any] = ["engine": engine, "details": [String: String]()]
            if let version = game.version { match["version"] = version }
            record["engine"] = match
        }
        write(record, to: folder.appendingPathComponent("game.json"))

        let latest = now.addingTimeInterval(-(game.playedHoursAgo ?? 400) * 3600 + 1800)
        for slot in 0..<game.saves {
            let name: String = switch game.engine {
            case "renpy": "\(slot + 1)-1-LT1.save"
            case "siglus": String(format: "%04d.sav", slot)
            case "artemis": String(format: "save%02d.dat", slot + 1)
            case "luca": String(format: "luca-%02d.json", slot + 1)
            case "catsystem2": "shiori-slot-\(slot + 1).json"
            default: "save\(slot).dat"
            }
            let url = saves.appendingPathComponent(name)
            fm.createFile(atPath: url.path, contents: Data("screenshot".utf8))
            try? fm.setAttributes([.modificationDate: latest.addingTimeInterval(-Double(slot) * 86400)], ofItemAtPath: url.path)
        }

        if game.appID == 9_100_010 {
            fm.createFile(atPath: folder.appendingPathComponent("patch/voices.rpa").path, contents: Data(count: 1024))
            let installed: [[String: Any]] = [[
                "id": "kawasemi-voices", "name": "Restored Voice Pack", "version": "1.2",
                "fingerprint": "https://kawasemi-works.example/patches/kawasemi-voices.zip",
                "installedAt": ISO8601DateFormatter().string(from: installedAt.addingTimeInterval(600)), "files": ["voices.rpa"],
            ]]
            write(installed, to: folder.appendingPathComponent("patches.json"))
        }
    }

    private static func writeCompatibility() {
        let folder = caches.appendingPathComponent("compatibility", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["renpy": "Ren'Py", "kirikiri": "KiriKiri", "artemis": "Artemis", "siglus": "Siglus", "luca": "Luca System"]
        for (engine, name) in names {
            let entries: [[String: Any]] = games.filter { $0.engine == engine }.map { game in
                [
                    "appID": game.appID, "name": game.name, "status": game.installed ? "complete" : "plays",
                    "tested": "2026-10-01", "devices": ["iPhone 17 Pro", "iPad Pro 13-inch"],
                    "notes": game.installed ? "Plays start to finish, with saves and the backlog." : "Plays through the first chapters.",
                ]
            }
            write(["engine": engine, "name": name, "games": entries] as [String: Any], to: folder.appendingPathComponent("\(engine).json"))
        }
    }

    private static func writePatchList() {
        let folder = caches.appendingPathComponent("patch-list", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var index: [String: Any] = [:]
        for (appID, list) in patches {
            let title = games.first { $0.appID == appID }?.name ?? ""
            index[String(appID)] = ["title": title, "patches": list.count, "updated": "2026-10-01"]
            write(["appID": appID, "title": title, "patches": list] as [String: Any], to: folder.appendingPathComponent("\(appID).json"))
        }
        // Every made-up game is in the index, so none is asked for.
        for game in games where index[String(game.appID)] == nil {
            index[String(game.appID)] = ["title": game.name, "patches": 0, "updated": "2026-10-01"]
        }
        write(["games": index], to: folder.appendingPathComponent("index.json"))
    }

    private static func write(_ object: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// The account's sign-in as Shiori shows it: signed in, as "Reader", with Steam's
    /// default store preferences (no adult content).
    static var loggedOnState: SessionState { .loggedOn(accountName: accountName, steamID: .individual(accountID: 1)) }
}

/// Fails every web request while the screenshot library is on, so nothing reaches a server.
final class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return ["http", "https", "ws", "wss"].contains(scheme)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
#endif
