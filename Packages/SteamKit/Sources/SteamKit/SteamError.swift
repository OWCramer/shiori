public enum SteamError: Error, Equatable, Sendable {
    /// The CM directory could not be fetched or returned no WebSocket servers.
    case directoryUnavailable
    /// The connection to the CM closed or was never open.
    case disconnected
    /// No reply arrived in time.
    case timeout
    /// A unified-service method (e.g. `Authentication.PollAuthSessionStatus#1`) returned an error.
    case serviceCallFailed(method: String, result: EResult)
    /// `ClientLogon` was rejected.
    case logonFailed(EResult)
    /// No refresh token is stored; the user needs to sign in.
    case notSignedIn
    /// The stored refresh token was rejected, so it has been deleted and the user must sign in again.
    case sessionExpired
    /// The sign-in timed out or was declined before being approved.
    case signInExpired
    /// Wrong account name or password.
    case invalidCredentials
    /// The Steam Guard code was wrong or expired.
    case invalidSteamGuardCode
    /// Too many sign-in attempts; Steam asks to wait before trying again.
    case rateLimited
    /// The operation needs a logged-on (not anonymous) session.
    case notLoggedOn
    /// Steam wouldn't hand out the key for a depot (usually: not owned).
    case depotAccessDenied(depotID: UInt32, result: EResult)
    /// The app has no Windows depots this account can download.
    case noDownloadableDepots(appID: UInt32)
    /// No content server offered HTTPS for this app.
    case noContentServers
    /// A chunk or manifest couldn't be fetched from any content server.
    case contentUnavailable(String)
    /// The manifest names a path outside the install folder.
    case unsafePath(String)
}

extension SteamError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .directoryUnavailable: "Couldn't reach Steam's server directory."
        case .disconnected: "Lost the connection to Steam."
        case .timeout: "Steam didn't answer in time."
        case let .serviceCallFailed(method, result): "\(method) failed: \(result)."
        case let .logonFailed(result): "Steam rejected the sign-in: \(result)."
        case .notSignedIn: "Not signed in to Steam."
        case .sessionExpired: "Your Steam session has expired. Sign in again."
        case .signInExpired: "The sign-in request expired. Start again."
        case .invalidCredentials: "Incorrect account name or password."
        case .invalidSteamGuardCode: "That Steam Guard code wasn't accepted. Check it and try again."
        case .rateLimited: "Too many sign-in attempts. Wait a while and try again."
        case .notLoggedOn: "Sign in to Steam first."
        case let .depotAccessDenied(depotID, result): "Steam refused access to depot \(depotID): \(result)."
        case .noDownloadableDepots: "This game has no Windows build this account can download."
        case .noContentServers: "No Steam content server is available right now."
        case let .contentUnavailable(what): "Couldn't download \(what) from Steam. Check the connection and resume."
        case let .unsafePath(path): "The game's file list has an invalid path: \(path)."
        }
    }
}

extension SteamError {
    /// Steam answered and refused, as opposed to the connection failing.
    var isServiceFailure: Bool {
        switch self {
        case .disconnected, .timeout, .directoryUnavailable: false
        default: true
        }
    }
}
