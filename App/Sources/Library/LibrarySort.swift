import Foundation

/// How a library list is ordered.
enum LibrarySort: String, CaseIterable, Identifiable {
    case name = "Name"
    case recent = "Recently Played"
    case size = "Size"
    var id: Self { self }

    /// The games in this order. `lastActivity` and `size` look a game up.
    func sorted(_ games: [LibraryGame], lastActivity: (UInt32) -> Date?, size: (LibraryGame) -> UInt64) -> [LibraryGame] {
        switch self {
        case .name:
            return games
        case .recent:
            // Games never played keep their (name) order, after the played ones.
            return games.enumerated().sorted { a, b in
                switch (lastActivity(a.element.appID), lastActivity(b.element.appID)) {
                case let (x?, y?): x > y
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): a.offset < b.offset
                }
            }.map(\.element)
        case .size:
            return games.sorted { size($0) > size($1) }
        }
    }
}
