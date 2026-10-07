import Foundation
import Observation

/// Which games appear in the Visual Novels tab: Steam's Visual Novel tag, plus games the user
/// adds by hand, minus games he hides. Kept on this device in UserDefaults.
@MainActor @Observable
final class LibraryCuration {
    private(set) var added: Set<UInt32>
    private(set) var hidden: Set<UInt32>

    private static let addedKey = "visualNovels.added"
    private static let hiddenKey = "visualNovels.hidden"

    init() {
        let defaults = UserDefaults.standard
        added = Set((defaults.array(forKey: Self.addedKey) as? [Int] ?? []).compactMap(UInt32.init(exactly:)))
        hidden = Set((defaults.array(forKey: Self.hiddenKey) as? [Int] ?? []).compactMap(UInt32.init(exactly:)))
    }

    func isVisualNovel(_ game: LibraryGame) -> Bool {
        !hidden.contains(game.appID) && (game.isVisualNovel || added.contains(game.appID))
    }

    /// Puts a game in the Visual Novels tab (undoing a hide if it was tagged by Steam).
    func add(_ game: LibraryGame) {
        hidden.remove(game.appID)
        if !game.isVisualNovel { added.insert(game.appID) }
        save()
    }

    /// Takes a game out of the Visual Novels tab, whether Steam tagged it or it was added.
    func remove(_ game: LibraryGame) {
        added.remove(game.appID)
        if game.isVisualNovel { hidden.insert(game.appID) }
        save()
    }

    func toggle(_ game: LibraryGame) {
        if isVisualNovel(game) { remove(game) } else { add(game) }
    }

    private func save() {
        UserDefaults.standard.set(added.map { Int($0) }, forKey: Self.addedKey)
        UserDefaults.standard.set(hidden.map { Int($0) }, forKey: Self.hiddenKey)
    }
}
