import Foundation

/// Lays the user's edits over the suggested collections:
///
/// 1. An edited suggestion whose id changed (new data renamed the series) is found again by
///    the games it had.
/// 2. Hidden suggestions go (a hidden sub-group's games go back to its collection), and
///    deleted collections with them; made collections and sub-groups join.
/// 3. Names, removed games, then games placed by hand: a game is in one collection at a
///    time, the latest placement winning.
/// 4. Merges fold a collection into another (its sub-groups come along, unless that would
///    nest them two deep, when their games join directly).
/// 5. Games no longer owned drop out; empty suggestions and sub-groups go.
enum CollectionResolver {
    static func resolve(_ suggestions: [SeriesSuggestion], edits: CollectionEdits, owned: Set<UInt32>,
                        releaseOrder: (UInt32, UInt32) -> Bool) -> [LibraryCollection] {
        let records = followingRenamedSuggestions(edits.records, suggestions: suggestions)
        var nodes: [String: Node] = [:]

        for suggestion in suggestions {
            nodes[suggestion.id] = Node(id: suggestion.id, name: suggestion.name, isSuggested: true, parent: nil, games: suggestion.games)
            for sub in suggestion.subgroups {
                nodes[sub.id] = Node(id: sub.id, name: sub.name, isSuggested: true, parent: suggestion.id, games: sub.games)
            }
        }
        for (id, record) in records where record.isCustom && !record.hidden {
            nodes[id] = Node(id: id, name: record.name ?? "Collection", isSuggested: false, parent: record.parent, games: [])
        }

        // Hidden suggestions; a hidden sub-group's games return to its collection.
        for (id, record) in records where record.hidden && !record.isCustom {
            guard let node = nodes.removeValue(forKey: id) else { continue }
            if let parent = node.parent { nodes[parent]?.games += node.games }
        }
        // Sub-groups whose collection went, go with it; a sub-group's own sub-groups are flattened.
        for (id, node) in nodes {
            guard let parent = node.parent else { continue }
            if nodes[parent] == nil {
                nodes[id] = nil
            } else if let grandparent = nodes[parent]?.parent {
                nodes[id]?.parent = grandparent
            }
        }

        // Names and removed games.
        for (id, record) in records {
            guard nodes[id] != nil else { continue }
            if let name = record.name, !name.isEmpty { nodes[id]?.name = name }
            if !record.removed.isEmpty {
                let removed = Set(record.removed)
                nodes[id]?.games.removeAll(where: removed.contains)
            }
        }
        // Games placed by hand: the newest placement of each game wins.
        var placements: [UInt32: (id: String, at: Date)] = [:]
        for (id, record) in records where nodes[id] != nil {
            for game in record.added where placements[game].map({ $0.at < record.modified }) ?? true {
                placements[game] = (id, record.modified)
            }
        }
        if !placements.isEmpty {
            for id in nodes.keys { nodes[id]?.games.removeAll { placements[$0] != nil } }
            for (game, placement) in placements { nodes[placement.id]?.games.append(game) }
        }

        // Merges, followed a few steps (A into B into C).
        for (id, record) in records {
            guard var target = record.mergedInto, nodes[id] != nil else { continue }
            var hops = 0
            while let next = records[target]?.mergedInto, next != id, hops < 5 { target = next; hops += 1 }
            guard target != id, nodes[target] != nil, let source = nodes.removeValue(forKey: id) else { continue }
            let children = nodes.values.filter { $0.parent == id }.map(\.id)
            if nodes[target]?.parent == nil, source.parent == nil {
                nodes[target]?.games += source.games
                for child in children { nodes[child]?.parent = target }
            } else {
                let moved = source.games + children.flatMap { nodes[$0]?.games ?? [] }
                nodes[target]?.games += moved
                for child in children { nodes[child] = nil }
            }
        }

        // Owned games only, each once, in release order; a collection's own games exclude
        // its sub-groups'.
        var seen: Set<UInt32> = []
        let ids = nodes.keys.sorted { (nodes[$0]?.parent == nil ? 1 : 0, $0) < (nodes[$1]?.parent == nil ? 1 : 0, $1) }
        for id in ids {
            // Sub-groups first, so their games stay theirs.
            let games = nodes[id]?.games.filter { owned.contains($0) && seen.insert($0).inserted } ?? []
            nodes[id]?.games = games.sorted(by: releaseOrder)
        }

        func order(_ a: Node, _ b: Node) -> Bool {
            switch (a.games.first, b.games.first) {
            case let (x?, y?): releaseOrder(x, y)
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        return nodes.values
            .filter { $0.parent == nil }
            .compactMap { top -> LibraryCollection? in
                var subs = nodes.values.filter { $0.parent == top.id && !$0.games.isEmpty }.sorted(by: order)
                if let saved = records[top.id]?.subgroupOrder {
                    subs.sort { (saved.firstIndex(of: $0.id) ?? .max) < (saved.firstIndex(of: $1.id) ?? .max) }
                }
                var collection = LibraryCollection(
                    id: top.id, name: top.name, isSuggested: top.isSuggested, parentID: nil, games: top.games,
                    subgroups: subs.map {
                        LibraryCollection(id: $0.id, name: $0.name, isSuggested: $0.isSuggested, parentID: top.id,
                                          games: $0.games, inReleaseOrder: $0.games)
                    }
                )
                collection.inReleaseOrder = collection.allGames.sorted(by: releaseOrder)
                // Made collections stay while empty (just made, or emptied by hand).
                return collection.allGames.isEmpty && top.isSuggested ? nil : collection
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private struct Node {
        var id: String
        var name: String
        var isSuggested: Bool
        var parent: String?
        var games: [UInt32]
    }

    /// Re-keys edits of a suggestion that's no longer suggested under that id to the
    /// suggestion holding most of the games it had (at least half), if that one has none.
    private static func followingRenamedSuggestions(_ records: [String: CollectionRecord],
                                                    suggestions: [SeriesSuggestion]) -> [String: CollectionRecord] {
        let all = suggestions.flatMap { [$0] + $0.subgroups }
        let suggestedIDs = Set(all.map(\.id))
        var result = records
        for (id, record) in records where !record.isCustom && !suggestedIDs.contains(id) {
            guard let members = record.members.map(Set.init), !members.isEmpty else { continue }
            let isSubgroup = id.contains("/")
            let best = all
                .filter { $0.id.contains("/") == isSubgroup && result[$0.id] == nil }
                .map { (id: $0.id, overlap: members.intersection($0.allGames).count) }
                .max { $0.overlap < $1.overlap }
            guard let best, best.overlap * 2 >= members.count else { continue }
            result[best.id] = record
            result[id] = nil
        }
        return result
    }
}
