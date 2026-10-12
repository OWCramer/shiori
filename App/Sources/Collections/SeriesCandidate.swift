import Foundation

/// What Collections needs to know about a game to suggest its series: the store's names
/// for it and when it came out. Kept apart from `LibraryGame` so the suggestions are plain
/// data in, plain data out.
struct SeriesCandidate: Hashable, Sendable {
    var appID: UInt32
    var name: String
    var developer: String?
    var publisher: String?
    var franchise: String?
    var releaseDate: Date?
}

extension SeriesCandidate {
    init(_ game: LibraryGame) {
        self.init(appID: game.appID, name: game.name, developer: game.developer, publisher: game.publisher,
                  franchise: game.franchise, releaseDate: game.releaseDate)
    }
}
