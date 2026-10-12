import Foundation
import Observation

/// When each game was last started, and when its saves last changed: what Home's
/// "last played" hero and Continue Playing shelf are built from.
///
/// Launches are kept in iCloud Keychain like the other synced choices, so the game started
/// on the iPad leads Home on the iPhone too. Save times come from each game's `saves/`
/// folder, which also covers games played before Shiori kept a record (and saves that
/// arrived from another device through iCloud or Steam Cloud).
@MainActor @Observable
final class PlayHistory {
    static let shared = PlayHistory()

    /// App ID → when the game was last started from Shiori (any device).
    private(set) var launches: [UInt32: Date] = [:]
    /// App ID → the newest file in the game's `saves/` folder; absent when it has none.
    private(set) var latestSave: [UInt32: Date] = [:]

    private static let account = "playHistory"
    /// Only the most recent launches are kept: Home shows a handful.
    private static let limit = 60
    private var refreshing: Task<Void, Never>?

    private init() {
        launches = Self.load()
        latestSave = Self.loadSaveTimes()
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
    }

    /// The most recent of the last launch and the last save, and which it was.
    func lastActivity(_ appID: UInt32) -> Activity? {
        switch (launches[appID], latestSave[appID]) {
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

    /// Re-reads the saves folders of these games, off the main thread.
    func refreshSaves(_ folders: [UInt32: URL]) {
        refreshing?.cancel()
        refreshing = Task {
            let found = await Task.detached(priority: .utility) { Self.newestSaves(in: folders) }.value
            guard !Task.isCancelled else { return }
            if found != latestSave {
                latestSave = found
                Self.storeSaveTimes(found)
            }
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

    /// The last save times found, kept on this device so Home's first frame after a launch
    /// already shows them (the folders are re-read in the background). Without it, Home
    /// first showed launch times and then jumped to the newer save times.
    private static let saveTimesKey = "playHistory.latestSave"

    private static func loadSaveTimes() -> [UInt32: Date] {
        let stored = UserDefaults.standard.dictionary(forKey: saveTimesKey) as? [String: Date] ?? [:]
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, date in UInt32(key).map { ($0, date) } })
    }

    private static func storeSaveTimes(_ times: [UInt32: Date]) {
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: times.map { (String($0.key), $0.value) }), forKey: saveTimesKey)
    }

    private static func load() -> [UInt32: Date] {
        let entries = SyncedKeychain.value([Entry].self, account: account) ?? []
        return Dictionary(entries.map { ($0.appID, $0.date) }, uniquingKeysWith: max)
    }

    /// The newest regular file under each `saves/`, skipping Shiori's own bookkeeping
    /// (conflict copies) and hidden files.
    nonisolated private static func newestSaves(in folders: [UInt32: URL]) -> [UInt32: Date] {
        var result: [UInt32: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for (appID, folder) in folders {
            let saves = folder.appendingPathComponent("saves", isDirectory: true)
            guard let walker = FileManager.default.enumerator(at: saves, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles]) else { continue }
            var newest: Date?
            var seen = 0
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name == SaveSync.conflictsFolder {
                    walker.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let date = values.contentModificationDate else { continue }
                if newest.map({ date > $0 }) ?? true { newest = date }
                seen += 1
                if seen > 5000 { break }
            }
            if let newest { result[appID] = newest }
        }
        return result
    }
}
