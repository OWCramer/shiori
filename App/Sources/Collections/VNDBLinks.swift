import Foundation

/// What VNDB says about the user's games, as Collections uses it: the VNDB entries each Steam
/// app is a release of, and how those entries relate (sequel, same series, fandisc…).
/// Cached on disk by `VNDBSeriesStore`, so suggestions work offline.
struct VNDBLinks: Codable, Equatable, Sendable {
    struct Relation: Codable, Hashable, Sendable {
        var id: String
        var relation: String
        var official: Bool
    }

    /// Steam app id (as a string, for JSON) → VNDB entry ids ("v15538").
    var vns: [String: [String]] = [:]
    /// When each app was last looked up, found or not.
    var checked: [String: Date] = [:]
    /// VNDB entry → its relations.
    var relations: [String: [Relation]] = [:]
    /// VNDB entry → its first release date ("2014-12-29"; VNDB may give only a year or month).
    var released: [String: String] = [:]
    /// When each entry's relations were last fetched.
    var vnChecked: [String: Date] = [:]

    func vns(of appID: UInt32) -> [String] { vns[String(appID)] ?? [] }

    /// The earliest release VNDB knows for the app's entries.
    func releaseDate(of appID: UInt32) -> Date? {
        vns(of: appID).compactMap { released[$0].flatMap(Self.date) }.min()
    }

    private static func date(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard let year = parts.first else { return nil }
        let components = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt, year: year,
                                        month: parts.count > 1 ? parts[1] : 12, day: parts.count > 2 ? parts[2] : 28)
        return components.date
    }
}
