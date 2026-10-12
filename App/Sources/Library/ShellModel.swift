import Observation

/// What the library's screens (and the keyboard's commands) ask of the shell around them:
/// switch section, or open Settings or Add Game. Shared through the environment and as the
/// scene's focused value.
@MainActor @Observable
final class ShellModel {
    var tab: ShellTab = .home
    var showingSettings = false
    var showingAddGame = false
    /// A collection sheet: Add to Collection, New Collection, or a collection's editor.
    var collectionSheet: CollectionSheet?
    /// The iPad's sidebar is showing sections (regular width): Settings is one of them there
    /// rather than a sheet.
    var usesSidebar = false

    func select(_ tab: ShellTab) { self.tab = tab }

    func showSettings() {
        if usesSidebar { tab = .settings } else { showingSettings = true }
    }

    func addGame() { showingAddGame = true }

    func addToCollection(_ games: [UInt32]) { collectionSheet = .addTo(games) }
    func newCollection(_ games: [UInt32]) { collectionSheet = .new(games) }
    func editCollection(_ id: String) { collectionSheet = .edit(id) }
}
