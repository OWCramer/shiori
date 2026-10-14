import Foundation
import Observation
import OSLog
import SteamKit

private let log = Logger(subsystem: "com.owencramer.vnhub", category: "scan")

/// What a game runs on, learned from its manifests before it's downloaded.
struct EngineScanResult: Codable, Equatable, Sendable {
    var engine: EngineMatch?
    var installSize: UInt64
    var scannedAt: Date
    /// Set when the scan itself failed (no Windows depot, Steam refused, ...).
    var error: String?
    /// When the default branch isn't playable: a beta branch that is (WORLD END ECONOMiCA
    /// episode.01's public build is a Unity remaster; its renpy_old beta is the Ren'Py one).
    var playableBranch: BranchScan?
}

struct BranchScan: Codable, Equatable, Sendable {
    var branch: String
    var engine: EngineMatch?
    var installSize: UInt64
}

/// Whether Shiori can play a game, as far as its engine goes.
enum Playability: Equatable {
    case playable
    /// Ren'Py, but a version this build's runtime can't run.
    case needsRuntime(String)
    case unsupportedEngine(String)
    case unknownEngine
    /// A server-backed game (OnlineGames), whatever it's built with.
    case onlineGame
    /// An engine Shiori plays elsewhere but not on this device (KiriKiri, Siglus and
    /// CatSystem2 on Apple TV), with the sentence saying so.
    case notOnThisDevice(String)

    /// Engines whose runtimes aren't built for Apple TV yet (their game views are left out
    /// of the tvOS app), so Play is never offered there.
    static let iOSOnlyEngines: Set<String> = ["kirikiri", "siglus", "catsystem2"]

    static func notOnAppleTVMessage(_ engine: String) -> String {
        "\(EngineDetection.displayName(for: engine)) games play on an iPhone or iPad, not on Apple TV yet."
    }

    /// For a particular game: online games first, then by engine.
    init(_ engine: EngineMatch?, appID: UInt32) {
        if OnlineGames.contains(appID) { self = .onlineGame; return }
        self.init(engine)
    }

    init(_ engine: EngineMatch?) {
        guard let engine else { self = .unknownEngine; return }
        #if os(tvOS)
        if Self.iOSOnlyEngines.contains(engine.engine) {
            self = .notOnThisDevice(Self.notOnAppleTVMessage(engine.engine))
            return
        }
        #endif
        if ["artemis", "kirikiri", "siglus", "luca", "catsystem2"].contains(engine.engine) { self = .playable; return }
        guard engine.engine == RenPyEngine.id else {
            self = .unsupportedEngine(EngineDetection.displayName(for: engine.engine))
            return
        }
        if let problem = RenPyEngine.incompatibility(engine) {
            self = .needsRuntime(problem)
        } else {
            self = .playable
        }
    }

    /// Short label for badges: "Ren'Py 8", "Ren'Py 7", "Kirikiri", "?".
    static func badge(_ engine: EngineMatch?) -> String {
        guard let engine else { return "Unknown engine" }
        let name = EngineDetection.displayName(for: engine.engine)
        if engine.engine == RenPyEngine.id, let major = engine.version?.split(separator: ".").first {
            return "\(name) \(major)"
        }
        return name
    }

    static func badge(_ engine: EngineMatch?, appID: UInt32) -> String {
        OnlineGames.contains(appID) ? OnlineGames.badge : badge(engine)
    }

    /// "Unity 2018.4.0f1, Mono": what a Unity scan found, for the unsupported message.
    static func unityBuild(_ engine: EngineMatch?) -> String? {
        guard let engine, engine.engine == "unity" else { return nil }
        let parts = [engine.version, engine.details["backend"]].compactMap { $0 }
        return parts.isEmpty ? "Unity" : "Unity " + parts.joined(separator: ", ")
    }

    /// What the game page says about a game Shiori can't play.
    static func unsupportedMessage(_ engine: EngineMatch?, appID: UInt32) -> String? {
        if OnlineGames.contains(appID) { return OnlineGames.explanation }
        if let unity = unityBuild(engine) {
            return "Built with \(unity). Unity games can be downloaded and patched, not played."
        }
        return nil
    }
}

/// Detects engines from depot manifests and keeps the results on disk.
@MainActor @Observable
final class EngineScanStore {
    private(set) var results: [UInt32: EngineScanResult] = [:]
    private(set) var scanning: UInt32?
    private(set) var queue: [UInt32] = []
    private var worker: Task<Void, Never>?
    private let session: SteamSession

    /// Bumped when detection changes, so older results are scanned again.
    private static var url: URL { URL.shioriSupport.appendingPathComponent("engine-scan-8.json") }

