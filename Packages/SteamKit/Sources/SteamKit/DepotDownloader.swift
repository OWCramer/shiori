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

    public init(phase: Phase, totalBytes: UInt64, completedBytes: UInt64, downloadedBytes: UInt64) {
        self.phase = phase
        self.totalBytes = totalBytes
        self.completedBytes = completedBytes
        self.downloadedBytes = downloadedBytes
    }
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

    /// How many of a finished install's files are missing or the wrong size, by stat alone
    /// (no hashing), so a check is cheap enough to run at every launch. Nil when there's no
    /// finished install with its manifests to compare against. Downloading again re-fetches
    /// exactly those files.
    public func missingFileCount() -> Int? {
        guard let depots = installedDepots else { return nil }
        let fm = FileManager.default
        var missing = 0
        for depot in depots {
            guard let manifest = loadManifest(depot) else { return nil }
            for file in manifest.files where !file.isDirectory && !file.isSymlink {
                guard let url = try? fileURL(for: file.name) else { continue }
                let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
                if size != file.size { missing += 1 }
            }
        }
        return missing
    }

    /// Deletes the bookkeeping (not the game files).
    public func removeState() throws {
        if FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.removeItem(at: stateDirectory)
        }
    }
}

extension SteamSession {
    /// Downloads the app's Windows depots into `install.root`, from `branch` (a public beta
    /// such as `renpy_old`, or "public"). Cancelling the task pauses; calling again resumes
    /// from the finished chunks. Returns the installed depot builds.
    public func download(
        appID: UInt32,
        branch: String = "public",
        into install: DepotInstall,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> [InstalledDepot] {
        progress(DownloadProgress(phase: .preparing, totalBytes: 0, completedBytes: 0, downloadedBytes: 0))
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
            let installed = InstalledDepot(depotID: depot.depotID, manifestID: depot.manifestID)
            let key = try await depotKey(depotID: depot.depotID, appID: appID)
            let manifest: DepotManifest
            if let saved = install.loadManifest(installed) {
                manifest = saved
            } else {
                let code = try await manifestRequestCode(appID: appID, depotID: depot.depotID, manifestID: depot.manifestID, branch: branch)
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

    /// A beta branch anyone who owns the game can pick (no password), as Steam lists it in
    /// the game's Properties › Betas.
    public struct Branch: Codable, Hashable, Sendable {
        public var name: String
        public var description: String?
        public var buildID: UInt64
        public var updated: Date?
    }

    /// The app's branches without a password, "public" first, then newest first.
    public static func branches(of app: AppInfo) -> [Branch] {
        guard let section = app.keyValues[path: "depots", "branches"] else { return [] }
        var branches: [Branch] = []
        for branch in section.children where branch["pwdrequired"]?.value != "1" {
            let updated = (branch["timeupdated"]?.uint64).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let description = branch["description"]?.value
            branches.append(Branch(name: branch.name, description: description?.isEmpty == false ? description : nil,
                                   buildID: branch["buildid"]?.uint64 ?? 0, updated: updated))
        }
        return branches.sorted {
            if ($0.name == "public") != ($1.name == "public") { return $0.name == "public" }
            return ($0.updated ?? .distantPast) > ($1.updated ?? .distantPast)
        }
    }

    /// Windows (or OS-neutral) depots the account owns on `branch`, English or
    /// language-neutral, preferring 64-bit when a depot is split by architecture. A depot with
    /// no build on a beta branch isn't part of that branch, as in the Steam client.
    public static func windowsDepots(of app: AppInfo, owned: Set<UInt32>, branch: String = "public") -> [Depot] {
        guard let depots = app.keyValues["depots"] else { return [] }
        var candidates: [(depot: Depot, arch: String)] = []
        for section in depots.children {
            guard let depotID = UInt32(section.name), owned.contains(depotID),
                  let manifest = section[path: "manifests", branch],
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

/// One of a game's DLCs, as the Steam client lists them under the game.
public struct DLCInfo: Hashable, Sendable, Identifiable {
    public var appID: UInt32
    public var name: String
    public var owned: Bool
    /// The game's depots that carry this DLC's files; empty when the DLC only unlocks
    /// content the game already has (it asks Steam whether you own it).
    public var depotIDs: [UInt32]
    /// Steam's content descriptors for the DLC (3 is adult only sexual content); see
    /// `StoreContentPreferences`.
    public var contentDescriptors: [UInt32] = []
    public var id: UInt32 { appID }
}

extension SteamSession {
    /// The game's DLCs (from its PICS `listofdlc` and the depots marked with a `dlcappid`),
    /// with their names and whether the account owns them.
    public func dlcs(appID: UInt32) async throws -> [DLCInfo] {
        guard let app = try await appInfo([appID]).first else { return [] }
        var depotsByDLC: [UInt32: [UInt32]] = [:]
        for depot in app.keyValues["depots"]?.children ?? [] {
            guard let depotID = UInt32(depot.name), let dlc = depot["dlcappid"]?.uint32 else { continue }
            depotsByDLC[dlc, default: []].append(depotID)
        }
        var ids = (app.keyValues[path: "extended", "listofdlc"]?.value ?? "")
            .split(separator: ",").compactMap { UInt32($0.trimmingCharacters(in: .whitespaces)) }
        for dlc in depotsByDLC.keys where !ids.contains(dlc) { ids.append(dlc) }
        guard !ids.isEmpty else { return [] }
        let owned = try await ownedPackageContents()
        let names = Dictionary((try await appInfo(ids)).map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.map { id in
            DLCInfo(appID: id, name: names[id]?.name ?? "DLC \(id)", owned: owned.contains(id),
                    depotIDs: (depotsByDLC[id] ?? []).sorted(),
                    contentDescriptors: names[id].map { Self.contentDescriptors(of: $0.keyValues) } ?? [])
        }
        // Steam lists hidden and unreleased DLC too; drop the ones with no name and no store page.
        .filter { names[$0.appID] != nil }
    }

    /// An app's content descriptors from its PICS `common` section (`content_descriptors`, a
    /// list of ids keyed "0", "1", …).
    public static func contentDescriptors(of appInfo: KeyValue) -> [UInt32] {
        (appInfo[path: "common", "content_descriptors"]?.children ?? []).compactMap(\.uint32).sorted()
    }
}
