import Foundation

public struct DownloadProgress: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Fetching app info, depot keys and manifests.
        case preparing
        case downloading
        case finishing
    }

    public var phase: Phase
    /// Size of the installed game.
    public var totalBytes: UInt64
    /// Bytes on disk and verified, including anything from an earlier, paused run.
    public var completedBytes: UInt64
    /// Compressed bytes fetched from the CDN in this run.
    public var downloadedBytes: UInt64

    public var fraction: Double { totalBytes == 0 ? 0 : Double(completedBytes) / Double(totalBytes) }
}

/// One depot build installed into a folder.
public struct InstalledDepot: Codable, Hashable, Sendable {
    public var depotID: UInt32
    public var manifestID: UInt64
}

/// SteamKit's bookkeeping for one app's install: the decrypted manifests and a per-manifest
/// journal of finished chunks, kept outside the game folder so the folder holds only game files.
public struct DepotInstall: Sendable {
    /// Where the game files go (`…/base`).
    public let root: URL
    /// Private state: `install.json`, `<depot>_<manifest>.manifest`, `<depot>_<manifest>.done`.
    public let stateDirectory: URL

    public init(root: URL, stateDirectory: URL) {
        self.root = root
        self.stateDirectory = stateDirectory
    }

    struct Record: Codable {
        var appID: UInt32
        var depots: [InstalledDepot]
        var isComplete: Bool
    }

    var recordURL: URL { stateDirectory.appendingPathComponent("install.json") }

    func manifestURL(_ depot: InstalledDepot) -> URL {
        stateDirectory.appendingPathComponent("\(depot.depotID)_\(depot.manifestID).manifest")
    }

    func journalURL(_ depot: InstalledDepot) -> URL {
        stateDirectory.appendingPathComponent("\(depot.depotID)_\(depot.manifestID).done")
    }

    func loadRecord() -> Record? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func save(_ record: Record) throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
    }

    /// The depots of a finished install, or nil if none has completed.
    public var installedDepots: [InstalledDepot]? {
        guard let record = loadRecord(), record.isComplete else { return nil }
        return record.depots
    }

    func loadManifest(_ depot: InstalledDepot) -> DepotManifest? {
        guard let data = try? Data(contentsOf: manifestURL(depot)) else { return nil }
        return try? DepotManifest(sections: data)
    }

    /// Resolves a manifest path inside `root`, refusing anything that would escape it.
    func fileURL(for name: String) throws -> URL {
        let components = name.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !name.hasPrefix("/"),
              !components.contains(where: { $0 == ".." || $0 == "." })
        else { throw SteamError.unsafePath(name) }
        return components.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    /// Deletes the bookkeeping (not the game files).
    public func removeState() throws {
        if FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
    }
}

extension SteamSession {
    /// Downloads the app's Windows depots into `install.root`. Cancelling the task pauses;
    /// calling again resumes from the finished chunks. Returns the installed depot builds.
    public func download(
        appID: UInt32,
        into install: DepotInstall,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> [InstalledDepot] {
        progress(DownloadProgress(phase: .preparing, totalBytes: 0, completedBytes: 0, downloadedBytes: 0))
        guard let app = try await appInfo([appID]).first else { throw SteamError.noDownloadableDepots(appID: appID) }
        let owned = try await ownedPackageContents()
        let depots = DepotSelection.windowsDepots(of: app, owned: owned)
        guard !depots.isEmpty else { throw SteamError.noDownloadableDepots(appID: appID) }

        let servers = try await contentServers().filter { $0.canServe(appID: appID) }
        guard !servers.isEmpty else { throw SteamError.noContentServers }
        let cdn = CDNClient(servers: servers, appID: appID, session: self)

        var jobs: [DepotJob] = []
        for depot in depots {
            try Task.checkCancellation()
            let installed = InstalledDepot(depotID: depot.depotID, manifestID: depot.manifestID)
            let key = try await depotKey(depotID: depot.depotID, appID: appID)
            let manifest: DepotManifest
            if let saved = install.loadManifest(installed) {
                manifest = saved
            } else {
                let code = try await manifestRequestCode(appID: appID, depotID: depot.depotID, manifestID: depot.manifestID)
                var fetched = try DepotManifest(zipped: try await cdn.manifest(depotID: depot.depotID, manifestID: depot.manifestID, requestCode: code))
                try fetched.decryptFilenames(key: key)
                try FileManager.default.createDirectory(at: install.stateDirectory, withIntermediateDirectories: true)
                try fetched.serialized().write(to: install.manifestURL(installed), options: .atomic)
                manifest = fetched
            }
            jobs.append(DepotJob(depot: installed, key: key, manifest: manifest))
        }

        let installed = jobs.map(\.depot)
        var record = install.loadRecord() ?? DepotInstall.Record(appID: appID, depots: installed, isComplete: false)
        if record.depots != installed || record.appID != appID {
            record = DepotInstall.Record(appID: appID, depots: installed, isComplete: false)
        }
        record.isComplete = false
        try install.save(record)

        try await DepotWriter(install: install, jobs: jobs, cdn: cdn, progress: progress).run()

        record.isComplete = true
        try install.save(record)
        return installed
    }

    /// Depot and app ids covered by the account's licences (a package can grant either).
    func ownedPackageContents() async throws -> Set<UInt32> {
        if ownedPackages == nil { _ = try await ownedApps() }
        return Set(ownedPackages?.flatMap { $0.depotIDs + $0.appIDs } ?? [])
    }
}

/// Which depots of an app make up the Windows install.
public enum DepotSelection {
    public struct Depot: Equatable, Sendable {
        public var depotID: UInt32
        public var manifestID: UInt64
        public var size: UInt64
    }

    /// Public-branch Windows (or OS-neutral) depots the account owns, English or language-neutral,
    /// preferring 64-bit when a depot is split by architecture.
    public static func windowsDepots(of app: AppInfo, owned: Set<UInt32>) -> [Depot] {
        guard let depots = app.keyValues["depots"] else { return [] }
        var candidates: [(depot: Depot, arch: String)] = []
        for section in depots.children {
            guard let depotID = UInt32(section.name), owned.contains(depotID),
                  let manifest = section[path: "manifests", "public"],
                  let gid = manifest["gid"]?.uint64 ?? manifest.uint64
            else { continue }
            let config = section["config"]
            if let oslist = config?["oslist"]?.value, !oslist.isEmpty,
               !oslist.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "windows" })
            { continue }
            if let language = config?["language"]?.value, !language.isEmpty, language != "english" { continue }
            if config?["lowviolence"]?.value == "1" { continue }
            let size = manifest["size"]?.uint64 ?? 0
            candidates.append((Depot(depotID: depotID, manifestID: gid, size: size), config?["osarch"]?.value ?? ""))
        }
        let has64 = candidates.contains { $0.arch == "64" }
        return candidates.filter { !(has64 && $0.arch == "32") }.map(\.depot)
    }
}

struct DepotJob: Sendable {
    var depot: InstalledDepot
    var key: Data
    var manifest: DepotManifest
}