    init(session: SteamSession) {
        self.session = session
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([String: EngineScanResult].self, from: data)
        {
            results = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UInt32(key).map { ($0, value) } })
        }
    }

    func result(for appID: UInt32) -> EngineScanResult? { results[appID] }

    /// Queues games that haven't been scanned. Scans run one at a time, gently.
    func scan(_ appIDs: [UInt32], force: Bool = false) {
        for appID in appIDs where (force || results[appID] == nil) && !queue.contains(appID) && scanning != appID {
            queue.append(appID)
        }
        startWorker()
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task {
            while let appID = queue.first {
                queue.removeFirst()
                guard case .loggedOn = await session.state else { break }
                scanning = appID
                let result = await Self.scanOne(appID: appID, session: session)
                results[appID] = result
                save()
                scanning = nil
                log.notice("Scanned \(appID): \(Playability.badge(result.engine), privacy: .public) \(result.engine?.version ?? "", privacy: .public) \(result.error ?? "", privacy: .public)")
                // Conservative pacing: one game at a time with a short pause.
                try? await Task.sleep(for: .milliseconds(500))
            }
            worker = nil
        }
    }

    private func save() {
        let encodable = Dictionary(uniqueKeysWithValues: results.map { (String($0.key), $0.value) })
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(encodable).write(to: Self.url, options: .atomic)
    }

    /// Mirrors the game's top-level layout (and the few files engines are recognised by)
    /// into a temporary folder, then runs the same detection used after a real download.
    nonisolated static func scanOne(appID: UInt32, session: SteamSession) async -> EngineScanResult {
        var result = await scanBranch(appID: appID, branch: "public", session: session)
        guard result.error == nil, Playability(result.engine) != .playable,
              let app = try? await session.appInfo([appID]).first
        else { return result }
        // Not playable as it is: look at the game's public betas, newest first.
        for branch in DepotSelection.branches(of: app) where branch.name != "public" {
            let scan = await scanBranch(appID: appID, branch: branch.name, session: session)
            if scan.error == nil, Playability(scan.engine) == .playable {
                result.playableBranch = BranchScan(branch: branch.name, engine: scan.engine, installSize: scan.installSize)
                break
            }
        }
        return result
    }

    nonisolated static func scanBranch(appID: UInt32, branch: String, session: SteamSession) async -> EngineScanResult {
        do {
            let preview = try await session.preview(appID: appID, branch: branch)
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("scan-\(appID)-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: root) }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            // Placeholders for everything two levels deep, plus a few deeper marker files.
            // Folders first (any path with children is a folder), then empty files.
            let markers: Set<String> = ["www/js/rpg_core.js", "js/rmmz_core.js", "resources/app/tyrano"]
            // A Unity player one folder down (`WEE3 HD/WEE3_Data/…`) is looked at one level deeper.
            func unityNested(_ parts: [String]) -> Bool { parts.count >= 3 && parts[1].lowercased().hasSuffix("_data") }
            var folders: Set<String> = []
            for path in preview.paths {
                let parts = path.split(separator: "/").map(String.init)
                let limit = unityNested(parts) ? 4 : 3
                for depth in 1 ..< min(parts.count, limit) { folders.insert(parts.prefix(depth).joined(separator: "/")) }
            }
            for folder in folders {
                try fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for path in preview.paths where !folders.contains(path) {
                let parts = path.split(separator: "/").map(String.init)
                let depth = parts.count
                guard depth <= 2 || markers.contains(path.lowercased()) || (depth == 3 && unityNested(parts)) else { continue }
                let url = root.appendingPathComponent(path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            }
            // The files Ren'Py's version is read from.
            for path in ["renpy/vc_version.py", "renpy/__init__.py", "game/script_version.txt"] {
                if let data = try await preview.contents(of: path, maxSize: 512 << 10) {
                    let url = root.appendingPathComponent(path)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url)
                }
            }
            var engine = EngineDetection.detect(gameRoot: root)
            // Unity: the version sits in the first bytes of the player's data (one chunk).
            if engine?.engine == "unity", let found = UnityLayout.find(in: root), let data = found.dataFolder {
                let folder = found.folder.isEmpty ? data : "\(found.folder)/\(data)"
                for name in UnityLayout.versionFiles {
                    guard let path = preview.paths.first(where: { $0.lowercased() == "\(folder)/\(name)".lowercased() }),
                          let head = try await preview.prefix(of: path, length: 256), !head.isEmpty else { continue }
                    try head.prefix(4096).write(to: root.appendingPathComponent(path))
                    engine = EngineDetection.detect(gameRoot: root)
                    break
                }
            }
            return EngineScanResult(engine: engine, installSize: preview.totalSize, scannedAt: .now)
        } catch {
            return EngineScanResult(engine: nil, installSize: 0, scannedAt: .now,
                                    error: (error as? SteamError)?.description ?? error.localizedDescription)
        }
    }
}
