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
        case let .engine(key): key == Self.notPlayable ? "Not Yet Playable" : LibraryFilters.engineName(key)
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
            return games.status(for: game.appID) != .notInstalled
        case .recentlyPlayed:
            return history.lastActivity(game.appID) != nil
        case let .engine(key):
            guard curation.isVisualNovel(game) || games.status(for: game.appID) != .notInstalled else { return false }
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
