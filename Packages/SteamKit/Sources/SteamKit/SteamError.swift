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
    /// The QR challenge timed out or was declined before being approved.
    case qrSignInExpired
    /// The operation needs a logged-on (not anonymous) session.
    case notLoggedOn
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
        case .qrSignInExpired: "The QR code expired. Start sign-in again."
        case .notLoggedOn: "Sign in to Steam first."
        }
    }
}
