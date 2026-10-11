#if os(iOS)
import Foundation

/// Everything Home shows, worked out from the library in one pass.
@MainActor
struct HomeShelves {
    /// The game leading Home: last played or saved, else the newest playable download.
    var featured: LibraryGame?
    /// Downloaded games played or saved, newest first (without the featured one).
    var continuePlaying: [LibraryGame] = []
    var downloading: [LibraryGame] = []
    /// Downloaded, playable, never started: newest download first.
    var readyToPlay: [LibraryGame] = []
    /// Visual novels not downloaded whose engine scan says they play.
    var playsInShiori: [LibraryGame] = []
    var visualNovels: [LibraryGame] = []

    var isEmpty: Bool { featured == nil && visualNovels.isEmpty && downloading.isEmpty }

    init(library: [LibraryGame], games: GameLibrary, curation: LibraryCuration,
         engineScans: EngineScanStore, history: PlayHistory) {
        var installed: [(game: LibraryGame, record: GameRecord)] = []
        for game in library {
            if case let .installed(record) = games.status(for: game.appID) { installed.append((game, record)) }
        }

        let active = installed
            .compactMap { entry in history.lastActivity(entry.game.appID).map { (game: entry.game, date: $0.date) } }
            .sorted { $0.date > $1.date }
            .map(\.game)
        let playable = installed.filter { games.playBlocker(appID: $0.game.appID) == nil }
        featured = active.first ?? playable.max { $0.record.installedAt < $1.record.installedAt }?.game
        #if DEBUG
        // `-ShioriHomeGame <appid>` leads Home with that game, to compare its banner with the
        // game page's (artwork picks, crops).
        let requested = UserDefaults.standard.integer(forKey: "ShioriHomeGame")
        if requested != 0, let game = library.first(where: { $0.appID == requested }) { featured = game }
        #endif
        continuePlaying = active.filter { $0.appID != featured?.appID }

        let byID = Dictionary(library.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        downloading = games.downloadItems.compactMap { byID[$0] }

        let started = Set(active.map(\.appID))
        readyToPlay = playable
            .filter { !started.contains($0.game.appID) && $0.game.appID != featured?.appID }
            .sorted { $0.record.installedAt > $1.record.installedAt }
            .map(\.game)

        visualNovels = library.filter { curation.isVisualNovel($0) }
        playsInShiori = visualNovels.filter { game in
            guard games.status(for: game.appID) == .notInstalled,
                  let scan = engineScans.result(for: game.appID), scan.error == nil else { return false }
            return Playability(scan.engine, appID: game.appID) == .playable || scan.playableBranch != nil
        }
    }
}
#endif
