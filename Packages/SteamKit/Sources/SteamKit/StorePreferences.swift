import Foundation

/// The account's store content preferences (Store › Preferences on Steam's website): which
/// content descriptors it hides on the store. Steam's descriptor ids: 1 some nudity or sexual
/// content, 2 frequent violence or gore, 3 adult only sexual content, 4 frequent nudity or
/// sexual content, 5 general mature content.
public struct StoreContentPreferences: Codable, Equatable, Sendable {
    public static let adultOnlySexualContent: UInt32 = 3

    /// The descriptors the account excludes. Nil when Steam sent no content preferences, which
    /// counts as not knowing.
    public var excludedDescriptors: Set<UInt32>?

    public init(excludedDescriptors: Set<UInt32>?) {
        self.excludedDescriptors = excludedDescriptors
    }

    public init(_ response: CStore_GetStorePreferences_Response) {
        if response.hasContentDescriptorPreferences {
            excludedDescriptors = Set(response.contentDescriptorPreferences.contentDescriptorsToExclude
                .filter(\.hasContentDescriptorid).map(\.contentDescriptorid))
        } else {
            excludedDescriptors = nil
        }
    }

    /// Adult only sexual content is shown only when the account is known not to exclude it.
    public var allowsAdultContent: Bool {
        guard let excludedDescriptors else { return false }
        return !excludedDescriptors.contains(Self.adultOnlySexualContent)
    }

    /// Whether something carrying these descriptors may be shown.
    public func allows(_ descriptors: some Sequence<UInt32>) -> Bool {
        let set = Set(descriptors)
        if set.contains(Self.adultOnlySexualContent) { return allowsAdultContent }
        guard let excludedDescriptors else { return true }
        return set.isDisjoint(with: excludedDescriptors)
    }
}

extension SteamSession {
    /// Reads the signed-in account's store content preferences (`Store.GetStorePreferences#1`).
    public func storeContentPreferences() async throws -> StoreContentPreferences {
        let response: CStore_GetStorePreferences_Response = try await loggedOnConnection().callService(
            "Store.GetStorePreferences#1", CStore_GetStorePreferences_Request(), authenticated: true
        )
        return StoreContentPreferences(response)
    }
}
