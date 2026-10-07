import Foundation

/// What an engine recognised in a game folder.
struct EngineMatch: Codable, Equatable, Sendable {
    /// Stable engine id written to `game.json`, e.g. `renpy`.
    var engine: String
    /// Engine version as the game ships it, e.g. `7.3.5.606`, if it could be read.
    var version: String?
    /// Extra facts the runtime needs to decide whether it can launch the game.
    var details: [String: String] = [:]
}

/// A runtime that can play games built with one engine. Phase 2 only detects;
/// `launch` arrives with the Ren'Py runtime in phase 3.
protocol VNEngine {
    /// Value of `EngineMatch.engine` for this engine.
    static var id: String { get }
    static var displayName: String { get }
    /// Recognises the engine from files on disk.
    static func detect(gameRoot: URL) -> EngineMatch?
}

enum EngineDetection {
    static let engines: [any VNEngine.Type] = [RenPyEngine.self]

    static func detect(gameRoot: URL) -> EngineMatch? {
        for engine in engines {
            if let match = engine.detect(gameRoot: gameRoot) { return match }
        }
        return nil
    }

    static func displayName(for id: String) -> String {
        engines.first { $0.id == id }?.displayName ?? id
    }
}
