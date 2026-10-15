// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Security

/// Small values kept in iCloud Keychain, so they follow the user to his other devices (iPhone,
/// iPad, Apple TV): the SteamGridDB key, the Visual Novels tab's additions and hides, and
/// picked artwork. (The Steam sign-in syncs the same way, through SteamKit's store.)
/// Synchronizable Keychain items need no iCloud entitlement, so this works on every target.
enum SyncedKeychain {
    static let service = "com.owencramer.vnhub.sync"

    /// The value, whether it's already synced or still a this-device item from before.
    static func data(account: String, service: String = service) -> Data? {
        #if DEBUG
        if ScreenshotLibrary.isOn { return ScreenshotLibrary.keychainData(account: memoryKey(account, service)) }
        #endif
        var query = baseQuery(account: account, service: service)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Replaces the value everywhere (nil removes it), as a synced item.
    static func set(_ data: Data?, account: String, service: String = service) {
        #if DEBUG
        if ScreenshotLibrary.isOn { return ScreenshotLibrary.setKeychainData(data, account: memoryKey(account, service)) }
        #endif
        var existing = baseQuery(account: account, service: service)
        existing[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(existing as CFDictionary)
        guard let data else { return }
        var item = baseQuery(account: account, service: service)
        item[kSecAttrSynchronizable as String] = true
        // Synced items can't be this-device-only.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecValueData as String] = data
        SecItemAdd(item as CFDictionary, nil)
    }

    static func value<T: Decodable>(_ type: T.Type, account: String) -> T? {
        data(account: account).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    static func setValue<T: Encodable>(_ value: T, account: String) {
        set(try? JSONEncoder().encode(value), account: account)
    }

    #if DEBUG
    /// The screenshot library's in-memory stand-in for an item.
    private static func memoryKey(_ account: String, _ service: String) -> String {
        service == Self.service ? account : "\(service)/\(account)"
    }
    #endif

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }
}
