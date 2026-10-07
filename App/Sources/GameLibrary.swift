import Observation
import OSLog
import SteamKit
import UIKit

private let log = Logger(subsystem: "com.owencramer.vnhub", category: "games")

/// `game.json`, written into each game folder once its download completes.
struct GameRecord: Codable, Equatable {
    var appID: UInt32
    var name: String
    /// Detected engine, or nil if none was recognised.
    var engine: EngineMatch?
    /// Steam depot builds in `base/`. Usually one manifest per depot.
    var depots: [InstalledDepot]
    var installedAt: Date
    var sizeBytes: UInt64
}

/// Installed and in-progress games on this device.
///
/// Layout: `Documents/Games/<appid>-<slug>/` holds `base/` (what Steam delivered), `patch/`,
/// `saves/` and `game.json`, all visible in the Files app. SteamKit's download bookkeeping
/// lives in `Application Support/Installs/<appid>/`, out of the user's way.
@MainActor @Observable
final class GameLibrary {
    enum Status: Equatable {
        case notInstalled
        case preparing
        case downloading(DownloadProgress)
        /// A download was started and not finished; resuming continues from the finished chunks.
        case paused(DownloadProgress?)
        case verifying(VerifyProgress)
        case installed(GameRecord)
        case failed(String, canResume: Bool)
    }

    private(set) var statuses: [UInt32: Status] = [:]
    /// Last verify result per app, for display.
    private(set) var verifyReports: [UInt32: VerifyReport] = [:]

    private let session: SteamSession
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    /// Downloads paused because the app went to the background, to restart on return.
    private var resumeOnForeground: [UInt32: String] = [:]

