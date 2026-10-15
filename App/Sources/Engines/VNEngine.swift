// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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

    /// Engines Shiori can't run yet, recognised by their files so the library can say
    /// "not playable yet: Artemis" instead of nothing. First match wins.
    struct Signature: Sendable {
        var id: String
        var name: String
        /// File names (lowercased) at the game root, or a predicate over them.
        var matches: @Sendable (_ rootNames: Set<String>, _ root: URL) -> Bool
    }

    static let signatures: [Signature] = [
        Signature(id: "artemis", name: "Artemis") { names, _ in names.contains { $0.hasSuffix(".pfs") || $0.contains(".pfs.") } },
        Signature(id: "kirikiri", name: "Kirikiri") { names, _ in names.contains { $0.hasSuffix(".xp3") } },
        // Steam's multilingual builds (planetarian HD, Summer Pockets) ship SceneEN.pck and
        // GameexeEN.dat, not Scene.pck: match before Godot, which also uses .pck.
        Signature(id: "siglus", name: "SiglusEngine") { names, _ in
            names.contains { name in
                (name.hasPrefix("scene") && name.hasSuffix(".pck")) || (name.hasPrefix("gameexe") && name.hasSuffix(".dat"))
                    || (name.hasPrefix("siglusengine") && name.hasSuffix(".exe"))
            }
        },
        // Prototype's Luca System (Summer Pockets REFLECTION BLUE): files/SCRIPT.PAK.
        Signature(id: "luca", name: "Luca System") { names, root in
            names.contains("files")
                && FileManager.default.fileExists(atPath: root.appendingPathComponent("files/SCRIPT.PAK").path)
        },
        Signature(id: "nscripter", name: "NScripter") { names, _ in
            names.contains("nscript.dat") || names.contains("0.txt") || names.contains("00.txt") || names.contains { $0.hasSuffix(".nsa") }
        },
        Signature(id: "yuris", name: "YU-RIS") { names, _ in names.contains { $0.hasSuffix(".ypf") } },
        Signature(id: "catsystem2", name: "CatSystem2") { names, _ in names.contains("cs2.exe") || names.contains { $0.hasSuffix(".int") } },
        Signature(id: "tyrano", name: "TyranoScript") { names, root in
            names.contains("tyrano") || FileManager.default.fileExists(atPath: root.appendingPathComponent("resources/app/tyrano").path)
        },
        Signature(id: "rpgmaker", name: "RPG Maker") { names, root in
            names.contains { $0.hasSuffix(".rgss3a") || $0.hasSuffix(".rgss2a") || $0.hasSuffix(".rgssad") }
                || FileManager.default.fileExists(atPath: root.appendingPathComponent("www/js/rpg_core.js").path)
                || FileManager.default.fileExists(atPath: root.appendingPathComponent("js/rmmz_core.js").path)
        },
        // UnityPlayer.dll or a <Name>_Data/ folder with the player's own files, at the root or
        // one folder down; not any name ending in _data (UnityLayout).
        Signature(id: "unity", name: "Unity") { _, root in UnityLayout.find(in: root) != nil },
        Signature(id: "godot", name: "Godot") { names, _ in names.contains { $0.hasSuffix(".pck") } },
    ]

    static func detect(gameRoot: URL) -> EngineMatch? {
        for engine in engines {
            if let match = engine.detect(gameRoot: gameRoot) { return match }
        }
        let names = Set(((try? FileManager.default.contentsOfDirectory(atPath: gameRoot.path)) ?? []).map { $0.lowercased() })
        if let signature = signatures.first(where: { $0.matches(names, gameRoot) }) {
            if signature.id == "unity", let unity = UnityLayout.match(in: gameRoot) { return unity }
            return EngineMatch(engine: signature.id, version: nil)
        }
        return nil
    }

    static func displayName(for id: String) -> String {
        engines.first { $0.id == id }?.displayName ?? signatures.first { $0.id == id }?.name ?? id
    }
}
