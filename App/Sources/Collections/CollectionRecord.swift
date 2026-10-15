// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// the user's changes to one collection, or a collection he made. Suggested collections are
/// worked out afresh each time; these records are laid over them, keyed by the collection's
/// id, so a rename or a removed game holds when the suggestions are refreshed.
struct CollectionRecord: Codable, Equatable, Sendable {
    /// A new name (or a made collection's name).
    var name: String?
    /// Made by the user rather than suggested.
    var isCustom = false
    /// A made sub-group's collection.
    var parent: String?
    /// Games put in it by hand. A game is in one collection at a time: the latest hand
    /// placement takes it out of any other.
    var added: [UInt32] = []
    /// Suggested games taken out.
    var removed: [UInt32] = []
    /// A hidden suggestion, or a made collection deleted.
    var hidden = false
    /// Folded into another collection.
    var mergedInto: String?
    /// Its sub-groups' order, when the user set one.
    var subgroupOrder: [String]?
    /// The suggested games when it was first edited, to find the suggestion again if its
    /// id changes (new data renaming the series).
    var members: [UInt32]?
    var modified: Date

    init(modified: Date = .now) { self.modified = modified }

    // Decoding tolerates fields added later (another device on an older build).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isCustom = try container.decodeIfPresent(Bool.self, forKey: .isCustom) ?? false
        parent = try container.decodeIfPresent(String.self, forKey: .parent)
        added = try container.decodeIfPresent([UInt32].self, forKey: .added) ?? []
        removed = try container.decodeIfPresent([UInt32].self, forKey: .removed) ?? []
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        mergedInto = try container.decodeIfPresent(String.self, forKey: .mergedInto)
        subgroupOrder = try container.decodeIfPresent([String].self, forKey: .subgroupOrder)
        members = try container.decodeIfPresent([UInt32].self, forKey: .members)
        modified = try container.decodeIfPresent(Date.self, forKey: .modified) ?? .distantPast
    }
}
