import CryptoKit
import Foundation
import Security

public struct SteamConfiguration: Sendable {
    /// Shown in the Steam app's approval prompt and in the account's device list.
    public var deviceName: String
    /// Stable per-install random value. The machine ID and login ID sent to Steam are
    /// derived from it, so Steam sees one consistent device across launches.
    public var deviceSeed: String
    /// Steam `EOSType` reported at logon. Default is `IOSUnknown` (-600).
    public var osType: Int32
    public var language: String
    public var urlSession: URLSession

    public init(
        deviceName: String,
        deviceSeed: String,
        osType: Int32 = -600,
        language: String = "english",
        urlSession: URLSession = .shared
    ) {
        self.deviceName = deviceName
        self.deviceSeed = deviceSeed
        self.osType = osType
        self.language = language
        self.urlSession = urlSession
    }

    /// The `MessageObject` binary KeyValues blob Steam expects in `machine_id`:
    /// three SHA-1 hex strings standing in for the machine GUID, MAC and disk serial.
    var machineID: Data {
        func hash(_ salt: String) -> String {
            Insecure.SHA1.hash(data: Data((salt + deviceSeed).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return KeyValue(name: "MessageObject", children: [
            KeyValue(name: "BB3", value: hash("BB3")),
            KeyValue(name: "FF2", value: hash("FF2")),
            KeyValue(name: "3B3", value: hash("3B3")),
        ]).binaryEncoded()
    }

    /// Sent as `obfuscated_private_ip`. A per-device value keeps this session from being
    /// mistaken for another client on the same network.
    var loginID: UInt32 {
        let digest = SHA256.hash(data: Data(("login" + deviceSeed).utf8))
        return digest.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// A signed-in account as persisted between launches. Only the refresh token is a credential.
public struct StoredSession: Codable, Equatable, Sendable {
    public var accountName: String
    public var refreshToken: String

    public init(accountName: String, refreshToken: String) {
        self.accountName = accountName
        self.refreshToken = refreshToken
    }
}

public protocol SessionStore: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func delete() throws
}

/// Keeps the session in the Keychain, readable after first unlock. With `synchronizable`,
/// it's an iCloud Keychain item, so signing in on one of the person's devices signs in the
/// others (and signing out signs them all out); otherwise it stays on this device.
public struct KeychainSessionStore: SessionStore {
    public enum Error: Swift.Error { case keychain(OSStatus) }

    public let service: String
    public let synchronizable: Bool

    public init(service: String, synchronizable: Bool = false) {
        self.service = service
        self.synchronizable = synchronizable
    }

    /// Matches the item whether it's synced or not (one saved before syncing was on).
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "steam-session",
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    public func load() throws -> StoredSession? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Error.keychain(status) }
        return try JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        try delete()
        var item = query
        item[kSecValueData as String] = try JSONEncoder().encode(session)
        item[kSecAttrSynchronizable as String] = synchronizable
        // A synced item can't be this-device-only.
        item[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw Error.keychain(status) }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Error.keychain(status) }
    }

    /// Re-saves a session stored before syncing was turned on, so it syncs too.
    public func migrateToSynchronizable() {
        guard synchronizable, let session = try? load() else { return }
        try? save(session)
    }
}

/// Non-persistent store for tests and the command-line smoke test.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(_ session: StoredSession? = nil) { self.session = session }

    public func load() throws -> StoredSession? { lock.withLock { session } }
    public func save(_ session: StoredSession) throws { lock.withLock { self.session = session } }
    public func delete() throws { lock.withLock { session = nil } }
}
