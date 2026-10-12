import Foundation

/// When each game's saves last went up, to iCloud and to Steam Cloud separately, and the
/// newest save file there was at the time. Lets the next launch tell whether saves were left
/// behind (the app force quit, crashed, or ran out of background time before pushing) and
/// push them before anything is pulled over them.
///
/// Kept in UserDefaults (this device only: it describes this device's files).
enum SavePushLedger {
    enum Destination: String, CaseIterable, Sendable {
        case iCloud
        case steamCloud
        /// Steam Cloud pushes made as dry runs (debug builds), kept apart so a dry run never
        /// counts as saves having gone up.
        case steamCloudDryRun
    }

    struct Entry: Codable, Equatable, Sendable {
        /// When the last successful push started: every file older than this was considered.
        var pushedAt: Date
        /// The newest save file in `saves/` when that push started.
        var newestSave: Date?
    }

    private static func key(_ destination: Destination, appID: UInt32) -> String {
        "savePush.\(destination.rawValue).\(appID)"
    }

    static func entry(_ destination: Destination, appID: UInt32) -> Entry? {
        guard let data = UserDefaults.standard.data(forKey: key(destination, appID: appID)) else { return nil }
        return try? JSONDecoder().decode(Entry.self, from: data)
    }

    static func record(_ destination: Destination, appID: UInt32, pushedAt: Date, newestSave: Date?) {
        guard let data = try? JSONEncoder().encode(Entry(pushedAt: pushedAt, newestSave: newestSave)) else { return }
        UserDefaults.standard.set(data, forKey: key(destination, appID: appID))
    }

    /// The newest modification time among the files in `saves/` (not conflict copies).
    static func newestSave(in saves: URL) -> Date? {
        SaveSync.files(in: saves).values.max()
    }

    enum Check: Equatable, Sendable {
        /// Nothing newer than the last push (or no saves at all).
        case upToDate
        /// Files changed after the last push started; `newest` is the newest of them.
        case pending(newest: Date, lastPush: Date?)
        /// Never recorded for this destination.
        case unknown(newest: Date)
    }

    static func check(_ destination: Destination, appID: UInt32, saves: URL) -> Check {
        guard let newest = newestSave(in: saves) else { return .upToDate }
        guard let entry = entry(destination, appID: appID) else { return .unknown(newest: newest) }
        return newest.timeIntervalSince(entry.pushedAt) > SaveSync.tolerance
            ? .pending(newest: newest, lastPush: entry.pushedAt) : .upToDate
    }
}
