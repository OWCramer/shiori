import Foundation

/// How the game page words engines, versions and Steam branches.
enum GameText {
    /// "Ren'Py 8.1.3", "Artemis", or "Engine not recognised".
    static func engine(_ engine: EngineMatch?) -> String {
        guard let engine else { return "Engine not recognised" }
        let name = EngineDetection.displayName(for: engine.engine)
        return engine.version.map { "\(name) \(shortVersion($0))" } ?? name
    }

    /// The first three parts of a version: `7.3.5.606` → `7.3.5`.
    static func shortVersion(_ version: String) -> String {
        version.split(separator: ".").prefix(3).joined(separator: ".")
    }

    /// "Default" for public; a beta's name, with Steam's description when it has one.
    static func branch(_ name: String, of game: LibraryGame) -> String {
        if name == "public" { return "Default" }
        if let description = game.branches?.first(where: { $0.name == name })?.description, !description.isEmpty {
            return "\(name) (\(description))"
        }
        return name
    }

    /// Why a game does or doesn't play, in a sentence.
    static func playability(_ playability: Playability, engine: EngineMatch?, appID: UInt32) -> String {
        if playability != .playable, let message = Playability.unsupportedMessage(engine, appID: appID) { return message }
        switch playability {
        case .playable: return "Plays in Shiori."
        case let .needsRuntime(reason): return reason
        case let .unsupportedEngine(name): return "\(name) games can be downloaded and patched, but not played."
        case .unknownEngine: return "Shiori doesn't recognise this game's engine."
        case .onlineGame: return OnlineGames.explanation
        case let .notOnThisDevice(reason): return reason
        }
    }

    /// A sync's state in a few words.
    static func sync(_ state: GameLibrary.SaveSyncState?) -> String {
        switch state ?? .idle {
        case .idle: "Not synced yet"
        case .syncing: "Syncing…"
        case let .synced(date, summary): "\(summary) · \(date.formatted(.relative(presentation: .named)))"
        case .unavailable: "iCloud unavailable"
        case let .failed(message): message
        }
    }
}
