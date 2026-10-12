import Foundation

/// The iPad sidebar's Engines section: each engine Shiori plays among the visual novels and
/// downloaded games, most games first, then those it doesn't play yet, with their counts
/// (the same games the engine's grid shows).
struct SidebarEngines: Equatable {
    struct Item: Equatable, Identifiable {
        let key: String
        let count: Int
        var id: String { key }
        var title: String { LibrarySection.engine(key).title }
        var systemImage: String { key == LibrarySection.notPlayable ? "exclamationmark.triangle" : "cpu" }
    }

    let items: [Item]

    /// No sidebar (compact width): nothing worked out.
    static let none = SidebarEngines(items: [])

    private init(items: [Item]) { self.items = items }

    @MainActor
    init(library: [LibraryGame], games: GameLibrary, curation: LibraryCuration,
         engineScans: EngineScanStore, compatibility: CompatibilityStore) {
        var counts: [String: Int] = [:]
        var notPlayable = 0
        for game in library where curation.isVisualNovel(game) || games.isOnDevice(game.appID) {
            let traits = GameTraits(game, games: games, engineScans: engineScans, compatibility: compatibility)
            switch traits.plays {
            case .yes: if let engine = traits.engine { counts[engine, default: 0] += 1 }
            case .no: notPlayable += 1
            case .unknown: break
            }
        }
        var items = counts.map { Item(key: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
        if notPlayable > 0 { items.append(Item(key: LibrarySection.notPlayable, count: notPlayable)) }
        self.items = items
    }
}
