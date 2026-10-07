import Foundation

/// A Steam connection manager (CM) reachable over WebSocket.
public struct CMServer: Hashable, Sendable, Codable {
    /// `host:port`, as returned by the directory.
    public var endpoint: String
    public var load: Double

    var url: URL { URL(string: "wss://\(endpoint)/cmsocket/")! }
}

/// Fetches the CM list from `ISteamDirectory/GetCMListForConnect`.
enum CMDirectory {
    struct Response: Decodable {
        struct Body: Decodable {
            struct Server: Decodable {
                var endpoint: String
                var type: String
                var wtd_load: Double?
                var load: Double?
            }
            var serverlist: [Server]
            var success: Bool
        }
        var response: Body
    }

    static func fetch(cellID: UInt32, urlSession: URLSession) async throws -> [CMServer] {
        var components = URLComponents(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/")!
        components.queryItems = [
            URLQueryItem(name: "cellid", value: String(cellID)),
            URLQueryItem(name: "cmtype", value: "websockets"),
            URLQueryItem(name: "realm", value: "steamglobal"),
        ]
        let (data, response) = try await urlSession.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamError.directoryUnavailable
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> [CMServer] {
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard decoded.response.success else { throw SteamError.directoryUnavailable }
        let servers = decoded.response.serverlist
            .filter { $0.type == "websockets" }
            .map { CMServer(endpoint: $0.endpoint, load: $0.wtd_load ?? $0.load ?? 0) }
            .sorted { $0.load < $1.load }
        guard !servers.isEmpty else { throw SteamError.directoryUnavailable }
        return servers
    }
}
