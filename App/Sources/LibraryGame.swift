import Foundation
import SteamKit

/// What the library UI needs about an owned game. Built from PICS app info and cached on
/// disk, so the library appears instantly at launch while Steam refreshes it.
struct LibraryGame: Codable, Hashable, Identifiable, Sendable {
    var appID: UInt32
    var name: String
    var isVisualNovel: Bool
    var capsule: URL?
    var capsuleLarge: URL?
    var hero: URL?
    var logo: URL?
    var header: URL?
    /// Base-game Windows depots' size from PICS, before DLC. An estimate for display.
    var estimatedSize: UInt64?
    /// Steam branches anyone who owns the game can pick (Properties › Betas), "public" first.
    var branches: [DepotSelection.Branch]?

    var id: UInt32 { appID }

    init(_ app: AppInfo) {
        appID = app.appID
        name = app.name
        isVisualNovel = app.isVisualNovel
        capsule = app.capsuleURL()
        capsuleLarge = app.capsuleURL(large: true)
        hero = app.heroURL(large: true)
        logo = app.logoURL(large: true)
        header = app.headerURL
        // Every depot counts as "owned" here; ownership is settled when downloading.
        let all = Set(app.keyValues["depots"]?.children.compactMap { UInt32($0.name) } ?? [])
        let size = DepotSelection.windowsDepots(of: app, owned: all)
            .filter { app.keyValues[path: "depots", String($0.depotID), "dlcappid"] == nil }
            .reduce(0) { $0 + $1.size }
        estimatedSize = size > 0 ? size : nil
        branches = DepotSelection.branches(of: app)
    }
}

/// The last library Steam returned, kept in Application Support.
enum LibraryCache {
    private static var url: URL {
        URL.applicationSupportDirectory.appendingPathComponent("library.json")
    }

    static func load() -> [LibraryGame] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([LibraryGame].self, from: data)) ?? []
    }

    static func save(_ games: [LibraryGame]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(games).write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
