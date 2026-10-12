#if os(iOS)
import Foundation
import Observation

/// Decides whether What's New shows at launch: once per catalog entry, after an update. A
/// fresh install marks the newest entry seen instead, so new players never get it.
@MainActor @Observable
final class WhatsNew {
    static let shared = WhatsNew()

    /// The entry to show now (`RootView` presents it).
    var pending: WhatsNewRelease?

    private static let lastBuildKey = "WhatsNewLastBuild"
    private static let seenKey = "WhatsNewSeenRelease"

    /// Run once as the app starts, before anything writes the library cache.
    func checkAtLaunch() {
        let defaults = UserDefaults.standard
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let lastBuild = defaults.string(forKey: Self.lastBuildKey)
        defaults.set(build, forKey: Self.lastBuildKey)
        guard let latest = WhatsNewCatalog.latest else { return }
        // Builds before this one didn't record theirs: anything Shiori keeps on disk means
        // this is an update, not a first install.
        let updated = lastBuild != nil || Self.hasEarlierInstall
        if !updated {
            defaults.set(latest.id, forKey: Self.seenKey)
        } else if defaults.string(forKey: Self.seenKey) != latest.id {
            pending = latest
        }
        #if DEBUG
        // `-ShioriShowWhatsNew YES` (debug): show the newest entry whatever was seen.
        if defaults.bool(forKey: "ShioriShowWhatsNew") { pending = latest }
        #endif
    }

    /// Continue: not shown again until a newer entry.
    func dismiss() {
        if let pending { UserDefaults.standard.set(pending.id, forKey: Self.seenKey) }
        pending = nil
    }

    private static var hasEarlierInstall: Bool {
        let files = FileManager.default
        if files.fileExists(atPath: URL.shioriSupport.appendingPathComponent("library.json").path) { return true }
        let games = (try? files.contentsOfDirectory(atPath: GameLibrary.gamesDirectory.path)) ?? []
        return !games.isEmpty
    }
}
#endif