    static var gamesDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("Games", isDirectory: true)
    }

    /// Regenerable runtime files (compiled bytecode, Ren'Py caches), kept out of the game folder.
    static func runtimeCache(appID: UInt32) -> URL {
        URL.cachesDirectory.appendingPathComponent("RenPy/\(appID)", isDirectory: true)
    }

    private static var installsDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Installs", isDirectory: true)
    }

    init(session: SteamSession) {
        self.session = session
        try? FileManager.default.createDirectory(at: Self.gamesDirectory, withIntermediateDirectories: true)
        scan()
    }

    func status(for appID: UInt32) -> Status { statuses[appID] ?? .notInstalled }

    var isDownloading: Bool {
        statuses.values.contains { if case .downloading = $0 { true } else if case .preparing = $0 { true } else { false } }
    }

    // MARK: - Folders

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        var slug = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                slug.unicodeScalars.append(scalar)
            } else if !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        let trimmed = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "game" : String(trimmed.prefix(60))
    }

    /// The game's folder, reusing an existing `<appid>-…` folder if the name has changed since.
    func folder(appID: UInt32, name: String) -> URL {
        let prefix = "\(appID)-"
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: Self.gamesDirectory.path))?
            .first { $0.hasPrefix(prefix) }
        return Self.gamesDirectory.appendingPathComponent(existing ?? prefix + Self.slug(name), isDirectory: true)
    }

    private func install(appID: UInt32, folder: URL) -> DepotInstall {
        DepotInstall(
            root: folder.appendingPathComponent("base", isDirectory: true),
            stateDirectory: Self.installsDirectory.appendingPathComponent(String(appID), isDirectory: true)
        )
    }

    /// Rebuilds statuses from disk: `game.json` means installed, leftover bookkeeping means paused.
    func scan() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Self.gamesDirectory.path)) ?? [] {
            let url = Self.gamesDirectory.appendingPathComponent(name).appendingPathComponent("game.json")
            guard let data = try? Data(contentsOf: url),
                  let record = try? Self.decoder.decode(GameRecord.self, from: data)
            else { continue }
            statuses[record.appID] = .installed(record)
        }
        for name in (try? fm.contentsOfDirectory(atPath: Self.installsDirectory.path)) ?? [] {
            guard let appID = UInt32(name), statuses[appID] == nil else { continue }
            statuses[appID] = .paused(nil)
        }
    }

    // MARK: - Download

    /// Starts or resumes downloading the game into its folder.
    func download(_ app: AppInfo) {
        startDownload(appID: app.appID, name: app.name)
    }

    private func startDownload(appID: UInt32, name: String) {
        guard tasks[appID] == nil else { return }
        names[appID] = name
        let folder = folder(appID: appID, name: name)
        let install = install(appID: appID, folder: folder)
        statuses[appID] = .preparing
        updateIdleTimer()

        tasks[appID] = Task {
            do {
                try Self.prepareFolder(folder)
                let depots = try await session.download(appID: appID, into: install) { progress in
                    Task { @MainActor in self.report(progress, for: appID) }
                }
                let record = try await Self.finish(appID: appID, name: name, folder: folder, install: install, depots: depots)
                statuses[appID] = .installed(record)
                log.notice("Installed \(appID): engine \(record.engine?.engine ?? "none", privacy: .public) \(record.engine?.version ?? "?", privacy: .public), \(record.sizeBytes) bytes")
            } catch is CancellationError {
                statuses[appID] = .paused(lastProgress(appID))
                log.notice("Paused \(appID)")
            } catch let error as URLError where error.code == .cancelled {
                statuses[appID] = .paused(lastProgress(appID))
                log.notice("Paused \(appID)")
            } catch {
                statuses[appID] = .failed(Self.message(for: error), canResume: true)
                log.error("Download \(appID) failed: \(String(describing: error), privacy: .public)")
            }
            tasks[appID] = nil
            updateIdleTimer()
        }
    }

    private func report(_ progress: DownloadProgress, for appID: UInt32) {
        // Progress callbacks can trail a pause; don't let them overwrite it.
        guard tasks[appID] != nil else { return }
        switch progress.phase {
        case .preparing: statuses[appID] = .preparing
        case .downloading, .finishing:
            let before = lastProgress(appID).map { Int($0.fraction * 20) } ?? -1
            statuses[appID] = .downloading(progress)
            if Int(progress.fraction * 20) != before {
                log.notice("Download \(appID): \(progress.completedBytes) of \(progress.totalBytes) bytes, \(progress.downloadedBytes) fetched")
            }
        }
    }

    private func lastProgress(_ appID: UInt32) -> DownloadProgress? {
        if case let .downloading(progress) = statuses[appID] { return progress }
        if case let .paused(progress) = statuses[appID] { return progress }
        return nil
    }

    func pause(appID: UInt32) {
        tasks[appID]?.cancel()
    }

    func resume(appID: UInt32, name: String) {
        startDownload(appID: appID, name: name)
    }

    private static func prepareFolder(_ folder: URL) throws {
        let fm = FileManager.default
        for sub in ["base", "patch", "saves"] {
            try fm.createDirectory(at: folder.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true)
        }
        // The game can always be downloaded again; keep gigabytes out of iCloud device backups.
        var base = folder.appendingPathComponent("base", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try base.setResourceValues(values)
    }

    /// Detects the engine and writes `game.json`. Detection reads a few small files, off the main actor.
    private nonisolated static func finish(
        appID: UInt32, name: String, folder: URL, install: DepotInstall, depots: [InstalledDepot]
    ) async throws -> GameRecord {
        let engine = EngineDetection.detect(gameRoot: install.root)
        let size = install.sizeOnDisk()
        let record = GameRecord(appID: appID, name: name, engine: engine, depots: depots, installedAt: .now, sizeBytes: size)
        try encoder.encode(record).write(to: folder.appendingPathComponent("game.json"), options: .atomic)
        return record
    }

    // MARK: - Play

    /// Why the game can't be played, or nil if Play should be offered.
    func playBlocker(appID: UInt32) -> String? {
        guard case let .installed(record) = statuses[appID] else { return "Not downloaded." }
        guard let engine = record.engine else { return "No supported engine was recognised in this game." }
        guard engine.engine == RenPyEngine.id else {
            return "Downloaded, not playable yet: \(EngineDetection.displayName(for: engine.engine)) isn't supported."
        }
        return RenPyEngine.incompatibility(engine)
    }

    /// Hands the app over to the game. Never returns: the app exits when the game quits.
    func play(appID: UInt32) {
        guard playBlocker(appID: appID) == nil, tasks[appID] == nil,
              case let .installed(record) = statuses[appID], let engine = record.engine
        else { return }
        let folder = folder(appID: appID, name: record.name)
        let saves = folder.appendingPathComponent("saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        log.notice("Launching \(appID) with Ren'Py \(engine.version ?? "?", privacy: .public)")
        // Start from a run-loop block, not the main dispatch queue: the game runs inside this
        // call for as long as it plays, and SDL's nested run loop can only drain the main
        // queue (main-actor tasks, timers) if we aren't already occupying it.
        RunLoop.main.perform(inModes: [.default]) {
            RenPyEngine.launch(gameFolder: folder, match: engine, saves: saves, cache: Self.runtimeCache(appID: appID))
        }
    }

    // MARK: - Verify

    func verify(appID: UInt32) {
        guard tasks[appID] == nil, case let .installed(record) = statuses[appID] else { return }
        let install = install(appID: appID, folder: folder(appID: appID, name: record.name))
        statuses[appID] = .verifying(VerifyProgress(totalBytes: record.sizeBytes, checkedBytes: 0))
        tasks[appID] = Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try await install.verify { progress in
                        Task { @MainActor in
                            if case .verifying = self.statuses[appID] { self.statuses[appID] = .verifying(progress) }
                        }
                    }
                }.value
                verifyReports[appID] = report
                log.notice("Verified \(appID): \(report.checkedFiles) files, \(report.problems.count) differ, \(report.extraFiles.count) extra")
                for (path, problem) in report.problems.prefix(20) {
                    log.notice("  \(path, privacy: .public): \(String(describing: problem), privacy: .public)")
                }
            } catch {
                verifyReports[appID] = nil
                log.error("Verify \(appID) failed: \(String(describing: error), privacy: .public)")
            }
            statuses[appID] = .installed(record)
            tasks[appID] = nil
        }
    }

    // MARK: - Delete

    func delete(appID: UInt32, name: String) {
        tasks[appID]?.cancel()
        tasks[appID] = nil
        let folder = folder(appID: appID, name: name)
        try? install(appID: appID, folder: folder).removeState()
        try? FileManager.default.removeItem(at: Self.runtimeCache(appID: appID))
        try? FileManager.default.removeItem(at: folder)
        statuses[appID] = nil
        verifyReports[appID] = nil
        updateIdleTimer()
    }

    // MARK: - App lifecycle

    /// iOS suspends the app shortly after it leaves the screen, which would stall the CDN
    /// requests mid-flight. Pause cleanly instead and pick up again on return.
    func didEnterBackground() {
        for (appID, task) in tasks {
            guard case .downloading = statuses[appID] else { continue }
            if let name = name(of: appID) { resumeOnForeground[appID] = name }
            task.cancel()
        }
    }

    func willEnterForeground() {
        let pending = resumeOnForeground
        resumeOnForeground = [:]
        for (appID, name) in pending { startDownload(appID: appID, name: name) }
    }

    /// Names of games downloaded this launch, for restarting them.
    private var names: [UInt32: String] = [:]

    private func name(of appID: UInt32) -> String? { names[appID] }

    /// Keeps the phone awake while a download runs, since locking it would pause the download.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isDownloading
    }

    private static func message(for error: Error) -> String {
        (error as? SteamError)?.description ?? error.localizedDescription
    }

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension DepotInstall {
    /// Total size of the files in `base/`.
    func sizeOnDisk() -> UInt64 {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey])
        var total: UInt64 = 0
        while let url = files?.nextObject() as? URL {
            total += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
