import Foundation

/// Another Steam version that should play in Shiori when the one picked doesn't: from the
/// engine scan (a beta it found playable) or the compatibility list (its `branch`).
struct BranchHint: Equatable {
    var branch: String
    var detail: String
    /// The engine scan read that version's files and found an engine Shiori plays.
    var scanned = false

    @MainActor
    static func find(for game: LibraryGame, games: GameLibrary, engineScans: EngineScanStore,
                     compatibility: CompatibilityStore) -> BranchHint? {
        let appID = game.appID
        let current = games.branch(for: appID)
        if case let .installed(record) = games.status(for: appID) {
            // Downloaded, and plays as it is: nothing to suggest.
            if Playability(record.engine) == .playable { return nil }
        } else if current != "public" {
            return nil // A beta is already picked for the download.
        } else if let engine = engineScans.result(for: appID)?.engine, Playability(engine) == .playable {
            return nil
        }
        let branches = Set(game.branches?.map(\.name) ?? [])
        if let scan = engineScans.result(for: appID)?.playableBranch, scan.branch != current,
           branches.isEmpty || branches.contains(scan.branch)
        {
            let size = scan.installSize > 0 ? ", \(scan.installSize.formatted(.byteCount(style: .file)))" : ""
            return BranchHint(branch: scan.branch,
                              detail: "The \(GameText.branch(scan.branch, of: game)) version is \(GameText.engine(scan.engine)) and plays in Shiori (a Steam beta\(size)).",
                              scanned: true)
        }
        if let entry = compatibility.entry(for: appID)?.entry, let branch = entry.branch, branch != current,
           entry.status != .unsupported, branches.isEmpty || branches.contains(branch)
        {
            let verb = entry.status == .boots ? "starts" : "plays"
            return BranchHint(branch: branch,
                              detail: "The compatibility list says the \(GameText.branch(branch, of: game)) version \(verb) in Shiori (a Steam beta).")
        }
        return nil
    }
}
