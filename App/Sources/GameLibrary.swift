import BackgroundTasks
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
        /// Waiting for the download ahead of it; one game downloads at a time.
        case queued
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
    /// The game downloading now, and the ones waiting behind it.
    private(set) var activeDownload: UInt32?
    private(set) var queue: [UInt32] = []
    /// Keeps the active download running while VN Hub is in the background.
    private var backgroundTask: BGContinuedProcessingTask?
    private static let backgroundTaskPrefix = "com.owencramer.vnhub.download"
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

    var isDownloading: Bool { activeDownload != nil }

    /// Downloads that are running, queued, paused or failed, for the downloads list.
    var downloadItems: [UInt32] {
        statuses.compactMap { appID, status in
            switch status {
            case .queued, .preparing, .downloading, .paused, .failed: appID
            default: nil
            }
        }
        .sorted { a, b in
            let rank = { (id: UInt32) -> Int in id == self.activeDownload ? 0 : (self.queue.firstIndex(of: id).map { $0 + 1 } ?? 1000) }
            return rank(a) < rank(b)
        }
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
    func download(_ game: LibraryGame) {
        startDownload(appID: game.appID, name: game.name)
    }

    private func startDownload(appID: UInt32, name: String) {
        guard tasks[appID] == nil else { return }
        names[appID] = name
        if let active = activeDownload, active != appID {
            if !queue.contains(appID) { queue.append(appID) }
            statuses[appID] = .queued
            return
        }
        queue.removeAll { $0 == appID }
        activeDownload = appID
        beginBackgroundTask(appID: appID, name: name)
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
            activeDownload = nil
            if let name = pendingDeletes.removeValue(forKey: appID) { performDelete(appID: appID, name: name) }
            endBackgroundTask(success: { if case .installed = statuses[appID] { true } else { false } }())
            updateIdleTimer()
            startNextQueued()
        }
    }

    private func startNextQueued() {
        guard activeDownload == nil, let next = queue.first, let name = names[next] else { return }
        queue.removeFirst()
        startDownload(appID: next, name: name)
    }

    private func report(_ progress: DownloadProgress, for appID: UInt32) {
        // Progress callbacks can trail a pause; don't let them overwrite it.
        guard tasks[appID] != nil else { return }
        switch progress.phase {
        case .preparing: statuses[appID] = .preparing
        case .downloading, .finishing:
            let before = lastProgress(appID).map { Int($0.fraction * 20) } ?? -1
            statuses[appID] = .downloading(progress)
            updateBackgroundTask(progress)
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
        if queue.contains(appID) {
            queue.removeAll { $0 == appID }
            statuses[appID] = .paused(nil)
            return
        }
        tasks[appID]?.cancel()
    }

    func resume(appID: UInt32, name: String) {
        startDownload(appID: appID, name: name)
    }

    private static func prepareFolder(_ folder: URL) throws {
        let fm = FileManager.default
        for sub in ["base", "patch/game", "saves"] {
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

    // MARK: - Saves (Steam Cloud)

    private(set) var steamCloud: [UInt32: SaveSyncState] = [:]

    func isSteamCloudEnabled(_ appID: UInt32) -> Bool {
        UserDefaults.standard.object(forKey: "steamCloudSaves.\(appID)") as? Bool ?? true
    }

    func setSteamCloud(_ appID: UInt32, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "steamCloudSaves.\(appID)")
        if enabled { Task { await pullSteamCloud(appID: appID) } }
    }

    /// Brings newer Steam Cloud saves down. Read-only towards Steam.
    func pullSteamCloud(appID: UInt32) async {
        guard isSteamCloudEnabled(appID), case let .installed(record) = statuses[appID] else { return }
        guard case .loggedOn = await session.state else {
            steamCloud[appID] = .failed("Not connected to Steam")
            log.notice("Steam Cloud \(appID): skipped, not logged on")
            return
        }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        steamCloud[appID] = .syncing
        do {
            let result = try await SteamCloudSync.pull(session: session, appID: appID, saves: saves)
            steamCloud[appID] = .synced(.now, result.summary)
            log.notice("Steam Cloud \(appID): \(result.summary, privacy: .public); unmapped \(result.unmapped, privacy: .public)")
        } catch {
            steamCloud[appID] = .failed(Self.message(for: error))
            log.error("Steam Cloud \(appID) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Uploads newer saves to Steam Cloud, if uploads are switched on in Settings.
    /// Whether saves made here may go up to Steam Cloud. Not for games run on a newer Ren'Py
    /// than their PC build: the PC's older engine might not load what the newer one wrote.
    func canUploadSteamCloud(_ appID: UInt32) -> Bool {
        guard SteamCloudSync.uploadsEnabled, isSteamCloudEnabled(appID) else { return false }
        guard case let .installed(record) = statuses[appID], let engine = record.engine else { return true }
        return RenPyEngine.savesMatchPC(engine)
    }

    func pushSteamCloud(appID: UInt32) async {
        guard canUploadSteamCloud(appID), case let .installed(record) = statuses[appID],
              case .loggedOn = await session.state
        else { return }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        steamCloud[appID] = .syncing
        do {
            let result = try await SteamCloudSync.push(session: session, appID: appID, saves: saves)
            steamCloud[appID] = .synced(.now, result.summary)
            log.notice("Steam Cloud upload \(appID): \(result.summary, privacy: .public), backup \(result.backupFolder?.path ?? "none", privacy: .public)")
        } catch {
            steamCloud[appID] = .failed(Self.message(for: error))
            log.error("Steam Cloud upload \(appID) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Spec order: Steam Cloud first, then iCloud.
    func syncAllSaveLocations(appID: UInt32) async {
        await pullSteamCloud(appID: appID)
        await pushSteamCloud(appID: appID)
        await syncSaves(appID: appID, direction: .both)
    }

    /// For the moment a game quits, just before VN Hub exits: upload to Steam Cloud and
    /// tell Steam the session is over, waiting up to `timeout` for it.
    private func finishSteamCloudSession(appID: UInt32, timeout: TimeInterval) {
        guard canUploadSteamCloud(appID), case let .installed(record) = statuses[appID] else { return }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        let session = session
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            defer { done.signal() }
            guard case .loggedOn = await session.state else { return }
            let result = try? await SteamCloudSync.push(session: session, appID: appID, saves: saves)
            try? await session.cloudExitSyncDone(appID: appID, clientID: SteamCloudSync.clientID,
                                                 uploadsCompleted: result?.failed.isEmpty ?? false,
                                                 uploadsRequired: !(result?.uploaded.isEmpty ?? true))
            log.notice("Steam Cloud on exit \(appID): \(result?.summary ?? "failed", privacy: .public)")
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    // MARK: - Saves (iCloud)

    enum SaveSyncState: Equatable {
        case idle
        case syncing
        case synced(Date, String)
        case unavailable
        case failed(String)
    }

    private(set) var saveSync: [UInt32: SaveSyncState] = [:]
    /// The game being played, whose saves are pushed when the app backgrounds or the game quits.
    private var playingAppID: UInt32?

    func isCloudSaveEnabled(_ appID: UInt32) -> Bool {
        UserDefaults.standard.object(forKey: "iCloudSaves.\(appID)") as? Bool ?? true
    }

    func setCloudSave(_ appID: UInt32, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "iCloudSaves.\(appID)")
        if enabled { Task { await syncSaves(appID: appID, direction: .both) } }
    }

    /// Syncs one game's saves with iCloud off the main thread and records the outcome.
    /// A sync already running for the game is waited for first, so two never overlap.
    func syncSaves(appID: UInt32, direction: SaveSync.Direction) async {
        guard isCloudSaveEnabled(appID), case let .installed(record) = statuses[appID] else { return }
        if let running = syncTasks[appID] { await running.value }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        saveSync[appID] = .syncing
        let task = Task.detached(priority: .userInitiated) { Self.syncNow(appID: appID, saves: saves, direction: direction) }
        syncTasks[appID] = Task { _ = await task.value }
        let outcome = await task.value
        syncTasks[appID] = nil
        noteSyncOutcome(outcome, for: appID)
    }

    private var syncTasks: [UInt32: Task<Void, Never>] = [:]

    /// Pulls every installed game's saves, e.g. at launch.
    func syncAllSaves() async {
        let installed = statuses.compactMap { appID, status in if case .installed = status { appID } else { nil } }
        for appID in installed { await syncSaves(appID: appID, direction: .both) }
    }

    /// Synchronous push for the running game, when there's no time for a task: the app
    /// going to the background, or the game quitting just before VN Hub exits.
    func pushRunningGameSaves(gameEnded: Bool = false) {
        guard let appID = playingAppID else { return }
        if gameEnded { finishSteamCloudSession(appID: appID, timeout: 20) }
        guard isCloudSaveEnabled(appID), case let .installed(record) = statuses[appID] else { return }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        noteSyncOutcome(Self.syncNow(appID: appID, saves: saves, direction: .push), for: appID)
    }

    private func noteSyncOutcome(_ outcome: Result<SaveSync.Result, Error>, for appID: UInt32) {
        switch outcome {
        case let .success(result):
            saveSync[appID] = .synced(.now, result.summary)
            log.notice("Saves \(appID): \(result.summary, privacy: .public)")
        case let .failure(error as SaveSync.Error) where error == .unavailable:
            saveSync[appID] = .unavailable
        case let .failure(error):
            saveSync[appID] = .failed(error.localizedDescription)
            log.error("Save sync \(appID) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func syncNow(appID: UInt32, saves: URL, direction: SaveSync.Direction) -> Result<SaveSync.Result, Error> {
        guard let root = SaveSync.remoteRoot() else { return .failure(SaveSync.Error.unavailable) }
        return Result { try SaveSync.sync(local: saves, remote: root.appendingPathComponent(String(appID), isDirectory: true), direction: direction) }
    }

    // MARK: - Play

    /// Why the game can't be played, or nil if Play should be offered.
    func playBlocker(appID: UInt32) -> String? {
        guard case let .installed(record) = statuses[appID] else { return "Not downloaded." }
        guard let engine = record.engine else { return "Downloaded, not playable yet: Shiori didn't recognise this game's engine." }
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
        playingAppID = appID
        Task {
            // Bring down saves made elsewhere first: Steam Cloud (the PC), then iCloud.
            await pullSteamCloud(appID: appID)
            if canUploadSteamCloud(appID), case .loggedOn = await session.state {
                let pending = (try? await session.cloudLaunchIntent(appID: appID, clientID: SteamCloudSync.clientID)) ?? []
                for operation in pending {
                    log.notice("Steam Cloud: \(operation.machineName, privacy: .public) is \(operation.description, privacy: .public)")
                }
            }
            await syncSaves(appID: appID, direction: .pull)
            log.notice("Launching \(appID) with Ren'Py \(engine.version ?? "?", privacy: .public)")
            // Start from a run-loop block, not the main dispatch queue: the game runs inside
            // this call for as long as it plays, and SDL's nested run loop can only drain the
            // main queue (main-actor tasks, timers) if we aren't already occupying it.
            RunLoop.main.perform(inModes: [.default]) {
                RenPyEngine.launch(appID: appID, gameFolder: folder, match: engine, saves: saves, cache: Self.runtimeCache(appID: appID)) {
                    MainActor.assumeIsolated { self.pushRunningGameSaves(gameEnded: true) }
                }
            }
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
                for (path, problem) in report.problems.prefix(10) {
                    log.notice("Verify \(appID): \(path, privacy: .public) \(String(describing: problem), privacy: .public)")
                }
                for (path, problem) in report.problems.prefix(20) {
                    log.notice("  \(path, privacy: .public): \(String(describing: problem), privacy: .public)")
                }
            } catch {
                verifyReports[appID] = nil
                log.error("Verify \(appID) failed: \(String(describing: error), privacy: .public)")
            }
            statuses[appID] = .installed(record)
            tasks[appID] = nil
            if let name = pendingDeletes.removeValue(forKey: appID) { performDelete(appID: appID, name: name) }
        }
    }

    // MARK: - Delete

    /// Deletes the game's folder and bookkeeping. A running download or verify is stopped
    /// first, so nothing writes into the folder while it's being removed.
    func delete(appID: UInt32, name: String) {
        queue.removeAll { $0 == appID }
        if let task = tasks[appID] {
            pendingDeletes[appID] = name
            task.cancel()
            return
        }
        performDelete(appID: appID, name: name)
    }

    private var pendingDeletes: [UInt32: String] = [:]

    private func performDelete(appID: UInt32, name: String) {
        let folder = folder(appID: appID, name: name)
        try? install(appID: appID, folder: folder).removeState()
        try? FileManager.default.removeItem(at: Self.runtimeCache(appID: appID))
        try? FileManager.default.removeItem(at: folder)
        statuses[appID] = nil
        verifyReports[appID] = nil
        updateIdleTimer()
    }

    // MARK: - Background continuation

    /// Identifiers iOS accepted a launch handler for; submitting without one throws an
    /// exception, and registering one twice kills the app.
    private var registeredTaskIdentifiers: Set<String> = []
    private var refusedTaskIdentifiers: Set<String> = []

    /// Continued-processing handlers are registered on demand, one per concrete identifier
    /// matching the `.*` entry in Info.plist.
    private func registerBackgroundTask(_ identifier: String) -> Bool {
        if registeredTaskIdentifiers.contains(identifier) { return true }
        if refusedTaskIdentifiers.contains(identifier) { return false }
        let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            MainActor.assumeIsolated { self.adopt(task) }
        }
        if accepted { registeredTaskIdentifiers.insert(identifier) } else { refusedTaskIdentifiers.insert(identifier) }
        log.notice("Background download handler for \(identifier, privacy: .public): \(accepted)")
        return accepted
    }

    /// Asks iOS to keep the download running if the user leaves the app. iOS shows its own
    /// progress UI for it and may decline or end it; then the download pauses as before.
    private func beginBackgroundTask(appID: UInt32, name: String) {
        let identifier = "\(Self.backgroundTaskPrefix).\(appID)"
        guard UIApplication.shared.applicationState == .active, registerBackgroundTask(identifier) else { return }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "Downloading \(name)", subtitle: "Starting…")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.notice("Background continuation unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func adopt(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask else { return }
        guard let appID = activeDownload, task.identifier.hasSuffix(".\(appID)") else {
            task.setTaskCompleted(success: false)
            return
        }
        task.progress.totalUnitCount = 1000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // iOS needs the time back: pause, and pick up again when the app returns.
                if let name = self.name(of: appID) { self.resumeOnForeground[appID] = name }
                self.backgroundTask = nil
                self.tasks[appID]?.cancel()
                task.setTaskCompleted(success: false)
            }
        }
        backgroundTask = task
        log.notice("Background continuation granted for \(appID)")
    }

    private func updateBackgroundTask(_ progress: DownloadProgress) {
        guard let task = backgroundTask else { return }
        task.progress.completedUnitCount = Int64(progress.fraction * 1000)
        let done = progress.completedBytes.formatted(.byteCount(style: .file))
        let total = progress.totalBytes.formatted(.byteCount(style: .file))
        task.updateTitle(task.title, subtitle: "\(done) of \(total)")
    }

    private func endBackgroundTask(success: Bool) {
        guard let task = backgroundTask else { return }
        backgroundTask = nil
        task.setTaskCompleted(success: success)
    }

    // MARK: - App lifecycle

    /// iOS suspends the app shortly after it leaves the screen, which would stall the CDN
    /// requests mid-flight. Pause cleanly instead and pick up again on return.
    func didEnterBackground() {
        // With a continued-processing task the download keeps going; otherwise pause it.
        guard backgroundTask == nil, let appID = activeDownload, let task = tasks[appID] else { return }
        if let name = name(of: appID) { resumeOnForeground[appID] = name }
        task.cancel()
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
