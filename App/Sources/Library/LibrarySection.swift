// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Which games a library grid shows: a tab (Visual Novels, Installed), Recently Played, or
/// one engine from the iPad's sidebar.
enum LibrarySection: Hashable {
    case visualNovels
    case installed
    case recentlyPlayed
    /// Visual novels and downloaded games on one engine; `notPlayable` for those Shiori
    /// doesn't play.
    case engine(String)

    static let notPlayable = "notPlayable"

    var title: String {
        switch self {
        case .visualNovels: "Visual Novels"
        case .installed: "Installed"
        case .recentlyPlayed: "Recently Played"
        case let .engine(key): key == Self.notPlayable ? "Not Playable" : LibraryFilters.engineName(key)
        }
    }

    /// The key its sort and filters are remembered under.
    var storageKey: String {
        switch self {
        case .visualNovels: "visualNovels"
        case .installed: "installed"
        case .recentlyPlayed: "recentlyPlayed"
        case let .engine(key): "engine.\(key)"
        }
    }

    /// Whether the game belongs here.
    @MainActor
    func contains(_ game: LibraryGame, traits: @autoclosure () -> GameTraits, games: GameLibrary,
                  curation: LibraryCuration, history: PlayHistory) -> Bool {
        switch self {
        case .visualNovels:
            return curation.isVisualNovel(game)
        case .installed:
            return games.isOnDevice(game.appID)
        case .recentlyPlayed:
            return history.lastActivity(game.appID) != nil
        case let .engine(key):
            guard curation.isVisualNovel(game) || games.isOnDevice(game.appID) else { return false }
            let traits = traits()
            if key == Self.notPlayable { return traits.plays == .no }
            return traits.plays == .yes && traits.engine == key
        }
    }
}

extension LibrarySection {
    /// The tab that shows this section.
    var shellTab: ShellTab {
        switch self {
        case .visualNovels: .visualNovels
        case .installed: .installed
        case .recentlyPlayed: .recentlyPlayed
        case let .engine(key): .engine(key)
        }
    }
}
