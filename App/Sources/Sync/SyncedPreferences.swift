import Foundation

/// Per-game choices that follow the user between devices (iCloud Keychain): the Steam version
/// (beta) a game downloads from and Ren'Py's Phone Layout. Mirrored into the UserDefaults keys
/// code off the main actor reads (`steamBranch.<appid>`, `renpyPhoneLayout.<appid>`).
///
/// Builds before 2026-10-15 also kept a KiriKiri engine choice per game (`shioriKrkr`,
/// `standardKrkr`); there is one engine now, and those keys are ignored when decoding.
@MainActor
enum SyncedPreferences {
    private struct Saved: Codable, Equatable {
        var branches: [String: String] = [:]
        var phoneLayout: [UInt32] = []
    }

    private static let account = "gamePreferences"
    private static let migratedKey = "gamePreferences.migrated"
    private static var saved = load()

    /// The Steam branch picked for the game, nil for the default ("public").
    static func branch(appID: UInt32) -> String? { saved.branches[String(appID)] }

    static func setBranch(_ branch: String?, appID: UInt32) {
        reload()
        saved.branches[String(appID)] = branch == "public" ? nil : branch
        save()
    }

    static func phoneLayout(appID: UInt32) -> Bool { saved.phoneLayout.contains(appID) }

    static func setPhoneLayout(_ enabled: Bool, appID: UInt32) {
        reload()
        saved.phoneLayout.removeAll { $0 == appID }
        if enabled { saved.phoneLayout.append(appID) }
        save()
    }

    /// Picks up changes made on another device (on returning to the foreground).
    static func reload() {
        let current = saved // Loads (and migrates) on first use.
        if let synced = SyncedKeychain.value(Saved.self, account: account), synced != current {
            saved = synced
            mirror(synced)
        }
    }

    private static func load() -> Saved {
        var saved = SyncedKeychain.value(Saved.self, account: account) ?? Saved()
        // Choices from before they synced join what other devices saved, once.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: migratedKey) {
            for (key, value) in defaults.dictionaryRepresentation() {
                if key.hasPrefix("steamBranch."), let branch = value as? String, saved.branches[String(key.dropFirst(12))] == nil {
                    saved.branches[String(key.dropFirst(12))] = branch
                } else if key.hasPrefix("renpyPhoneLayout."), value as? Bool == true,
                          let appID = UInt32(key.dropFirst(17)), !saved.phoneLayout.contains(appID) {
                    saved.phoneLayout.append(appID)
                }
            }
            SyncedKeychain.setValue(saved, account: account)
            defaults.set(true, forKey: migratedKey)
        }
        mirror(saved)
        return saved
    }

    private static func save() {
        SyncedKeychain.setValue(saved, account: account)
        mirror(saved)
    }

    private static func mirror(_ saved: Saved) {
        let defaults = UserDefaults.standard
        // `kirikiriEngine.<appid>` went with the engine choice; cleared here too.
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("steamBranch.") || key.hasPrefix("renpyPhoneLayout.")
            || key.hasPrefix("kirikiriEngine.") {
            defaults.removeObject(forKey: key)
        }
        for (appID, branch) in saved.branches { defaults.set(branch, forKey: "steamBranch.\(appID)") }
        for appID in saved.phoneLayout { defaults.set(true, forKey: "renpyPhoneLayout.\(appID)") }
    }
}
