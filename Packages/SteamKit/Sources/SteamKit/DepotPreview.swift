import Foundation

/// A game's Windows file list, read from its depot manifests without downloading the game,
/// plus the ability to fetch individual small files. Used to tell what engine a game runs
/// on before committing gigabytes to it.
public struct DepotPreview: Sendable {
    public let appID: UInt32
    public let depots: [InstalledDepot]
    /// Every file and folder path across the depots, `/`-separated, as the manifests spell them.
    public let paths: [String]
    /// Size the install would take.
    public let totalSize: UInt64

    let jobs: [DepotJob]
    let cdn: CDNClient

    /// Downloads one file (looked up case-insensitively) if it's no bigger than `maxSize`.
    /// Returns nil if the game doesn't have it.
    public func contents(of path: String, maxSize: UInt64 = 1 << 20) async throws -> Data? {
        let wanted = path.lowercased()
        for job in jobs {
            guard let file = job.manifest.files.first(where: { $0.name.lowercased() == wanted && !$0.isDirectory }) else { continue }
            guard file.size <= maxSize else { return nil }
            var data = Data(count: Int(file.size))
            for chunk in file.chunks {
                let compressed = try await cdn.chunk(depotID: job.depot.depotID, chunk: chunk)
                let piece = try DepotWriter.decode(compressed, chunk: chunk, key: job.key)
                data.replaceSubrange(Int(chunk.offset) ..< Int(chunk.offset) + piece.count, with: piece)
            }
            return data
        }
        return nil
    }

    /// The first bytes of one file (at least `length`, rounded up to whole chunks, usually
    /// one), for reading a header out of a file too big to fetch. Nil if the game doesn't have it.
    public func prefix(of path: String, length: UInt64) async throws -> Data? {
        let wanted = path.lowercased()
        for job in jobs {
            guard let file = job.manifest.files.first(where: { $0.name.lowercased() == wanted && !$0.isDirectory }) else { continue }
            var data = Data()
            for chunk in file.chunks where chunk.offset < length {
                // Chunks are sorted by offset; stop at a gap rather than return misplaced bytes.
                guard chunk.offset == UInt64(data.count) else { break }
                let compressed = try await cdn.chunk(depotID: job.depot.depotID, chunk: chunk)
                data.append(try DepotWriter.decode(compressed, chunk: chunk, key: job.key))
            }
            return data
        }
        return nil
    }
}

extension SteamSession {
    /// Reads the game's Windows depot manifests (a few MB at most) without downloading it.
    public func preview(appID: UInt32, branch: String = "public") async throws -> DepotPreview {
        guard let app = try await appInfo([appID]).first else { throw SteamError.noDownloadableDepots(appID: appID) }
        let owned = try await ownedPackageContents()
        let depots = DepotSelection.windowsDepots(of: app, owned: owned, branch: branch)
        guard !depots.isEmpty else { throw SteamError.noDownloadableDepots(appID: appID) }

        let servers = try await contentServers().filter { $0.canServe(appID: appID) }
        guard !servers.isEmpty else { throw SteamError.noContentServers }
        let cdn = CDNClient(servers: servers, appID: appID, session: self)

        var jobs: [DepotJob] = []
        for depot in depots {
            try Task.checkCancellation()
            let key = try await depotKey(depotID: depot.depotID, appID: appID)
            let code = try await manifestRequestCode(appID: appID, depotID: depot.depotID, manifestID: depot.manifestID, branch: branch)
            var manifest = try DepotManifest(zipped: try await cdn.manifest(depotID: depot.depotID, manifestID: depot.manifestID, requestCode: code))
            try manifest.decryptFilenames(key: key)
            jobs.append(DepotJob(depot: InstalledDepot(depotID: depot.depotID, manifestID: depot.manifestID), key: key, manifest: manifest))
        }
        let files = jobs.flatMap(\.manifest.files)
        return DepotPreview(
            appID: appID,
            depots: jobs.map(\.depot),
            paths: files.map(\.name),
            totalSize: files.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size },
            jobs: jobs,
            cdn: cdn
        )
    }
}
