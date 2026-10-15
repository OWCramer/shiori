// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Keyboard shortcuts (iPad with a keyboard; hold ⌘ to see them): the open game's Play,
/// Import Patch and Open Folder, Add to Visual Novels, Settings, Search, and ⌘1–⌘5 for the
/// library's sections.
struct ShioriCommands: Commands {
    let games: GameLibrary
    @FocusedValue(ShellModel.self) private var shell
    @FocusedValue(GamePageModel.self) private var page

    private var pageGame: LibraryGame? { page?.game }

    private var canPlay: Bool {
        guard let game = pageGame, games.stage(for: game.appID) == .installed else { return false }
        return games.playBlocker(appID: game.appID) == nil && games.launchPhase(for: game.appID) == nil
    }

    private var isInstalled: Bool {
        guard let game = pageGame, games.stage(for: game.appID) == .installed else { return false }
        return true
    }

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…", action: showSettings)
                .keyboardShortcut(",", modifiers: .command)
                .disabled(shell == nil)
        }
        CommandGroup(replacing: .newItem) {
            Button("Add to Visual Novels…", action: addGame)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(shell == nil)
        }
        CommandMenu("Game") {
            Button("Play", action: play)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canPlay)
            Button("Import Patch…", action: importPatch)
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!isInstalled)
            Button("Open Folder in Files", action: openFolder)
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!isInstalled)
        }
        CommandMenu("Go") {
            Button("Home") { shell?.select(.home) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Visual Novels") { shell?.select(.visualNovels) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Installed") { shell?.select(.installed) }
                .keyboardShortcut("3", modifiers: .command)
            Button("Recently Played") { shell?.select(.recentlyPlayed) }
                .keyboardShortcut("4", modifiers: .command)
            Button("Downloads") { shell?.select(.downloads) }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Search") { shell?.select(.search) }
                .keyboardShortcut("f", modifiers: .command)
        }
    }

    private func showSettings() { shell?.showSettings() }
    private func addGame() { shell?.addGame() }

    private func play() {
        if let game = pageGame { games.play(appID: game.appID) }
    }

    private func importPatch() { page?.importingPatch = true }

    private func openFolder() {
        if let game = pageGame { openInFiles(games.folder(appID: game.appID, name: game.name)) }
    }
}
#endif
