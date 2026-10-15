import Foundation
import SwiftProtobuf
import Testing
@testable import SteamKit

struct StorePreferencesTests {
    /// A response as Steam sends it, through the wire format.
    private func response(excluding ids: [UInt32]?) throws -> CStore_GetStorePreferences_Response {
        var response = CStore_GetStorePreferences_Response()
        response.preferences.primaryLanguage = 0
        if let ids {
            var preferences = UserContentDescriptorPreferences()
            preferences.contentDescriptorsToExclude = ids.map { id in
                var descriptor = UserContentDescriptorPreferences.ContentDescriptor()
                descriptor.contentDescriptorid = id
                descriptor.timestampAdded = 1_700_000_000
                return descriptor
            }
            response.contentDescriptorPreferences = preferences
        }
        return try CStore_GetStorePreferences_Response(serializedBytes: try response.serializedData())
    }

    @Test func newAccountDefaultHidesAdultContent() throws {
        // Steam's default for a new account excludes 3 (adult only) and 4 (frequent nudity).
        let preferences = StoreContentPreferences(try response(excluding: [3, 4]))
        #expect(preferences.excludedDescriptors == [3, 4])
        #expect(!preferences.allowsAdultContent)
        #expect(!preferences.allows([1, 3, 5]))
        #expect(preferences.allows([1, 5]))
    }

    @Test func allowedWhenAdultOnlyIsNotExcluded() throws {
        let preferences = StoreContentPreferences(try response(excluding: []))
        #expect(preferences.excludedDescriptors == [])
        #expect(preferences.allowsAdultContent)
        #expect(preferences.allows([1, 3, 4, 5]))
    }

    @Test func otherExclusionsDoNotHideAdultOnly() throws {
        let preferences = StoreContentPreferences(try response(excluding: [2]))
        #expect(preferences.allowsAdultContent)
        #expect(!preferences.allows([2]))
    }

    @Test func missingPreferencesCountAsUnknownAndHide() throws {
        let preferences = StoreContentPreferences(try response(excluding: nil))
        #expect(preferences.excludedDescriptors == nil)
        #expect(!preferences.allowsAdultContent)
        #expect(!preferences.allows([3]))
        #expect(preferences.allows([1]))
    }

    @Test func roundTripsThroughACache() throws {
        let cached = try JSONDecoder().decode(StoreContentPreferences.self,
                                              from: JSONEncoder().encode(StoreContentPreferences(excludedDescriptors: [4])))
        #expect(cached.allowsAdultContent)
        let unknown = try JSONDecoder().decode(StoreContentPreferences.self,
                                               from: JSONEncoder().encode(StoreContentPreferences(excludedDescriptors: nil)))
        #expect(!unknown.allowsAdultContent)
    }

    @Test func readsDLCContentDescriptorsFromPICS() throws {
        let kv = try KeyValue.parseText("""
        "appinfo"
        {
            "appid" "983090"
            "common"
            {
                "name" "Sakura Sakura - 18+ DLC"
                "type" "DLC"
                "content_descriptors" { "0" "1" "1" "3" "2" "5" }
            }
        }
        """)
        #expect(SteamSession.contentDescriptors(of: kv) == [1, 3, 5])
        let none = try KeyValue.parseText(#""appinfo" { "common" { "name" "Soundtrack" } }"#)
        #expect(SteamSession.contentDescriptors(of: none).isEmpty)
    }
}
