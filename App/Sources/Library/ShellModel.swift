import Observation

/// What the library's screens ask of the shell around them: switch tab, or open Settings
/// or Add Game. Shared through the environment.
@MainActor @Observable
final class ShellModel {
    var tab: ShellTab = .home
    var showingSettings = false
    var showingAddGame = false

    func select(_ tab: ShellTab) { self.tab = tab }
    func showSettings() { showingSettings = true }
    func addGame() { showingAddGame = true }
}
