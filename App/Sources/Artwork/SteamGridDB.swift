import Foundation
import Security

/// Alternate artwork from [SteamGridDB](https://www.steamgriddb.com), adapted from Tana's
/// `SteamGridDBService`. Needs a free API key (steamgriddb.com › Preferences › API), kept
/// in the Keychain and tested against the live API before it's saved.
struct SteamGridDB: Sendable {
    enum Kind: String, CaseIterable, Identifiable, Codable, Sendable {
        /// Portrait capsule, used on library cards.
        case grid
        /// Wide key art behind the game page and launcher.
        case hero
        /// Transparent wordmark over the hero.
        case logo

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .grid: "Cover"
            case .hero: "Banner"
            case .logo: "Logo"
            }
        }

        var path: String {
            switch self {
            case .grid: "grids"
            case .hero: "heroes"
            case .logo: "logos"
            }
        }

        var previewAspectRatio: CGFloat { self == .grid ? 2.0 / 3.0 : 16.0 / 9.0 }
    }

    struct Asset: Identifiable, Hashable, Sendable {
        let id: Int
        let url: URL
        let thumbnail: URL?
        let width: Int?
        let height: Int?
        let score: Int

        var dimensions: String? {
            guard let width, let height else { return nil }
            return "\(width) × \(height)"
        }
    }

    enum Failure: LocalizedError {
        case noKey
        case rejectedKey
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noKey: "Add a SteamGridDB API key in Settings."
            case .rejectedKey: "SteamGridDB rejected the API key. Check it at steamgriddb.com › Preferences › API."
            case let .http(status): "SteamGridDB answered with HTTP \(status)."
            }
        }
    }

    private static let base = "https://www.steamgriddb.com/api/v2"

    let key: String

    /// The stored key, if there is one.
    init?() {
        guard let key = APIKeyStore.steamGridDB.value else { return nil }
        self.key = key
    }

    init(key: String) {
        self.key = key
    }

    static var isConfigured: Bool { APIKeyStore.steamGridDB.value != nil }

    /// Checks the key against the live API (uncached, since URLCache ignores the
    /// Authorization header and would happily pass a broken key).
    func validate() async throws {
        let _: [Game] = try await get("/search/autocomplete/highway", cache: .reloadIgnoringLocalCacheData) ?? []
    }

    /// SteamGridDB's own game ID for a Steam app.
    func gameID(steamAppID: UInt32) async throws -> Int? {
        let game: Game? = try await get("/games/steam/\(steamAppID)")
        return game?.id
    }

    /// Every asset of one kind, best-scored first.
    func assets(_ kind: Kind, gameID: Int, includeAdult: Bool) async throws -> [Asset] {
        var query = ["limit": "60", "nsfw": includeAdult ? "any" : "false"]
        if kind == .grid { query["dimensions"] = "600x900" }
        let raw: [RawAsset] = try await get("/\(kind.path)/game/\(gameID)", query: query) ?? []
        return raw.compactMap { asset in
            guard let id = asset.id, let url = asset.url.flatMap(URL.init(string:)) else { return nil }
            return Asset(id: id, url: url, thumbnail: asset.thumb.flatMap(URL.init(string:)),
                         width: asset.width, height: asset.height, score: asset.score ?? 0)
        }
        .sorted { $0.score > $1.score }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:],
                                   cache: URLRequest.CachePolicy = .returnCacheDataElseLoad) async throws -> T? {
        var components = URLComponents(string: Self.base + path)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!, cachePolicy: cache, timeoutInterval: 20)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.rejectedKey }
        // 404: SteamGridDB doesn't know the game.
        if status == 404 { return nil }
        guard (200 ..< 300).contains(status) else { throw Failure.http(status) }
        let envelope = try JSONDecoder().decode(Envelope<T>.self, from: data)
        return envelope.success ? envelope.data : nil
    }

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
    }

    private struct Game: Decodable {
        let id: Int
    }

    private struct RawAsset: Decodable {
        let id: Int?
        let score: Int?
        let url: String?
        let thumb: String?
        let width: Int?
        let height: Int?
    }
}

/// API keys in the Keychain (this device only, readable after first unlock).
struct APIKeyStore: Sendable {
    static let steamGridDB = APIKeyStore(account: "steamgriddb")

    let account: String
    private let service = "com.owencramer.vnhub.apikeys"

    var value: String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    func set(_ key: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let key, !key.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
}
