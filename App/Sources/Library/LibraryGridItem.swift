// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
/// One tile in a library grid: a game, or a collection's games stacked as one.
enum LibraryGridItem: Identifiable {
    case game(LibraryGame)
    /// A collection (or sub-group) and its games here, front one first.
    case collection(LibraryCollection, games: [LibraryGame])

    var id: String {
        switch self {
        case let .game(game): "game-\(game.appID)"
        case let .collection(collection, _): "collection-\(collection.id)"
        }
    }

    /// The games in this order, with each collection that has two or more of them stacked
    /// into one tile where its first game would be.
    @MainActor
    static func grouping(_ games: [LibraryGame], collections: LibraryCollections) -> [LibraryGridItem] {
        var members: [String: [LibraryGame]] = [:]
        for game in games {
            if let id = collections.collectionOfGame[game.appID] { members[id, default: []].append(game) }
        }
        var items: [LibraryGridItem] = []
        var placed: Set<String> = []
        for game in games {
            guard let id = collections.collectionOfGame[game.appID], let here = members[id], here.count > 1,
                  let collection = collections.collection(id: id)
            else {
                items.append(.game(game))
                continue
            }
            guard placed.insert(id).inserted else { continue }
            items.append(.collection(collection, games: inReleaseOrder(here, of: collection)))
        }
        return items
    }

    /// A collection's page: its own games and its sub-groups' stacks, in release order.
    static func page(of collection: LibraryCollection, library: [UInt32: LibraryGame]) -> [LibraryGridItem] {
        var items: [(first: Int, item: LibraryGridItem)] = []
        let position = Dictionary(collection.inReleaseOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        for appID in collection.games {
            if let game = library[appID] { items.append((position[appID] ?? .max, .game(game))) }
        }
        for sub in collection.subgroups {
            let games = sub.games.compactMap { library[$0] }
            if games.count > 1 {
                items.append((sub.games.compactMap { position[$0] }.min() ?? .max, .collection(sub, games: games)))
            } else if let only = games.first {
                items.append((position[only.appID] ?? .max, .game(only)))
            }
        }
        return items.sorted { $0.first < $1.first }.map(\.item)
    }

    private static func inReleaseOrder(_ games: [LibraryGame], of collection: LibraryCollection) -> [LibraryGame] {
        let position = Dictionary(collection.inReleaseOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return games.sorted { (position[$0.appID] ?? .max) < (position[$1.appID] ?? .max) }
    }
}
#endif
