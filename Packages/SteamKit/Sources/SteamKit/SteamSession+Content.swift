import Foundation

/// A content (CDN) server from `ContentServerDirectory.GetServersForSteamPipe`.
public struct ContentServer: Hashable, Sendable {
    public var host: String
    public var vhost: String
    public var type: String
    public var weightedLoad: Float
    public var entries: Int
    public var allowedAppIDs: [UInt32]
    public var httpsSupport: String

    init(_ info: CContentServerDirectory_ServerInfo) {
        host = info.host
        vhost = info.vhost.isEmpty ? info.host : info.vhost
        type = info.type
        weightedLoad = info.weightedLoad
        entries = Int(max(1, info.numEntriesInClientList))
        allowedAppIDs = info.allowedAppIds
        httpsSupport = info.httpsSupport
    }

    /// Whether this server can serve `appID` over HTTPS (the app's ATS policy allows nothing else).
    func canServe(appID: UInt32) -> Bool {
        (type == "CDN" || type == "SteamCache")
            && (allowedAppIDs.isEmpty || allowedAppIDs.contains(appID))
            && (httpsSupport == "mandatory" || httpsSupport == "optional")
    }
}

extension SteamSession {
    /// AES key for a depot the account owns.
    public func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        var request = CMsgClientGetDepotDecryptionKey()
        request.depotID = depotID
        request.appID = appID
        let response: CMsgClientGetDepotDecryptionKeyResponse = try await loggedOnConnection().call(
            Packet(emsg: .kEmsgClientGetDepotDecryptionKey, message: request),
            replyEMsg: .kEmsgClientGetDepotDecryptionKeyResponse
        )[0].decode()
        let result = EResult(rawValue: response.eresult)
        guard result == .ok, response.depotEncryptionKey.count == 32 else {
            throw SteamError.depotAccessDenied(depotID: depotID, result: result)
        }
        return response.depotEncryptionKey
    }

    /// Short-lived code the CDN requires to serve a manifest.
    public func manifestRequestCode(appID: UInt32, depotID: UInt32, manifestID: UInt64, branch: String = "public") async throws -> UInt64 {
        var request = CContentServerDirectory_GetManifestRequestCode_Request()
        request.appID = appID
        request.depotID = depotID
        request.manifestID = manifestID
        if branch.caseInsensitiveCompare("public") != .orderedSame { request.appBranch = branch }
        let response: CContentServerDirectory_GetManifestRequestCode_Response = try await loggedOnConnection().callService(
            "ContentServerDirectory.GetManifestRequestCode#1", request, authenticated: true
        )
        return response.manifestRequestCode
    }

    /// CDN servers for this client's cell, best first.
    public func contentServers() async throws -> [ContentServer] {
        var request = CContentServerDirectory_GetServersForSteamPipe_Request()
        request.cellID = cellID
        let response: CContentServerDirectory_GetServersForSteamPipe_Response = try await loggedOnConnection().callService(
            "ContentServerDirectory.GetServersForSteamPipe#1", request, authenticated: true
        )
        return response.servers.map(ContentServer.init).sorted { $0.weightedLoad < $1.weightedLoad }
    }

    /// Token some CDN hosts want appended to requests for a depot.
    public func cdnAuthToken(appID: UInt32, depotID: UInt32, host: String) async throws -> String {
        var request = CContentServerDirectory_GetCDNAuthToken_Request()
        request.appID = appID
        request.depotID = depotID
        request.hostName = host
        let response: CContentServerDirectory_GetCDNAuthToken_Response = try await loggedOnConnection().callService(
            "ContentServerDirectory.GetCDNAuthToken#1", request, authenticated: true
        )
        return response.token
    }
}
