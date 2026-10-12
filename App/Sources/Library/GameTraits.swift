import Foundation

/// What the library's filters know about a game: whether it plays in Shiori, its entry in
/// the compatibility list, and its engine. From the download's record when there is one,
/// else from the engine scan of Steam's manifests.
struct GameTraits: Equatable {
    enum Plays: Equatable {
        /// Shiori plays it (or another Steam version of it).
        case yes
        /// Its engine is known and Shiori doesn't play it.
        case no
        /// Not checked yet, or the check failed.
        case unknown
    }

    var plays: Plays
    var compatibility: CompatibilityStore.Status?
    /// An engine id (`renpy`, `artemis`, …), `LibraryFilters.unknownEngine` when the check
    /// found none, or nil before the check.
    var engine: String?

    @MainActor
    init(_ game: LibraryGame, games: GameLibrary, engineScans: EngineScanStore, compatibility: CompatibilityStore) {
        let appID = game.appID
        self.compatibility = compatibility.entry(for: appID)?.entry.status
        if let record = games.record(for: appID) {
            // Downloaded: whether it starts here (a Ren'Py version this build lacks, an
            // engine not built for this device, …), as the Play button says.
            // When only another Steam version plays, the engine is that version's.
            let playable = games.playBlocker(appID: appID) == nil
            let beta = playable ? nil : engineScans.result(for: appID)?.playableBranch
            plays = playable || beta != nil ? .yes : .no
            engine = (beta?.engine ?? record.engine)?.engine ?? LibraryFilters.unknownEngine
        } else if let scan = engineScans.result(for: appID), scan.error == nil {
            let playable = Playability(scan.engine, appID: appID) == .playable
            let beta = playable ? nil : scan.playableBranch
            plays = playable || beta != nil ? .yes : .no
            engine = (beta?.engine ?? scan.engine)?.engine ?? LibraryFilters.unknownEngine
        } else {
            plays = .unknown
            engine = nil
        }
    }
}
