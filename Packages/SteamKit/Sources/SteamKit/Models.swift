// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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

    /// Steam store tag ids, most relevant first.
    public var storeTags: [UInt32] { keyValues[path: "common", "store_tags"]?.children.compactMap(\.uint32) ?? [] }

    /// Steam's "Visual Novel" store tag.
    public static let visualNovelTag: UInt32 = 3799
    public var isVisualNovel: Bool { storeTags.contains(Self.visualNovelTag) }

    /// Names from the store's `associations` of one type: "developer", "publisher" or
    /// "franchise" (NEKOPARA, Sakura; some publishers file their own name as the franchise).
    public func associations(_ type: String) -> [String] {
        keyValues[path: "common", "associations"]?.children.compactMap { entry in
            guard entry["type"]?.value?.caseInsensitiveCompare(type) == .orderedSame else { return nil }
            return entry["name"]?.value.flatMap { $0.isEmpty ? nil : $0 }
        } ?? []
    }

    /// When the game first came out: the original release where the store records one
    /// (a port of an older game), else its Steam release.
    public var releaseDate: Date? {
        let dates = ["original_release_date", "steam_release_date"].compactMap { key in
            keyValues[path: "common", key]?.value.flatMap(TimeInterval.init).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        }
        return dates.min()
    }

    /// Portrait library capsule (600×900, or 1200×1800 with `large`).
    public func capsuleURL(large: Bool = false) -> URL? {
        libraryAsset("library_capsule", large: large) ?? assetURL(large ? "library_600x900_2x.jpg" : "library_600x900.jpg")
    }

    /// Wide library hero banner.
    public func heroURL(large: Bool = false) -> URL? {
        libraryAsset("library_hero", large: large) ?? assetURL(large ? "library_hero_2x.jpg" : "library_hero.jpg")
    }

    /// Transparent title logo drawn over the hero.
    public func logoURL(large: Bool = false) -> URL? {
        libraryAsset("library_logo", large: large)
    }

    /// Landscape store header (460×215), the fallback when a game has no library art.
    public var headerURL: URL? {
        assetURL(keyValues[path: "common", "header_image", "english"]?.value ?? "header.jpg")
    }

    private func libraryAsset(_ kind: String, large: Bool) -> URL? {
        let images = keyValues[path: "common", "library_assets_full", kind]
        let image = (large ? images?["image2x"] : nil) ?? images?["image"]
        guard let file = image?["english"]?.value ?? image?.children.first?.value else { return nil }
        return assetURL(file)
    }

    /// Store assets live on Steam's public CDN, keyed by app id; newer ones carry a hash path.
    private func assetURL(_ file: String) -> URL? {
        URL(string: "https://shared.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(file)")
    }

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
    public var depotIDs: [UInt32] { keyValues["depotids"]?.children.compactMap(\.uint32) ?? [] }
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

public enum SignInEvent: Equatable, Sendable {
    /// QR sign-in: show this URL as a QR code to scan with the Steam app on another device.
    /// Steam rotates the challenge, so a new URL can arrive while waiting.
    case challenge(URL)
    /// Password sign-in: how Steam wants this sign-in confirmed.
    case steamGuard(SteamGuardPrompt)
    /// QR sign-in: the code was scanned; waiting for approval in the Steam app.
    case awaitingConfirmation
    /// Approved, token stored and logged on.
    case signedIn(accountName: String)
}

public struct SteamGuardPrompt: Equatable, Sendable {
    public enum CodeKind: Equatable, Sendable {
        /// Code from the Steam Guard authenticator in the Steam app.
        case authenticator
        /// Code emailed to the account.
        case email
    }

    /// A sign-in request appears in the Steam app (works on the same phone).
    public var canApproveInSteamApp: Bool
    /// A confirmation link is emailed.
    public var canConfirmByEmail: Bool
    /// A code can be typed in and sent with `submitSteamGuardCode`.
    public var code: CodeKind?
    /// For email codes, the address domain Steam sent it to.
    public var emailHint: String?
}
