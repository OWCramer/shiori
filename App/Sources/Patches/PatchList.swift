import Foundation
import Observation

/// The public patch list (github.com/OWCramer/shiori-patches): for each Steam app id, the
/// patches its publishers and players have made, where to get them and how they install. Read
/// like the compatibility list: `index.json` refreshed at most every six hours, a game's file
/// when its page opens, both kept in Caches for offline use.
@MainActor
@Observable
final class PatchListStore {
    struct Game: Codable, Sendable {
        var appID: UInt32
        var title: String
        var patches: [Patch]
    }

    struct Patch: Codable, Sendable, Identifiable, Hashable {
        var id: String
        var name: String
        var kind: String
        var official: Bool
        var by: String
        var source: Source
        var version: String?
        var languages: [String]
        var adult: Bool
        var branch: String?
        var status: String
        var verified: Verified?
        var notes: String?
        var install: Install?
        var files: [File]

        struct Source: Codable, Sendable, Hashable {
            var site: String
            var page: String
            var key: String?
        }

        struct Install: Codable, Sendable, Hashable {
            var into: String?
            var strip: String?
        }

        struct File: Codable, Sendable, Hashable {
            var host: String
            var url: String
            var name: String?
            var size: Int64?
            var sha256: String?
            var format: String?
            var installer: Bool?
            var dlc: UInt32?
            var mirrors: [Mirror]?
        }

        struct Mirror: Codable, Sendable, Hashable {
            var host: String
            var url: String
        }

        /// `false` in the JSON, or who checked the patch in Shiori and when.
        struct Verified: Codable, Sendable, Hashable {
            var by: String
            var date: String
            var engine: String?
            var note: String?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                by = try container.decode(String.self, forKey: .by)
                date = try container.decode(String.self, forKey: .date)
                engine = try container.decodeIfPresent(String.self, forKey: .engine)
                note = try container.decodeIfPresent(String.self, forKey: .note)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            kind = try c.decode(String.self, forKey: .kind)
            official = try c.decode(Bool.self, forKey: .official)
            by = try c.decode(String.self, forKey: .by)
            source = try c.decode(Source.self, forKey: .source)
            version = try c.decodeIfPresent(String.self, forKey: .version)
            languages = try c.decodeIfPresent([String].self, forKey: .languages) ?? []
            adult = try c.decodeIfPresent(Bool.self, forKey: .adult) ?? false
            branch = try c.decodeIfPresent(String.self, forKey: .branch)
            status = try c.decodeIfPresent(String.self, forKey: .status) ?? "ok"
            verified = try? c.decodeIfPresent(Verified.self, forKey: .verified)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
            install = try c.decodeIfPresent(Install.self, forKey: .install)
            files = try c.decode([File].self, forKey: .files)
        }

        /// Every part downloads inside Shiori (plain links, Google Drive, MEGA).
        var isDownloadable: Bool {
            status != "unsupported" && files.allSatisfy { ["direct", "gdrive", "mega", "wetransfer"].contains($0.host) && $0.installer != true }
        }

        var totalSize: Int64? {
            let sizes = files.compactMap(\.size)
            return sizes.count == files.count ? sizes.reduce(0, +) : nil
        }

        /// Identifies the installed version: the files' hashes, or their links when not hashed.
        var fingerprint: String {
            files.map { $0.sha256 ?? $0.url }.joined(separator: ",")
        }
    }

    private struct Index: Decodable {
        struct Entry: Decodable { var title: String; var patches: Int; var updated: String }
        var games: [String: Entry]
    }

    static let repository = URL(string: "https://github.com/OWCramer/shiori-patches")!
    private static let raw = URL(string: "https://raw.githubusercontent.com/OWCramer/shiori-patches/main/")!
    private static let refreshInterval: TimeInterval = 6 * 3600

    /// Patch counts and last change by app id, from index.json.
    private(set) var index: [UInt32: (patches: Int, updated: String)] = [:]
    /// Games whose file has been read.
    private(set) var games: [UInt32: Game] = [:]
    private var refreshing = false
    private var loading: Set<UInt32> = []

    private let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("patch-list", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexFile) { absorbIndex(data) }
    }

    func patches(for appID: UInt32) -> [Patch] { games[appID]?.patches ?? [] }

    /// Fetches index.json again when the cached copy is older than six hours (or `force`).
    func refresh(force: Bool = false) async {
        guard !refreshing else { return }
        let stamp = (try? indexFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if !force, let stamp, Date().timeIntervalSince(stamp) < Self.refreshInterval { return }
        refreshing = true
        defer { refreshing = false }
        guard let data = await Self.get(Self.raw.appendingPathComponent("index.json")),
              (try? JSONDecoder().decode(Index.self, from: data)) != nil else { return }
        try? data.write(to: indexFile, options: .atomic)
        absorbIndex(data)
    }

    /// Reads a game's patches: the cached file at once, then GitHub's when the index says it changed.
    func load(appID: UInt32) async {
        let file = gameFile(appID)
        if games[appID] == nil, let data = try? Data(contentsOf: file),
           let game = try? JSONDecoder().decode(Game.self, from: data) {
            games[appID] = game
        }
        await refresh()
        // With the index loaded, a game it doesn't list has no file; without it (first launch,
        // or the index still downloading), ask for the file anyway.
        guard index.isEmpty || index[appID] != nil, !loading.contains(appID) else { return }
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if games[appID] != nil, let stamp, Date().timeIntervalSince(stamp) < Self.refreshInterval { return }
        loading.insert(appID)
        defer { loading.remove(appID) }
        guard let data = await Self.get(Self.raw.appendingPathComponent("patches/\(appID).json")),
              let game = try? JSONDecoder().decode(Game.self, from: data) else { return }
        try? data.write(to: file, options: .atomic)
        games[appID] = game
    }

    private var indexFile: URL { folder.appendingPathComponent("index.json") }
    private func gameFile(_ appID: UInt32) -> URL { folder.appendingPathComponent("\(appID).json") }

    private func absorbIndex(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode(Index.self, from: data) else { return }
        index = Dictionary(uniqueKeysWithValues: decoded.games.compactMap { key, value in
            UInt32(key).map { ($0, (value.patches, value.updated)) }
        })
    }

    private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
