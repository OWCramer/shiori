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

// MARK: - Uploads and the app-session handshake
//
// These write to the account's Steam Cloud, the same store the PC client syncs from.
// VN Hub only calls them once uploads are switched on, and backs up each remote file
// before replacing it.

/// Another device's Steam session for an app, reported at launch.
public struct CloudPendingOperation: Hashable, Sendable {
    public var machineName: String
    /// e.g. "app session active" — the game is still running elsewhere.
    public var description: String
}

/// One file to upload: where it goes in the cloud and its contents.
public struct CloudUpload: Sendable {
    /// Full cloud path, prefix included: `%GameInstall%game/saves/1-1-LT1.save`.
    public var path: String
    public var data: Data
    public var timestamp: Date

    public init(path: String, data: Data, timestamp: Date) {
        self.path = path
        self.data = data
        self.timestamp = timestamp
    }
}

extension SteamSession {
    /// Tells Steam this device is starting the app. Returns sessions on other devices
    /// that haven't finished syncing (the PC still running the game, for instance).
    public func cloudLaunchIntent(appID: UInt32, clientID: UInt64) async throws -> [CloudPendingOperation] {
        var request = CCloud_AppLaunchIntent_Request()
        request.appid = appID
        request.clientID = clientID
        request.machineName = configuration.deviceName
        request.osType = configuration.osType
        let response: CCloud_AppLaunchIntent_Response = try await loggedOnConnection().callService(
            "Cloud.SignalAppLaunchIntent#1", request, authenticated: true
        )
        return response.pendingRemoteOperations.map { operation in
            let description = switch operation.operation {
            case .kEcloudPendingRemoteOperationAppSessionActive: "game running"
            case .kEcloudPendingRemoteOperationAppSessionSuspended: "game suspended"
            case .kEcloudPendingRemoteOperationUploadInProgress: "uploading saves"
            case .kEcloudPendingRemoteOperationUploadPending: "upload pending"
            default: "busy"
            }
            return CloudPendingOperation(machineName: operation.machineName, description: description)
        }
    }

    /// Tells Steam this device has finished with the app and its saves are synced.
    public func cloudExitSyncDone(appID: UInt32, clientID: UInt64, uploadsCompleted: Bool, uploadsRequired: Bool) async throws {
        var notification = CCloud_AppExitSyncDone_Notification()
        notification.appid = appID
        notification.clientID = clientID
        notification.uploadsCompleted = uploadsCompleted
        notification.uploadsRequired = uploadsRequired
        try await loggedOnConnection().notifyService("Cloud.SignalAppExitSyncDone#1", notification)
    }

    /// Uploads files as one batch, the way the Steam client does, so the PC sees a normal
    /// sync. Returns the paths that committed.
    public func cloudUpload(appID: UInt32, clientID: UInt64, buildID: UInt64, files: [CloudUpload]) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let connection = try loggedOnConnection()

        var begin = CCloud_BeginAppUploadBatch_Request()
        begin.appid = appID
        begin.machineName = configuration.deviceName
        begin.filesToUpload = files.map(\.path)
        begin.clientID = clientID
        begin.appBuildID = buildID
        let batch: CCloud_BeginAppUploadBatch_Response = try await connection.callService(
            "Cloud.BeginAppUploadBatch#1", begin, authenticated: true
        )

        var committed: [String] = []
        var batchSucceeded = true
        for file in files {
            let sha = Data(Insecure.SHA1.hash(data: file.data))
            var request = CCloud_ClientBeginFileUpload_Request()
            request.appid = appID
            request.fileSize = UInt32(file.data.count)
            request.rawFileSize = UInt32(file.data.count)
            request.fileSha = sha
            request.timeStamp = UInt64(file.timestamp.timeIntervalSince1970)
            request.filename = file.path
            request.cellID = cellID
            request.canEncrypt = false
            request.uploadBatchID = batch.batchID
            let plan: CCloud_ClientBeginFileUpload_Response = try await connection.callService(
                "Cloud.ClientBeginFileUpload#1", request, authenticated: true
            )

            var transferred = !plan.encryptFile
            if transferred {
                for block in plan.blockRequests {
                    do {
                        try await putBlock(block, of: file.data)
                    } catch {
                        transferred = false
                        break
                    }
                }
            }

            var commit = CCloud_ClientCommitFileUpload_Request()
            commit.transferSucceeded = transferred
            commit.appid = appID
            commit.fileSha = sha
            commit.filename = file.path
            let result: CCloud_ClientCommitFileUpload_Response = try await connection.callService(
                "Cloud.ClientCommitFileUpload#1", commit, authenticated: true
            )
            if transferred, result.fileCommitted { committed.append(file.path) } else { batchSucceeded = false }
        }

        var complete = CCloud_CompleteAppUploadBatch_Request()
        complete.appid = appID
        complete.batchID = batch.batchID
        complete.batchEresult = UInt32(bitPattern: batchSucceeded ? EResult.ok.rawValue : EResult.fail.rawValue)
        let _: CCloud_CompleteAppUploadBatch_Response = try await connection.callService(
            "Cloud.CompleteAppUploadBatchBlocking#1", complete, authenticated: true
        )
        return committed
    }

    private func putBlock(_ block: ClientCloudFileUploadBlockDetails, of data: Data) async throws {
        let raw = "\(block.useHTTPS ? "https" : "http")://\(block.urlHost)\(block.urlPath)"
        guard let url = URL(string: raw) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        // http_method is an EHTTPMethod (GET 1, HEAD 2, POST 3, PUT 4); Steam sends PUT.
        request.httpMethod = block.httpMethod == 3 ? "POST" : "PUT"
        for header in block.requestHeaders { request.setValue(header.value, forHTTPHeaderField: header.name) }
        request.setValue("Valve/Steam HTTP Client 1.0", forHTTPHeaderField: "User-Agent")
        let body: Data
        if block.hasExplicitBodyData {
            body = block.explicitBodyData
        } else {
            let start = Int(block.blockOffset)
            let end = min(data.count, start + Int(block.blockLength))
            guard start <= end else { throw SteamError.contentUnavailable("an upload block") }
            body = data.subdata(in: start ..< end)
        }
        let (_, response) = try await configuration.urlSession.upload(for: request, from: body)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200 ..< 300).contains(status) else {
            throw SteamError.contentUnavailable("an upload block")
        }
    }
}
