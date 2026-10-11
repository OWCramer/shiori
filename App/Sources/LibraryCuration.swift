import Foundation
import Observation

/// Which games appear in the Visual Novels tab: Steam's Visual Novel tag, plus games the user
/// adds by hand, minus games he hides. Kept in iCloud Keychain so every device shows the
/// same tab.
@MainActor @Observable
final class LibraryCuration {
    private(set) var added: Set<UInt32>
    private(set) var hidden: Set<UInt32>

    private struct Saved: Codable {
        var added: [UInt32]
        var hidden: [UInt32]
    }

    private static let account = "visualNovels"
    /// Where the lists lived before they synced (this device only).
    private static let addedKey = "visualNovels.added"
    private static let hiddenKey = "visualNovels.hidden"

    init() {
        let synced = SyncedKeychain.value(Saved.self, account: Self.account)
        added = Set(synced?.added ?? [])
        hidden = Set(synced?.hidden ?? [])
        // Lists from before syncing join what other devices saved, once.
        let defaults = UserDefaults.standard
        if let legacyAdded = defaults.array(forKey: Self.addedKey) as? [Int] {
            let legacyHidden = defaults.array(forKey: Self.hiddenKey) as? [Int] ?? []
            added.formUnion(legacyAdded.compactMap(UInt32.init(exactly:)))
            hidden.formUnion(legacyHidden.compactMap(UInt32.init(exactly:)))
            hidden.subtract(added)
            save()
            defaults.removeObject(forKey: Self.addedKey)
            defaults.removeObject(forKey: Self.hiddenKey)
        }
    }

    /// Picks up changes made on another device (on returning to the foreground).
    func reload() {
        guard let synced = SyncedKeychain.value(Saved.self, account: Self.account) else { return }
        let newAdded = Set(synced.added), newHidden = Set(synced.hidden)
        if newAdded != added { added = newAdded }
        if newHidden != hidden { hidden = newHidden }
    }

    func isVisualNovel(_ game: LibraryGame) -> Bool {
        !hidden.contains(game.appID) && (game.isVisualNovel || added.contains(game.appID))
    }

    /// Puts a game in the Visual Novels tab (undoing a hide if it was tagged by Steam).
    func add(_ game: LibraryGame) {
        reload()
        hidden.remove(game.appID)
        if !game.isVisualNovel { added.insert(game.appID) }
        save()
    }

    /// Takes a game out of the Visual Novels tab, whether Steam tagged it or it was added.
    func remove(_ game: LibraryGame) {
        reload()
        added.remove(game.appID)
        if game.isVisualNovel { hidden.insert(game.appID) }
        save()
    }

    func toggle(_ game: LibraryGame) {
        if isVisualNovel(game) { remove(game) } else { add(game) }
    }

    private func save() {
        SyncedKeychain.setValue(Saved(added: added.sorted(), hidden: hidden.sorted()), account: Self.account)
    }
}
