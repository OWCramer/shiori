import Foundation
import SwiftProtobuf

/// A Steam client session: QR sign-in, logon with the stored refresh token, heartbeat,
/// automatic reconnect, and library lookups through PICS.
///
/// One connection at a time, and requests are made one after another as the official
/// client does.
public actor SteamSession {
    public let configuration: SteamConfiguration
    public private(set) var state: SessionState = .signedOut {
        didSet { if state != oldValue { for observer in observers.values { observer.yield(state) } } }
    }

    private let store: SessionStore
    private var connection: CMConnection?
    private var servers: [CMServer] = []
    private var serverIndex = 0
    private var cellID: UInt32 = 0

    /// True while the user is signed in; drives automatic reconnect.
    private var staysLoggedOn = false
    private var heartbeatTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    private var licenseList: [License]?
    private var licenseWaiters: [CheckedContinuation<[License], Error>] = []
    private var observers: [UUID: AsyncStream<SessionState>.Continuation] = [:]

    public init(configuration: SteamConfiguration, store: SessionStore) {
        self.configuration = configuration
        self.store = store
    }

    /// The current state, then every change.
    public func stateUpdates() -> AsyncStream<SessionState> {
        let (stream, continuation) = AsyncStream<SessionState>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }

    /// Account name of the stored session, if one exists.
    public var storedAccountName: String? { (try? store.load())?.accountName }

    // MARK: - Sign-in

    /// Logs on with the refresh token from a previous sign-in. If Steam can't be reached,
    /// keeps retrying in the background and reports `.reconnecting`.
    public func resume() async throws {
        guard let stored = try store.load() else {
            state = .signedOut
            throw SteamError.notSignedIn
        }
        staysLoggedOn = true
        do {
            try await logOn(with: stored)
        } catch SteamError.sessionExpired {
            throw SteamError.sessionExpired
        } catch {
            scheduleReconnect()
            throw error
        }
    }

    /// Starts a QR sign-in. The stream yields challenge URLs to display (or open in the
    /// Steam app on the same device) and finishes with `.signedIn` once approved.
    /// Cancelling the consuming task abandons the attempt.
    public nonisolated func beginQRSignIn() -> AsyncThrowingStream<QRSignInEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.runQRSignIn(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runQRSignIn(_ events: AsyncThrowingStream<QRSignInEvent, Error>.Continuation) async {
        do {
            state = .connecting
            let connection = try await connect()
            state = .connectedAnonymously

            var request = CAuthentication_BeginAuthSessionViaQR_Request()
            request.websiteID = "Client"
            request.deviceDetails.deviceFriendlyName = configuration.deviceName
            request.deviceDetails.platformType = .kEauthTokenPlatformTypeSteamClient
            request.deviceDetails.osType = configuration.osType
            let begin: CAuthentication_BeginAuthSessionViaQR_Response = try await connection.callService(
                "Authentication.BeginAuthSessionViaQR#1", request, authenticated: false
            )
            if let url = URL(string: begin.challengeURL) { events.yield(.challenge(url)) }

            var clientID = begin.clientID
            var sawRemoteInteraction = false
            while true {
                try await Task.sleep(for: .seconds(Double(max(begin.interval, 1))))

                var poll = CAuthentication_PollAuthSessionStatus_Request()
                poll.clientID = clientID
                poll.requestID = begin.requestID
                let status: CAuthentication_PollAuthSessionStatus_Response
                do {
                    status = try await connection.callService(
                        "Authentication.PollAuthSessionStatus#1", poll, authenticated: false
                    )
                } catch let SteamError.serviceCallFailed(_, result) where [.expired, .fileNotFound, .fail].contains(result) {
                    throw SteamError.qrSignInExpired
                }

                if status.newClientID != 0 { clientID = status.newClientID }
                if !status.newChallengeURL.isEmpty, let url = URL(string: status.newChallengeURL) {
                    events.yield(.challenge(url))
                }
                if status.hadRemoteInteraction, !sawRemoteInteraction {
                    sawRemoteInteraction = true
                    events.yield(.awaitingConfirmation)
                }
                if !status.refreshToken.isEmpty {
                    let stored = StoredSession(accountName: status.accountName, refreshToken: status.refreshToken)
                    try store.save(stored)
                    staysLoggedOn = true
                    try await logOn(with: stored)
                    events.yield(.signedIn(accountName: stored.accountName))
                    events.finish()
                    return
                }
            }
        } catch {
            if !staysLoggedOn {
                await disconnect()
                state = .signedOut
            }
            events.finish(throwing: error)
        }
    }

    /// Logs off, closes the connection and forgets the refresh token.
    public func signOut() async {
        staysLoggedOn = false
        reconnectTask?.cancel()
        reconnectTask = nil
        if let connection, case .loggedOn = state {
            try? await connection.send(Packet(emsg: .kEmsgClientLogOff))
        }
        await disconnect()
        try? store.delete()
        licenseList = nil
        state = .signedOut
    }

    /// Logs on with no account. Public app info is readable this way; used by the
    /// command-line smoke test to capture fixtures.
    public func logOnAnonymously() async throws {
        state = .connecting
        let connection = try await connect()
        var logon = baseLogon()
        logon.clientOsType = UInt32(bitPattern: configuration.osType)
        let anonymous = SteamID(rawValue: (1 << 56) | (10 << 52))
        let steamID = try await sendLogon(logon, as: anonymous, on: connection)
        state = .loggedOn(accountName: "anonymous", steamID: steamID)
    }

    private func logOn(with stored: StoredSession) async throws {
        state = .connecting
        let connection = try await connect()
        var logon = baseLogon()
        logon.accountName = stored.accountName
        logon.accessToken = stored.refreshToken
        logon.shouldRememberPassword = true
        logon.machineName = configuration.deviceName
        logon.chatMode = 2 // new Steam chat
        logon.clientPackageVersion = 1771
        logon.supportsRateLimitResponse = true
        var ip = CMsgIPAddress()
        ip.v4 = configuration.loginID
        logon.obfuscatedPrivateIp = ip
        logon.deprecatedObfustucatedPrivateIp = configuration.loginID

        do {
            let steamID = try await sendLogon(logon, as: .individual(accountID: 0), on: connection)
            state = .loggedOn(accountName: stored.accountName, steamID: steamID)
        } catch let SteamError.logonFailed(result) where Self.meansBadToken(result) {
            staysLoggedOn = false
            await disconnect()
            try? store.delete()
            state = .signedOut
            throw SteamError.sessionExpired
        }
    }

    private func baseLogon() -> CMsgClientLogon {
        var logon = CMsgClientLogon()
        logon.protocolVersion = currentProtocol
        logon.clientOsType = UInt32(bitPattern: configuration.osType)
        logon.clientLanguage = configuration.language
        logon.cellID = cellID
        logon.machineID = configuration.machineID
        return logon
    }

    private func sendLogon(_ logon: CMsgClientLogon, as steamID: SteamID, on connection: CMConnection) async throws -> SteamID {
        await connection.setIdentity(steamID: steamID.rawValue, sessionID: 0)
        let reply = try await connection.call(
            Packet(emsg: .kEmsgClientLogon, message: logon),
            replyEMsg: .kEmsgClientLogOnResponse
        )[0]
        let response: CMsgClientLogonResponse = try reply.decode()
        let result = EResult(rawValue: response.eresult)
        guard result == .ok else { throw SteamError.logonFailed(result) }

        await connection.setIdentity(steamID: reply.header.steamid, sessionID: reply.header.clientSessionid)
        if response.cellID != 0 { cellID = response.cellID }
        startHeartbeat(on: connection, every: response.heartbeatSeconds)
        return SteamID(rawValue: reply.header.steamid)
    }

    private static func meansBadToken(_ result: EResult) -> Bool {
        [.invalidPassword, .accessDenied, .expired, .revoked, .invalidSignature].contains(result)
    }

    // MARK: - Connection

    private func connect() async throws -> CMConnection {
        if let connection, await !connection.isClosed { return connection }
        if servers.isEmpty || serverIndex >= servers.count {
            servers = try await CMDirectory.fetch(cellID: cellID, urlSession: configuration.urlSession)
            serverIndex = 0
        }
        let connection = CMConnection(server: servers[serverIndex], urlSession: configuration.urlSession)
        do {
            try await connection.open()
        } catch {
            serverIndex += 1
            throw error
        }
        self.connection = connection
        Task { [weak self] in
            for await packet in connection.unsolicited {
                await self?.handleUnsolicited(packet)
            }
            await self?.connectionClosed(connection)
        }
        return connection
    }

    private func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await connection?.close()
        connection = nil
    }

    private func connectionClosed(_ closed: CMConnection) {
        guard closed === connection else { return }
        connection = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        for waiter in licenseWaiters { waiter.resume(throwing: SteamError.disconnected) }
        licenseWaiters.removeAll()
        if staysLoggedOn {
            serverIndex += 1
            scheduleReconnect()
        } else if state != .connecting {
            state = .signedOut
        }
    }

    private func scheduleReconnect() {
        guard reconnectTask == nil, staysLoggedOn else { return }
        // Inherits the actor's isolation, so state can be touched directly.
        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled, staysLoggedOn {
                attempt += 1
                state = .reconnecting(attempt: attempt)
                try? await Task.sleep(for: .seconds(min(60, 1 << min(attempt - 1, 6))))
                guard !Task.isCancelled else { break }
                do {
                    try await reconnectOnce()
                    break
                } catch SteamError.sessionExpired, SteamError.notSignedIn {
                    break
                } catch {
                    serverIndex += 1
                }
            }
            if !Task.isCancelled { reconnectTask = nil }
        }
    }

    private func reconnectOnce() async throws {
        guard let stored = try store.load() else { throw SteamError.notSignedIn }
        try await logOn(with: stored)
    }


    private func startHeartbeat(on connection: CMConnection, every seconds: Int32) {
        heartbeatTask?.cancel()
        let interval = Duration.seconds(max(Int(seconds), 9))
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                try? await connection.send(Packet(emsg: .kEmsgClientHeartBeat, message: CMsgClientHeartBeat()))
            }
        }
    }

    private func handleUnsolicited(_ packet: Packet) async {
        switch packet.knownEMsg {
        case .kEmsgClientLicenseList:
            guard let list = try? packet.decode(CMsgClientLicenseList.self) else { return }
            let licenses = list.licenses.map(License.init)
            licenseList = licenses
            for waiter in licenseWaiters { waiter.resume(returning: licenses) }
            licenseWaiters.removeAll()
        case .kEmsgClientLoggedOff:
            // Steam ended the session (e.g. maintenance). Dropping the socket lets the
            // reconnect path log on again, or surface an expired token.
            await connection?.close()
        default:
            break
        }
    }

    private func loggedOnConnection() throws -> CMConnection {
        guard case .loggedOn = state, let connection else { throw SteamError.notLoggedOn }
        return connection
    }

    // MARK: - Library

    /// Licences on the account, as sent by Steam right after logon.
    public func licenses() async throws -> [License] {
        _ = try loggedOnConnection()
        if let licenseList { return licenseList }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(30))
            self.failLicenseWaiters()
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { licenseWaiters.append($0) }
    }

    private func failLicenseWaiters() {
        for waiter in licenseWaiters { waiter.resume(throwing: SteamError.timeout) }
        licenseWaiters.removeAll()
    }

    public func packageInfo(for licenses: [License]) async throws -> [PackageInfo] {
        var packages: [PackageInfo] = []
        for batch in licenses.chunked(into: 200) {
            var request = CMsgClientPICSProductInfoRequest()
            request.packages = batch.map {
                var package = CMsgClientPICSProductInfoRequest.PackageInfo()
                package.packageid = $0.packageID
                package.accessToken = $0.accessToken
                return package
            }
            for response in try await productInfo(request) {
                for package in response.packages where !package.buffer.isEmpty {
                    packages.append(PackageInfo(
                        packageID: package.packageid,
                        keyValues: try KeyValue.parsePackageInfo(package.buffer)
                    ))
                }
            }
        }
        return packages
    }

    /// PICS app info, requesting access tokens first so owned private data is included.
    public func appInfo(_ appIDs: [UInt32]) async throws -> [AppInfo] {
        let connection = try loggedOnConnection()
        var apps: [AppInfo] = []
        for batch in appIDs.chunked(into: 200) {
            var tokenRequest = CMsgClientPICSAccessTokenRequest()
            tokenRequest.appids = Array(batch)
            let tokenReply: CMsgClientPICSAccessTokenResponse = try await connection.call(
                Packet(emsg: .kEmsgClientPicsaccessTokenRequest, message: tokenRequest),
                replyEMsg: .kEmsgClientPicsaccessTokenResponse
            )[0].decode()
            let tokens = Dictionary(
                tokenReply.appAccessTokens.map { ($0.appid, $0.accessToken) },
                uniquingKeysWith: { first, _ in first }
            )

            var request = CMsgClientPICSProductInfoRequest()
            request.apps = batch.map {
                var app = CMsgClientPICSProductInfoRequest.AppInfo()
                app.appid = $0
                app.accessToken = tokens[$0] ?? 0
                return app
            }
            for response in try await productInfo(request) {
                for app in response.apps {
                    guard let keyValues = try await appKeyValues(app, httpHost: response.httpHost) else { continue }
                    apps.append(AppInfo(appID: app.appid, changeNumber: app.changeNumber, keyValues: keyValues))
                }
            }
        }
        return apps
    }

    /// Games the account owns (active licences, `common.type == game`), sorted by name.
    public func ownedApps() async throws -> [AppInfo] {
        // Package 0 is the base "Steam" licence every account has; it doesn't represent owned games.
        let licenses = try await licenses().filter { !$0.isRevoked && $0.packageID != 0 }
        let packages = try await packageInfo(for: licenses)
        let appIDs = Set(packages.flatMap(\.appIDs)).sorted()
        return try await appInfo(appIDs)
            .filter(\.isGame)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func productInfo(_ request: CMsgClientPICSProductInfoRequest) async throws -> [CMsgClientPICSProductInfoResponse] {
        let connection = try loggedOnConnection()
        let replies = try await connection.call(
            Packet(emsg: .kEmsgClientPicsproductInfoRequest, message: request),
            replyEMsg: .kEmsgClientPicsproductInfoResponse,
            timeout: .seconds(60),
            isComplete: { (try? $0.decode(CMsgClientPICSProductInfoResponse.self))?.responsePending != true }
        )
        return try replies.map { try $0.decode() }
    }

    /// Inline buffer, or for large apps the gzipped copy PICS points to over HTTP.
    private func appKeyValues(_ app: CMsgClientPICSProductInfoResponse.AppInfo, httpHost: String) async throws -> KeyValue? {
        if !app.buffer.isEmpty { return try KeyValue.parseText(app.buffer) }
        guard !httpHost.isEmpty, !app.sha.isEmpty else { return nil }
        let sha = app.sha.map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "https://\(httpHost)/appinfo/\(app.appid)/sha/\(sha).txt.gz") else { return nil }
        let (data, response) = try await configuration.urlSession.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try KeyValue.parseText(Gzip.decompress(data))
    }
}

extension CMConnection {
    func setIdentity(steamID: UInt64, sessionID: Int32) {
        self.steamID = steamID
        self.sessionID = sessionID
    }
}

extension Array {
    func chunked(into size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0 ..< Swift.min($0 + size, count)] }
    }
}

// MARK: - Debug

extension SteamSession {
    /// Raw PICS buffers, for capturing test fixtures from the command-line tool.
    @_spi(Debug) public func rawProductInfo(apps: [UInt32], packages: [License]) async throws
        -> (apps: [UInt32: Data], packages: [UInt32: Data])
    {
        var request = CMsgClientPICSProductInfoRequest()
        request.apps = apps.map {
            var app = CMsgClientPICSProductInfoRequest.AppInfo()
            app.appid = $0
            return app
        }
        request.packages = packages.map {
            var package = CMsgClientPICSProductInfoRequest.PackageInfo()
            package.packageid = $0.packageID
            package.accessToken = $0.accessToken
            return package
        }
        var result: (apps: [UInt32: Data], packages: [UInt32: Data]) = ([:], [:])
        for response in try await productInfo(request) {
            for app in response.apps { result.apps[app.appid] = app.buffer }
            for package in response.packages { result.packages[package.packageid] = package.buffer }
        }
        return result
    }
}
