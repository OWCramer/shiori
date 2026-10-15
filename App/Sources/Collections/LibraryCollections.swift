import Foundation
import Observation

/// The library's collections (Phase 20): series suggested from Steam and VNDB, with the user's
/// edits over them, kept in iCloud Keychain like the Visual Novels tab's choices so every
/// device shows the same groups.
///
/// Suggestions come from the games in the Visual Novels tab and the downloaded ones; they're
/// worked out again when those change or VNDB answers, and the edits are laid over them
/// each time (`CollectionResolver`).
@MainActor @Observable
final class LibraryCollections {
    /// Top-level collections, by name.
    private(set) var collections: [LibraryCollection] = []
    /// The top-level collection each game is in.
    private(set) var collectionOfGame: [UInt32: String] = [:]
    private(set) var edits: CollectionEdits

    let vndb = VNDBSeriesStore()
    @ObservationIgnored private var candidates: [SeriesCandidate] = []
    @ObservationIgnored private var owned: Set<UInt32> = []
    @ObservationIgnored private var suggestions: [SeriesSuggestion] = []
    @ObservationIgnored private var suggestedFrom: (candidates: [SeriesCandidate], links: VNDBLinks)?
    @ObservationIgnored private var releaseDates: [UInt32: Date] = [:]
    @ObservationIgnored private var names: [UInt32: String] = [:]

    private static let account = "collections"

    init() {
        edits = SyncedKeychain.value(CollectionEdits.self, account: Self.account) ?? CollectionEdits()
    }

    // MARK: - Reading

    /// A collection or sub-group by id.
    func collection(id: String) -> LibraryCollection? {
        for collection in collections {
            if collection.id == id { return collection }
            if let sub = collection.subgroups.first(where: { $0.id == id }) { return sub }
        }
        return nil
    }

    /// The top-level collection a game is in.
    func collection(of appID: UInt32) -> LibraryCollection? {
        collectionOfGame[appID].flatMap { id in collections.first { $0.id == id } }
    }

    // MARK: - Inputs

    /// The library changed: which games can be suggested (the Visual Novels tab's and the
    /// downloaded ones) and which are owned at all.
    func update(library: [LibraryGame], suggestable: (LibraryGame) -> Bool) {
        let candidates = library.filter(suggestable).map(SeriesCandidate.init)
        owned = Set(library.map(\.appID))
        names = Dictionary(library.map { ($0.appID, $0.name) }, uniquingKeysWith: { first, _ in first })
        releaseDates = Dictionary(library.compactMap { game in game.releaseDate.map { (game.appID, $0) } },
                                  uniquingKeysWith: { first, _ in first })
        self.candidates = candidates
        recompute()
    }

    /// Looks the Visual Novels tab's games up on VNDB (cached; only what's missing or stale),
    /// then suggests again with what it said.
    func refreshVNDB(appIDs: [UInt32]) async {
        #if DEBUG
        if ScreenshotLibrary.isOn { return recompute() }
        #endif
        await vndb.refresh(appIDs: appIDs)
        recompute()
    }

    /// Picks up edits made on another device (on returning to the foreground).
    func reload() {
        guard let synced = SyncedKeychain.value(CollectionEdits.self, account: Self.account) else { return }
        let merged = edits.merged(with: synced)
        guard merged != edits else { return }
        edits = merged
        recompute()
    }

    // MARK: - Editing

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(id) { $0.name = trimmed }
    }

    /// Puts games in a collection (out of any other).
    func add(_ games: [UInt32], to id: String) {
        edit(id) { record in
            record.removed.removeAll(where: games.contains)
            for game in games where !record.added.contains(game) { record.added.append(game) }
        }
    }

    /// Takes games out of a collection (they're in none afterwards).
    func remove(_ games: [UInt32], from id: String) {
        edit(id) { record in
            record.added.removeAll(where: games.contains)
            for game in games where !record.removed.contains(game) { record.removed.append(game) }
        }
    }

    /// Makes a collection (or, with `parent`, a sub-group) of these games; returns its id.
    @discardableResult
    func create(named name: String, games: [UInt32], parent: String? = nil) -> String {
        let id = "c:" + UUID().uuidString
        edit(id) { record in
            record.isCustom = true
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Collection" : name
            record.parent = parent
            record.added = games
        }
        return id
    }

    /// Hides a suggestion, or deletes a made collection. Its games are left ungrouped.
    func hide(_ id: String) {
        edit(id) { $0.hidden = true }
    }

    /// Brings back hidden suggestions.
    func restoreHidden() {
        mutate { edits in
            for (id, record) in edits.records where record.hidden && !record.isCustom {
                edits.records[id]?.hidden = false
                edits.records[id]?.modified = .now
            }
        }
    }

    var hiddenSuggestionCount: Int { edits.records.values.filter { $0.hidden && !$0.isCustom }.count }

    /// Folds a collection into another.
    func merge(_ id: String, into target: String) {
        guard id != target else { return }
        edit(id) { $0.mergedInto = target }
    }

    func setSubgroupOrder(_ order: [String], in id: String) {
        edit(id) { $0.subgroupOrder = order }
    }

    // MARK: - Private

    /// Changes one collection's record, noting the suggested games it had the first time.
    private func edit(_ id: String, _ change: (inout CollectionRecord) -> Void) {
        let members = suggestedMembers(id)
        mutate { edits in
            var record = edits.records[id] ?? CollectionRecord()
            if record.members == nil, !record.isCustom { record.members = members }
            change(&record)
            record.modified = .now
            edits.records[id] = record
        }
    }

    /// Read what another device saved, change, write back, so edits on two devices merge.
    private func mutate(_ change: (inout CollectionEdits) -> Void) {
        var current = SyncedKeychain.value(CollectionEdits.self, account: Self.account).map { edits.merged(with: $0) } ?? edits
        change(&current)
        edits = current
        SyncedKeychain.setValue(current, account: Self.account)
        recompute()
    }

    private func suggestedMembers(_ id: String) -> [UInt32]? {
        for suggestion in suggestions {
            if suggestion.id == id { return suggestion.allGames }
            if let sub = suggestion.subgroups.first(where: { $0.id == id }) { return sub.games }
        }
        return nil
    }

    private func recompute() {
        let links = vndb.links
        if suggestedFrom.map({ $0.candidates != candidates || $0.links != links }) ?? true {
            suggestions = SeriesSuggester.suggest(candidates, vndb: links)
            suggestedFrom = (candidates, links)
        }
        let dates = releaseDates, names = names
        let resolved = CollectionResolver.resolve(suggestions, edits: edits, owned: owned) { a, b in
            let x = dates[a] ?? links.releaseDate(of: a) ?? .distantFuture
            let y = dates[b] ?? links.releaseDate(of: b) ?? .distantFuture
            if x != y { return x < y }
            return (names[a] ?? "").localizedStandardCompare(names[b] ?? "") == .orderedAscending
        }
        var membership: [UInt32: String] = [:]
        for collection in resolved {
            for game in collection.allGames { membership[game] = collection.id }
        }
        if resolved != collections { collections = resolved }
        if membership != collectionOfGame { collectionOfGame = membership }
    }
}
