import Foundation

/// HTTPS client for Steam content servers. Rotates to the next server when one fails and
/// fetches a CDN auth token for hosts that ask for one.
actor CDNClient {
    /// Concurrent chunk requests, matching DepotDownloader's default and the Steam client's range.
    static let maxConcurrentRequests = 8

    private let servers: [ContentServer]
    private let appID: UInt32
    private let session: SteamSession
    private let http: URLSession
    private var current = 0
    private var authTokens: [String: String] = [:]

    init(servers: [ContentServer], appID: UInt32, session: SteamSession) {
        // Each server is listed as often as Steam weights it, as the official client does.
        self.servers = servers.flatMap { Array(repeating: $0, count: min($0.entries, 4)) }
        self.appID = appID
        self.session = session
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = Self.maxConcurrentRequests
        configuration.timeoutIntervalForRequest = 30
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": "Valve/Steam HTTP Client 1.0"]
        http = URLSession(configuration: configuration)
    }

    deinit { http.invalidateAndCancel() }

    func manifest(depotID: UInt32, manifestID: UInt64, requestCode: UInt64) async throws -> Data {
        let path = requestCode == 0
            ? "depot/\(depotID)/manifest/\(manifestID)/5"
            : "depot/\(depotID)/manifest/\(manifestID)/5/\(requestCode)"
        return try await fetch(path, depotID: depotID, what: "the file list for depot \(depotID)")
    }

    func chunk(depotID: UInt32, chunk: DepotManifest.Chunk) async throws -> Data {
        let data = try await fetch("depot/\(depotID)/chunk/\(chunk.hexID)", depotID: depotID, what: "game data")
        guard chunk.compressedLength == 0 || data.count == Int(chunk.compressedLength) else {
            throw CDNError.lengthMismatch
        }
        return data
    }

    enum CDNError: Error { case lengthMismatch, status(Int) }

    /// Tries up to five servers (or the same one again if there's only one), backing off between attempts.
    private func fetch(_ path: String, depotID: UInt32, what: String) async throws -> Data {
        var lastError: Error?
        for attempt in 0 ..< 5 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(for: .milliseconds(500 << min(attempt, 4))) }
            let index = current
            let server = servers[index % servers.count]
            do {
                return try await get(path, from: server, depotID: depotID)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                if current == index { current += 1 }
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throw lastError.map { _ in SteamError.contentUnavailable(what) } ?? SteamError.contentUnavailable(what)
    }

    private func get(_ path: String, from server: ContentServer, depotID: UInt32) async throws -> Data {
        let tokenKey = "\(server.vhost)/\(depotID)"
        let (data, status) = try await request(path, host: server.vhost, token: authTokens[tokenKey])
        if status == 200 { return data }
        if status == 401 || status == 403, authTokens[tokenKey] == nil {
            let token = try await session.cdnAuthToken(appID: appID, depotID: depotID, host: server.vhost)
            authTokens[tokenKey] = token
            let (retried, retriedStatus) = try await request(path, host: server.vhost, token: token)
            if retriedStatus == 200 { return retried }
            throw CDNError.status(retriedStatus)
        }
        throw CDNError.status(status)
    }

    private nonisolated func request(_ path: String, host: String, token: String?) async throws -> (Data, Int) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + path
        if let token, !token.isEmpty {
            // Tokens arrive already formatted as a query string ("?token=…").
            components.percentEncodedQuery = token.hasPrefix("?") ? String(token.dropFirst()) : token
        }
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await http.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
