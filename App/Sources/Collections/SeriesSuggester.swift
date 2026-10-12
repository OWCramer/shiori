import Foundation

/// Works out which of the user's games form a series, from four signals joined together:
///
/// - the same title once its number, volume or episode is taken off ("NEKOPARA Vol. 1",
///   "NEKOPARA Extra"; "Sakura Succubus 2" … "9");
/// - Steam's franchise (Sakura, Muv-Luv), unless it's only the publisher's name again
///   (Shiravune files its own name as NUKITASHI's franchise);
/// - one title starting with the other from the same developer or publisher, the weaker
///   store signal ("Summer Pockets" and "Summer Pockets REFLECTION BLUE");
/// - VNDB: releases of the same entry, or entries VNDB relates as sequels, prequels, the
///   same series, side stories, fandiscs or other versions.
///
/// Each connected set of two or more games is a collection. Inside one, games sharing a
/// title of their own (the numbered Sakura Succubus games) form a sub-group, one level deep.
enum SeriesSuggester {
    /// VNDB relations that put two entries in one series. "Same setting" and "shares
    /// characters" are left out: they join too loosely.
    static let seriesRelations: Set<String> = ["seq", "preq", "ser", "side", "par", "fan", "orig", "alt"]

    static func suggest(_ candidates: [SeriesCandidate], vndb: VNDBLinks = VNDBLinks()) -> [SeriesSuggestion] {
        let games = candidates.sorted { $0.appID < $1.appID }
        let count = games.count
        guard count > 1 else { return [] }
        let bases = games.map { SeriesName.base(of: $0.name) }
        let baseKeys = bases.map(SeriesName.key)
        let franchises = games.map(strongFranchise)
        var sets = DisjointSets(count: count)

        // The same title without its number.
        joinEqual(baseKeys.map { $0.isEmpty ? nil : $0 }, in: &sets)
        // Steam's franchise.
        joinEqual(franchises.map { $0.map(SeriesName.key) }, in: &sets)
        // One title the start of the other, from the same developer or publisher.
        let developers = games.map { $0.developer.map(makerKey) }
        let publishers = games.map { $0.publisher.map(makerKey) }
        for i in 0 ..< count {
            for j in (i + 1) ..< count where baseKeys[i] != baseKeys[j] {
                let sameMaker = (developers[i] != nil && developers[i] == developers[j])
                    || (publishers[i] != nil && publishers[i] == publishers[j])
                guard sameMaker else { continue }
                let (short, long) = baseKeys[i].count < baseKeys[j].count ? (baseKeys[i], baseKeys[j]) : (baseKeys[j], baseKeys[i])
                if short.count >= 4, long.hasPrefix(short + " ") { sets.join(i, j) }
            }
        }
        // VNDB: the same entry, or related entries.
        var gamesByVN: [String: [Int]] = [:]
        for (index, game) in games.enumerated() {
            for vn in vndb.vns(of: game.appID) { gamesByVN[vn, default: []].append(index) }
        }
        for (vn, members) in gamesByVN {
            for member in members.dropFirst() { sets.join(members[0], member) }
            for relation in vndb.relations[vn] ?? [] where relation.official && seriesRelations.contains(relation.relation) {
                if let other = gamesByVN[relation.id]?.first { sets.join(members[0], other) }
            }
        }

        let release: (Int) -> Date = { index in
            games[index].releaseDate ?? vndb.releaseDate(of: games[index].appID) ?? .distantFuture
        }
        let inReleaseOrder: (Int, Int) -> Bool = { a, b in
            let (x, y) = (release(a), release(b))
            if x != y { return x < y }
            return games[a].name.localizedStandardCompare(games[b].name) == .orderedAscending
        }

        var suggestions: [SeriesSuggestion] = []
        var usedIDs: Set<String> = []
        for component in sets.components() where component.count > 1 {
            let members = component.sorted(by: inReleaseOrder)
            let name = collectionName(members.map { (franchises[$0], bases[$0]) })
            let id = uniqueID("s:" + SeriesName.key(name), used: &usedIDs)
            // Runs sharing a title of their own, when the collection holds more than that.
            var runs: [String: [Int]] = [:]
            if members.count > 2 {
                for member in members { runs[baseKeys[member], default: []].append(member) }
            }
            let subgroups = runs.values
                .filter { $0.count > 1 && $0.count < members.count }
                .sorted { inReleaseOrder($0[0], $1[0]) }
                .map { run in
                    SeriesSuggestion(id: id + "/" + baseKeys[run[0]], name: bases[run[0]], games: run.map { games[$0].appID })
                }
            let inSubgroups = Set(subgroups.flatMap(\.games))
            suggestions.append(SeriesSuggestion(
                id: id, name: name,
                games: members.map { games[$0].appID }.filter { !inSubgroups.contains($0) },
                subgroups: subgroups
            ))
        }
        return suggestions.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The franchise Steam gives, unless it's just the developer's or publisher's name.
    static func strongFranchise(_ game: SeriesCandidate) -> String? {
        guard let franchise = game.franchise?.trimmingCharacters(in: .whitespaces), !franchise.isEmpty else { return nil }
        let key = makerKey(franchise)
        guard !key.isEmpty, key != game.developer.map(makerKey), key != game.publisher.map(makerKey) else { return nil }
        return franchise
    }

    /// A developer or publisher's name without spaces, since stores spell them both ways
    /// ("VisualArts/Key", "VISUAL ARTS/Key").
    private static func makerKey(_ name: String) -> String {
        SeriesName.key(name).replacing(" ", with: "")
    }

    /// The collection's name: the franchise most of its games carry, else the words their
    /// titles start with, else the first game's title.
    private static func collectionName(_ members: [(franchise: String?, base: String)]) -> String {
        var counts: [String: (name: String, count: Int, first: Int)] = [:]
        for (index, member) in members.enumerated() {
            guard let franchise = member.franchise else { continue }
            let key = SeriesName.key(franchise)
            counts[key] = (counts[key]?.name ?? franchise, (counts[key]?.count ?? 0) + 1, counts[key]?.first ?? index)
        }
        if let best = counts.values.max(by: { $0.count != $1.count ? $0.count < $1.count : $0.first > $1.first }) {
            return best.name
        }
        return SeriesName.commonPrefix(members.map(\.base)) ?? members[0].base
    }

    private static func joinEqual(_ keys: [String?], in sets: inout DisjointSets) {
        var first: [String: Int] = [:]
        for (index, key) in keys.enumerated() {
            guard let key, !key.isEmpty else { continue }
            if let earlier = first[key] { sets.join(earlier, index) } else { first[key] = index }
        }
    }

    private static func uniqueID(_ id: String, used: inout Set<String>) -> String {
        var candidate = id
        var number = 2
        while used.contains(candidate) {
            candidate = "\(id)-\(number)"
            number += 1
        }
        used.insert(candidate)
        return candidate
    }
}

/// Union-find over indices.
private struct DisjointSets {
    private var parent: [Int]

    init(count: Int) { parent = Array(0 ..< count) }

    mutating func find(_ index: Int) -> Int {
        var root = index
        while parent[root] != root { root = parent[root] }
        var node = index
        while parent[node] != root {
            let next = parent[node]
            parent[node] = root
            node = next
        }
        return root
    }

    mutating func join(_ a: Int, _ b: Int) {
        let (x, y) = (find(a), find(b))
        if x != y { parent[max(x, y)] = min(x, y) }
    }

    mutating func components() -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for index in parent.indices { groups[find(index), default: []].append(index) }
        return groups.keys.sorted().compactMap { groups[$0] }
    }
}
