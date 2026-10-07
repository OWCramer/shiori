import Foundation

/// A package licence from `ClientLicenseList`.
public struct License: Hashable, Sendable {
    public var packageID: UInt32
    public var accessToken: UInt64
    public var flags: UInt32
    public var licenseType: UInt32

    /// Expired, or cancelled by the user or by Steam.
    public var isRevoked: Bool { flags & (0x08 | 0x10 | 0x20) != 0 }

    public init(packageID: UInt32, accessToken: UInt64 = 0, flags: UInt32 = 0, licenseType: UInt32 = 0) {
        self.packageID = packageID
        self.accessToken = accessToken
        self.flags = flags
        self.licenseType = licenseType
    }

    init(_ license: CMsgClientLicenseList.License) {
        packageID = license.packageID
        accessToken = license.accessToken
        flags = license.flags
        licenseType = license.licenseType
    }
}

/// PICS product info for an app. The full tree is kept for later phases
/// (depots, launch config, `ufs` cloud rules); the common fields are surfaced here.
public struct AppInfo: Hashable, Sendable, Identifiable {
    public var appID: UInt32
    public var changeNumber: UInt32
    public var keyValues: KeyValue

    public var id: UInt32 { appID }
    public var name: String { keyValues[path: "common", "name"]?.value ?? "App \(appID)" }
    /// "Game", "DLC", "Application", "Tool", "Demo", ... (Steam's casing varies).
    public var type: String { keyValues[path: "common", "type"]?.value ?? "" }
    public var isGame: Bool { type.caseInsensitiveCompare("game") == .orderedSame }

    public init(appID: UInt32, changeNumber: UInt32, keyValues: KeyValue) {
        self.appID = appID
        self.changeNumber = changeNumber
        self.keyValues = keyValues
    }
}

/// PICS product info for a package.
public struct PackageInfo: Hashable, Sendable {
    public var packageID: UInt32
    public var keyValues: KeyValue

    public var appIDs: [UInt32] { keyValues["appids"]?.children.compactMap(\.uint32) ?? [] }
}

public enum SessionState: Equatable, Sendable {
    case signedOut
    case connecting
    /// Connected without an account, e.g. while a QR code is on screen.
    case connectedAnonymously
    case loggedOn(accountName: String, steamID: SteamID)
    /// The connection dropped; SteamKit is reconnecting with the stored token.
    case reconnecting(attempt: Int)
}

public enum QRSignInEvent: Equatable, Sendable {
    /// Show this URL as a QR code, or open it on the same device to approve in the Steam app.
    /// Steam rotates the challenge, so a new URL can arrive while waiting.
    case challenge(URL)
    /// The Steam app has the prompt open but hasn't approved yet.
    case awaitingConfirmation
    /// Approved, token stored and logged on.
    case signedIn(accountName: String)
}
