import Foundation
import SteamKit

/// The last store content preferences read from Steam, for launches before Steam answers
/// (offline, or still connecting). None read yet counts as unknown, which hides adult content.
enum ContentPreferencesCache {
    private static let key = "steamStoreContentPreferences"

    static func load() -> StoreContentPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let preferences = try? JSONDecoder().decode(StoreContentPreferences.self, from: data)
        else { return StoreContentPreferences(excludedDescriptors: nil) }
        return preferences
    }

    static func save(_ preferences: StoreContentPreferences) {
        if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: key) }
    }
}
