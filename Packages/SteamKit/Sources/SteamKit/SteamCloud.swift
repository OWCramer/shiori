import CryptoKit
import Foundation

/// A file in an app's Steam Cloud, from `Cloud.GetAppFileChangelist`.
public struct CloudFile: Hashable, Sendable {
    /// The path prefix Steam stores with the file, e.g. `%GameInstall%game/saves/`.
    public var prefix: String
    /// The name under that prefix, e.g. `1-1-LT1.save`.
    public var name: String
    public var sha: Data
    public var timestamp: Date
    public var size: UInt32
    /// Deleted or forgotten on the server; nothing to download.
    public var isDeleted: Bool

    /// What `ClientFileDownload` and the upload calls name the file by.
    public var path: String { prefix + name }

    public init(prefix: String, name: String, sha: Data, timestamp: Date, size: UInt32, isDeleted: Bool = false) {
        self.prefix = prefix
        self.name = name
        self.sha = sha
        self.timestamp = timestamp
        self.size = size
        self.isDeleted = isDeleted
    }
}

/// An app's Steam Cloud save rules, from PICS `ufs/savefiles`.
public struct UFSConfig: Equatable, Sendable {
    public struct SaveRule: Equatable, Sendable {
        /// `gameinstall`, `WinAppDataRoaming`, `WinMyDocuments`, ...
        public var root: String
        /// Path under the root, `/`-separated, without leading or trailing slashes.
        public var path: String
        public var pattern: String
        public var recursive: Bool
        /// Empty means every platform.
        public var platforms: [String]

        /// The prefix Steam stores this rule's files under: `%root%path/`.
        public var cloudPrefix: String { "%\(root)%" + (path.isEmpty ? "" : path + "/") }
    }

    public var quota: UInt64?
    public var maxFiles: Int?
    public var saveRules: [SaveRule]

    public init(app: AppInfo) {
        let ufs = app.keyValues["ufs"]
        quota = ufs?["quota"]?.uint64
        maxFiles = ufs?["maxnumfiles"].flatMap { $0.value.flatMap { Int($0) } }
        saveRules = ufs?["savefiles"]?.children.compactMap { rule in
            guard let root = rule["root"]?.value else { return nil }
            let path = (rule["path"]?.value ?? "")
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return SaveRule(
                root: root,
                path: path,
                pattern: rule["pattern"]?.value ?? "*",
                recursive: rule["recursive"]?.value == "1",
                platforms: rule["platforms"]?.children.compactMap(\.value) ?? []
            )
        } ?? []
    }

    /// The rule a cloud file belongs to, matching its prefix case-insensitively (Steam's
    /// casing of roots varies: `%GameInstall%` vs `gameinstall`).
    public func rule(for file: CloudFile) -> SaveRule? {
        let prefix = file.prefix.replacingOccurrences(of: "\\", with: "/").lowercased()
        return saveRules.first { rule in
            let expected = rule.cloudPrefix.lowercased()
            return prefix == expected || (rule.recursive && prefix.hasPrefix(expected))
        }
    }
}

extension SteamSession {
    /// Every file in the app's Steam Cloud for this account. Read-only.
    public func cloudFiles(appID: UInt32) async throws -> (changeNumber: UInt64, files: [CloudFile]) {
        var request = CCloud_GetAppFileChangelist_Request()
        request.appid = appID
        request.syncedChangeNumber = 0
        let response: CCloud_GetAppFileChangelist_Response = try await loggedOnConnection().callService(
            "Cloud.GetAppFileChangelist#1", request, authenticated: true
        )
        let files = response.files.map { info in
            let prefix = info.hasPathPrefixIndex && Int(info.pathPrefixIndex) < response.pathPrefixes.count
                ? response.pathPrefixes[Int(info.pathPrefixIndex)] : ""
            return CloudFile(
                prefix: prefix,
                name: info.fileName,
                sha: info.shaFile,
                timestamp: Date(timeIntervalSince1970: TimeInterval(info.timeStamp)),
                size: info.rawFileSize,
                isDeleted: info.persistState != .kEcloudStoragePersistStatePersisted
            )
        }
        return (response.currentChangeNumber, files)
    }

    /// Downloads one cloud file and checks it against Steam's SHA-1. Read-only.
    public func cloudDownload(appID: UInt32, file: CloudFile) async throws -> Data {
        var request = CCloud_ClientFileDownload_Request()
        request.appid = appID
        request.filename = file.path
        let info: CCloud_ClientFileDownload_Response = try await loggedOnConnection().callService(
            "Cloud.ClientFileDownload#1", request, authenticated: true
        )
        guard !info.urlHost.isEmpty, !info.encrypted else {
            throw SteamError.contentUnavailable("\(file.name) from Steam Cloud")
        }
        // Steam's url_path isn't always valid percent-encoding for URLComponents (it traps),
        // so build the URL from the string, escaping only what the string form won't take.
        let scheme = info.useHTTPS ? "https" : "http"
        let raw = "\(scheme)://\(info.urlHost)\(info.urlPath)"
        guard let url = URL(string: raw)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed.union(.urlQueryAllowed)).flatMap(URL.init(string:))
        else { throw URLError(.badURL) }
        var http = URLRequest(url: url)
        for header in info.requestHeaders { http.setValue(header.value, forHTTPHeaderField: header.name) }

        let (body, response) = try await configuration.urlSession.data(for: http)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SteamError.contentUnavailable("\(file.name) from Steam Cloud")
        }
        // Larger files are stored as a one-entry zip; the sizes differ when they are.
        let data = info.fileSize != info.rawFileSize ? try Zip.firstEntry(body) : body
        guard data.count == Int(info.rawFileSize), Data(Insecure.SHA1.hash(data: data)) == info.shaFile else {
            throw SteamError.contentUnavailable("\(file.name) from Steam Cloud (checksum mismatch)")
        }
        return data
    }
}
