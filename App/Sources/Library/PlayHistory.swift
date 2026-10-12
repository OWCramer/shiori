import Foundation
import Observation

/// When each game was last started, and its save slots: what Home's "last played" hero
/// and Continue Playing shelf, and the game page's Saves, are built from.
///
/// Launches are kept in iCloud Keychain like the other synced choices, so the game started
/// on the iPad leads Home on the iPhone too. Saves come from each game's `saves/` folder
/// (`SaveInventory`: real save slots only, not settings or read-text files), which also
/// covers games played before Shiori kept a record, and saves that arrived from another
/// device through iCloud or Steam Cloud.
@MainActor @Observable
final class PlayHistory {
    static let shared = PlayHistory()

    /// App ID → when the game was last started from Shiori (any device).
    private(set) var launches: [UInt32: Date] = [:]
    /// App ID → the game's save slots; absent until its folder has been read.
    private(set) var saves: [UInt32: SaveInventory] = [:]
    /// App ID → when its newest save slot was written; absent when it has none.
    var latestSave: [UInt32: Date] { saves.compactMapValues(\.latest) }

    /// App ID → when it was taken off Continue Playing (any device). Playing or saving it
    /// again after that puts it back.
    private(set) var removed: [UInt32: Date] = [:]

    private static let account = "playHistory"
    private static let removedAccount = "continuePlayingRemoved"
    /// Only the most recent launches are kept: Home shows a handful.
    private static let limit = 60
    private var refreshing: Task<Void, Never>?

    private init() {
        launches = Self.load()
        removed = Self.load(account: Self.removedAccount)
        saves = Self.loadSaveInventories()
    }

    /// Notes that the game is starting.
    func recordLaunch(_ appID: UInt32) {
        reload()
        launches[appID] = .now
        if launches.count > Self.limit {
            let keep = launches.sorted { $0.value > $1.value }.prefix(Self.limit)
            launches = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        SyncedKeychain.setValue(launches.map { Entry(appID: $0.key, date: $0.value) }, account: Self.account)
    }

    /// Picks up launches on other devices (on returning to the foreground).
    func reload() {
        let synced = Self.load()
        if synced != launches { launches = synced }
        let syncedRemoved = Self.load(account: Self.removedAccount)
        if syncedRemoved != removed { removed = syncedRemoved }
    }

    /// Takes the game off Continue Playing (finished, or not playing it now) until it's
    /// played or saved again.
    func removeFromContinuePlaying(_ appID: UInt32) {
        reload()
        removed[appID] = .now
        SyncedKeychain.setValue(removed.map { Entry(appID: $0.key, date: $0.value) }, account: Self.removedAccount)
    }

    /// Whether the game belongs on Continue Playing: played or saved, and not removed since.
    func isContinuing(_ appID: UInt32) -> Bool {
        guard let activity = lastActivity(appID) else { return false }
        guard let removedAt = removed[appID] else { return true }
        return activity.date > removedAt
    }

    /// The most recent of the last launch and the last save, and which it was.
    func lastActivity(_ appID: UInt32) -> Activity? {
        switch (launches[appID], saves[appID]?.latest) {
        case let (launch?, save?):
            if launch >= save { Activity(date: launch, kind: .played) }
            // Saved during that session: still "played", as of the save.
            else if save.timeIntervalSince(launch) < 6 * 3600 { Activity(date: save, kind: .played) }
            else { Activity(date: save, kind: .saved) }
        case let (launch?, nil): Activity(date: launch, kind: .played)
        case let (nil, save?): Activity(date: save, kind: .saved)
        case (nil, nil): nil
        }
    }

    /// Re-reads the saves of these games (folder and engine), off the main thread.
    func refreshSaves(_ folders: [UInt32: (folder: URL, engine: String?)]) {
        refreshing?.cancel()
        refreshing = Task {
            let found = await Task.detached(priority: .utility) {
                folders.mapValues { SaveInventory.read(gameFolder: $0.folder, engine: $0.engine) }
            }.value
            guard !Task.isCancelled else { return }
            if found != saves {
                saves = found
                Self.storeSaveInventories(found)
            }
        }
    }

    /// Re-reads one game's saves (its page opening, a sync finishing).
    func refreshSaves(appID: UInt32, folder: URL, engine: String?) async {
        let found = await Task.detached(priority: .userInitiated) { SaveInventory.read(gameFolder: folder, engine: engine) }.value
        if saves[appID] != found {
            saves[appID] = found
            Self.storeSaveInventories(saves)
        }
    }

    struct Activity: Equatable {
        enum Kind { case played, saved }
        var date: Date
        var kind: Kind

        /// "Played 2 hours ago", "Saved yesterday".
        var description: String {
            let when = date.formatted(.relative(presentation: .named))
            return kind == .played ? "Played \(when)" : "Saved \(when)"
        }
    }

    private struct Entry: Codable {
        var appID: UInt32
        var date: Date
    }

    /// The last saves found, kept on this device so Home's first frame after a launch
    /// already shows them (the folders are re-read in the background). Without it, Home
    /// first showed launch times and then jumped to the newer save times.
    private static let savesKey = "playHistory.saveSlots"

    private static func loadSaveInventories() -> [UInt32: SaveInventory] {
        UserDefaults.standard.removeObject(forKey: "playHistory.latestSave") // Any file, before save slots.
        guard let data = UserDefaults.standard.data(forKey: savesKey),
              let stored = try? JSONDecoder().decode([String: SaveInventory].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, inventory in UInt32(key).map { ($0, inventory) } })
    }

    private static func storeSaveInventories(_ saves: [UInt32: SaveInventory]) {
        let stored = Dictionary(uniqueKeysWithValues: saves.map { (String($0.key), $0.value) })
        UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: savesKey)
    }

    private static func load(account: String = account) -> [UInt32: Date] {
        let entries = SyncedKeychain.value([Entry].self, account: account) ?? []
        return Dictionary(entries.map { ($0.appID, $0.date) }, uniquingKeysWith: max)
    }
}
