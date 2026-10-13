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
    /// The Steam branch `base/` came from; nil is the default ("public").
    var branch: String?
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

    /// A status without its progress: what a game is doing, which changes only when it moves
    /// from one state to the next (not with every progress report).
    enum Stage: Equatable {
        case notInstalled, queued, preparing, downloading, paused, verifying, installed, failed

        init(_ status: Status) {
            switch status {
            case .notInstalled: self = .notInstalled
            case .queued: self = .queued
            case .preparing: self = .preparing
            case .downloading: self = .downloading
            case .paused: self = .paused
            case .verifying: self = .verifying
            case .installed: self = .installed
            case .failed: self = .failed
            }
        }
    }

    /// Each game's status in its own observable cell, so a progress report re-evaluates only
    /// the views showing that game's progress. One dictionary of statuses made every view
    /// that read any game's status (the shell, Home's shelves, every capsule in the grids)
    /// re-evaluate with each report, which made scrolling during a download hitch. The
    /// dictionary itself changes only when a game gets its first status.
    private var cells: [UInt32: StatusCell] = [:]

    /// The cells as a table of statuses, for the bookkeeping below (nil is not installed).
    private var statuses: StatusTable { StatusTable(library: self) }

    @MainActor
    struct StatusTable {
        let library: GameLibrary

        subscript(appID: UInt32) -> Status? {
            get { library.cells[appID].flatMap { $0.status == .notInstalled ? nil : $0.status } }
            nonmutating set { library.setStatus(newValue ?? .notInstalled, for: appID) }
        }
    }

    private func setStatus(_ status: Status, for appID: UInt32) {
        if let cell = cells[appID] {
            cell.update(status)
        } else if status != .notInstalled {
            cells[appID] = StatusCell(status)
        }
    }

    /// Last verify result per app, for display.
    private(set) var verifyReports: [UInt32: VerifyReport] = [:]

    private let session: SteamSession
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    /// The game downloading now, and the ones waiting behind it.
    private(set) var activeDownload: UInt32?
    private(set) var queue: [UInt32] = []
    /// Keeps the active download running while Shiori is in the background.
    #if os(iOS)
    private var backgroundTask: BGContinuedProcessingTask?
    #else
    /// Apple TV has no continued-processing tasks: downloads pause in the background.
    private var backgroundTask: AnyObject?
    #endif
    private static let backgroundTaskPrefix = "com.owencramer.vnhub.download"
    /// Downloads paused because the app went to the background, to restart on return.
    private var resumeOnForeground: [UInt32: String] = [:]

    static var gamesDirectory: URL {
        URL.shioriDocuments.appendingPathComponent("Games", isDirectory: true)
    }

    /// Regenerable runtime files (compiled bytecode, Ren'Py caches), kept out of the game folder.
    static func runtimeCache(appID: UInt32) -> URL {
        URL.cachesDirectory.appendingPathComponent("RenPy/\(appID)", isDirectory: true)
    }

    private static var installsDirectory: URL {
        URL.shioriSupport.appendingPathComponent("Installs", isDirectory: true)
    }

    init(session: SteamSession) {
        self.session = session
        try? FileManager.default.createDirectory(at: Self.gamesDirectory, withIntermediateDirectories: true)
        scan()
    }

    /// The game's status with its latest progress. Reading it follows every progress report
    /// for that game: views that show progress read it, others read `stage(for:)` or
    /// `record(for:)`.
    func status(for appID: UInt32) -> Status { cells[appID]?.status ?? .notInstalled }

    /// What the game is doing, without progress: changes only between states.
    func stage(for appID: UInt32) -> Stage { cells[appID]?.stage ?? .notInstalled }

    /// The installed game's record, without following progress.
    func record(for appID: UInt32) -> GameRecord? { cells[appID]?.record }

    /// Whether anything of the game is on this device (installed, or a download started).
    func isOnDevice(_ appID: UInt32) -> Bool { stage(for: appID) != .notInstalled }

    /// Games with something on this device.
    var onDeviceAppIDs: Set<UInt32> { Set(cells.compactMap { $0.value.stage == .notInstalled ? nil : $0.key }) }

    /// Installed games' records by app id.
    var installedRecords: [UInt32: GameRecord] { cells.compactMapValues(\.record) }

    var isDownloading: Bool { activeDownload != nil }

    /// Downloads that are running, queued, paused or failed, for the downloads list.
    var downloadItems: [UInt32] {
        cells.compactMap { appID, cell in
            switch cell.stage {
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
                  var record = try? Self.decoder.decode(GameRecord.self, from: data)
            else { continue }
            // Installed before Shiori knew its engine, or recorded as one no runtime takes (an
            // older detector read Sakura Isekai Adventure's Ren'Py 8.1 as its Python 2 twin,
            // 7.6): look again (detection reads a few small files).
            let stale = record.engine == nil
                || (record.engine?.engine == RenPyEngine.id && record.engine.map(RenPyEngine.incompatibility) != nil)
                // Unity from before the layout check (any `_data` name), with no version or backend.
                || (record.engine?.engine == "unity" && record.engine?.version == nil && record.engine?.details["backend"] == nil)
            if stale,
               let engine = EngineDetection.detect(gameRoot: url.deletingLastPathComponent().appendingPathComponent("base", isDirectory: true)),
               engine != record.engine {
                record.engine = engine
                try? Self.encoder.encode(record).write(to: url, options: .atomic)
            }
            statuses[record.appID] = .installed(record)
            #if os(tvOS)
            Self.remember(appID: record.appID, name: record.name)
            #endif
        }
        for name in (try? fm.contentsOfDirectory(atPath: Self.installsDirectory.path)) ?? [] {
            guard let appID = UInt32(name), statuses[appID] == nil else { continue }
            #if os(tvOS)
            // A finished game that lost game.json to tvOS: restoreClearedGames() brings it back.
            if (UserDefaults.standard.dictionary(forKey: Self.installedKey) as? [String: String])?[name] != nil { continue }
            #endif
            statuses[appID] = .paused(nil)
        }
    }

    // MARK: - Download

    /// Starts or resumes downloading the game into its folder.
    func download(_ game: LibraryGame) {
        startDownload(appID: game.appID, name: game.name)
    }

    /// The Steam branch of the game's files when it's installed, else the one it downloads
    /// from: "public" unless a beta was picked (on any of the user's devices; SyncedPreferences).
    func branch(for appID: UInt32) -> String {
        if let record = record(for: appID) { return record.branch ?? "public" }
        return SyncedPreferences.branch(appID: appID) ?? "public"
    }

    /// Picks the Steam branch (a public beta, or "public"). An installed or partly downloaded
    /// game is downloaded again from that branch; `saves/` and `patch/` stay.
    func setBranch(_ branch: String, for appID: UInt32, name: String) {
        guard branch != self.branch(for: appID) else { return }
        SyncedPreferences.setBranch(branch, appID: appID)
        guard statuses[appID] != nil, statuses[appID] != .notInstalled else { return }
        log.notice("Switching \(appID) to branch \(branch, privacy: .public)")
        tasks[appID]?.cancel()
        queue.removeAll { $0 == appID }
        Task {
            if let running = tasks[appID] { await running.value }
            let folder = folder(appID: appID, name: name)
            try? install(appID: appID, folder: folder).removeState()
            let fm = FileManager.default
            try? fm.removeItem(at: folder.appendingPathComponent("base", isDirectory: true))
            try? fm.removeItem(at: folder.appendingPathComponent("game.json"))
            try? fm.removeItem(at: Self.runtimeCache(appID: appID))
            verifyReports[appID] = nil
            statuses[appID] = .notInstalled
            startDownload(appID: appID, name: name)
        }
    }

    private func startDownload(appID: UInt32, name: String) {
        guard tasks[appID] == nil else { return }
        #if DEBUG
        if fakeDownloads.contains(appID) { return startFakeDownload(appID: appID, name: name) }
        #endif
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
        latestProgress[appID] = nil
        progressGates[appID] = nil
        updateIdleTimer()

        tasks[appID] = Task {
            do {
                try Self.prepareFolder(folder)
                let branch = branch(for: appID)
                let depots = try await session.download(appID: appID, branch: branch, into: install) { progress in
                    Task { @MainActor in self.report(progress, for: appID) }
                }
                let record = try await Self.finish(appID: appID, name: name, folder: folder, install: install, depots: depots,
                                                   branch: branch == "public" ? nil : branch)
                statuses[appID] = .installed(record)
                #if os(tvOS)
                Self.remember(appID: appID, name: name)
                restoring.remove(appID)
                #endif
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

    #if DEBUG
    /// Games downloading for show (`-ShioriFakeDownload`); Resume restarts the fake, never Steam.
    @ObservationIgnored private var fakeDownloads: Set<UInt32> = []

    /// `-ShioriFakeDownload <appid>` (debug): progress for a download that isn't happening,
    /// reported as SteamKit reports a real one (every 250 ms, ~24 MB/s of a 2 GB game), with
    /// nothing fetched or written, to measure what a progress tick costs the screens.
    func startFakeDownload(appID: UInt32, name: String) {
        guard tasks[appID] == nil else { return }
        fakeDownloads.insert(appID)
        names[appID] = name
        if let active = activeDownload, active != appID {
            if !queue.contains(appID) { queue.append(appID) }
            statuses[appID] = .queued
            return
        }
        queue.removeAll { $0 == appID }
        activeDownload = appID
        statuses[appID] = .preparing
        let total: UInt64 = 2_000_000_000
        var done = lastProgress(appID)?.completedBytes ?? 0
        tasks[appID] = Task {
            while !Task.isCancelled, done < total {
                try? await Task.sleep(for: .milliseconds(250))
                done = min(total, done + 6_000_000)
                report(DownloadProgress(phase: .downloading, totalBytes: total, completedBytes: done, downloadedBytes: done), for: appID)
            }
            statuses[appID] = done < total ? .paused(lastProgress(appID)) : nil
            tasks[appID] = nil
            activeDownload = nil
            startNextQueued()
        }
    }
    #endif

    private func startNextQueued() {
        guard activeDownload == nil, let next = queue.first, let name = names[next] else { return }
        queue.removeFirst()
        startDownload(appID: next, name: name)
    }

    private func report(_ progress: DownloadProgress, for appID: UInt32) {
        // Progress callbacks can trail a pause; don't let them overwrite it.
        guard tasks[appID] != nil else { return }
        let previous = latestProgress[appID]
        latestProgress[appID] = progress
        switch progress.phase {
        case .preparing: statuses[appID] = .preparing
        case .downloading, .finishing:
            let force = previous?.phase != progress.phase || progress.completedBytes >= progress.totalBytes
            guard progressGates[appID, default: ProgressGate()].admit(progress.fraction, force: force) else { return }
            let shown: DownloadProgress? = if case let .downloading(shown) = statuses[appID] { shown } else { nil }
            let before = shown.map { Int($0.fraction * 20) } ?? -1
            statuses[appID] = .downloading(progress)
            updateBackgroundTask(progress)
            if Int(progress.fraction * 20) != before {
                log.notice("Download \(appID): \(progress.completedBytes) of \(progress.totalBytes) bytes, \(progress.downloadedBytes) fetched")
            }
        }
    }

    /// Every progress report as it came, and which were shown (`ProgressGate`); not observed.
    @ObservationIgnored private var latestProgress: [UInt32: DownloadProgress] = [:]
    @ObservationIgnored private var progressGates: [UInt32: ProgressGate] = [:]

    private func lastProgress(_ appID: UInt32) -> DownloadProgress? {
        if case .downloading = statuses[appID], let latest = latestProgress[appID] { return latest }
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
        appID: UInt32, name: String, folder: URL, install: DepotInstall, depots: [InstalledDepot], branch: String?
    ) async throws -> GameRecord {
        let engine = EngineDetection.detect(gameRoot: install.root)
        let size = install.sizeOnDisk()
        let record = GameRecord(appID: appID, name: name, engine: engine, depots: depots, installedAt: .now, sizeBytes: size,
                                branch: branch)
        try encoder.encode(record).write(to: folder.appendingPathComponent("game.json"), options: .atomic)
        return record
    }

    // MARK: - Saves (Steam Cloud)

    private(set) var steamCloud: [UInt32: SaveSyncState] = [:]

    /// Bumped when the check changes, so cached answers are asked again.
    private static let steamCloudCheckVersion = 3

    /// Whether a game uses Steam Cloud at all on PC (a cloud quota or save rules in its
    /// app info), cached across launches; nil until asked.
    private(set) var steamCloudSupport: [UInt32: Bool] = {
        guard UserDefaults.standard.integer(forKey: "steamCloudSupportVersion") == GameLibrary.steamCloudCheckVersion else { return [:] }
        let saved = UserDefaults.standard.dictionary(forKey: "steamCloudSupport") as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UInt32(key).map { ($0, value) } })
    }()

    /// Whether the game's cloud save rules name a folder Shiori maps onto `saves/` (KiriKiri
    /// games that write the cloud through Steam's API instead have none); nil until asked.
    private(set) var steamCloudMapped: [UInt32: Bool] = {
        guard UserDefaults.standard.integer(forKey: "steamCloudSupportVersion") == GameLibrary.steamCloudCheckVersion else { return [:] }
        let saved = UserDefaults.standard.dictionary(forKey: "steamCloudMapped") as? [String: Bool] ?? [:]
        return Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UInt32(key).map { ($0, value) } })
    }()

    /// Looks up whether the game has Steam Cloud (a read-only app info request).
    func loadSteamCloudSupport(_ appID: UInt32) async {
        guard steamCloudSupport[appID] == nil, case .loggedOn = await session.state,
              let app = try? await session.appInfo([appID]).first else { return }
        // Steam lists the feature as store category 23 ("Steam Cloud"); save rules count too.
        // A quota alone doesn't: Steam gives some games one they never use (Ne no Kami).
        let category = app.keyValues[path: "common", "category", "category_23"]?.value == "1"
        let ufs = UFSConfig(app: app)
        let supported = category || !ufs.saveRules.isEmpty
        log.info("Steam Cloud for \(appID): category \(category), quota \(ufs.quota ?? 0), rules \(ufs.saveRules.count)")
        steamCloudSupport[appID] = supported
        steamCloudMapped[appID] = ufs.saveRules.contains(where: SteamCloudSync.mapsToSaves)
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: steamCloudSupport.map { (String($0.key), $0.value) }),
                                  forKey: "steamCloudSupport")
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: steamCloudMapped.map { (String($0.key), $0.value) }),
                                  forKey: "steamCloudMapped")
        UserDefaults.standard.set(Self.steamCloudCheckVersion, forKey: "steamCloudSupportVersion")
    }

    func isSteamCloudEnabled(_ appID: UInt32) -> Bool {
        UserDefaults.standard.object(forKey: "steamCloudSaves.\(appID)") as? Bool ?? true
    }

    func setSteamCloud(_ appID: UInt32, enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "steamCloudSaves.\(appID)")
        if enabled { Task { await pullSteamCloud(appID: appID) } }
    }

    /// Whether this game's saves are the PC's own files, so Steam Cloud may sync them at all:
    /// Artemis, Luca and CatSystem2 save in Shiori's own format (a PC save pulled over them,
    /// or one of theirs pushed over a PC save, would break both); KiriKiri and Siglus only
    /// when the game's cloud rules name the save folder. Every Steam Cloud pull and push
    /// checks it, whatever asked (Sync Now, the launcher, the TV page, catch-up, leaving).
    func usesSteamCloud(_ appID: UInt32) -> Bool {
        guard case let .installed(record) = statuses[appID] else { return false }
        switch record.engine?.engine {
        case "artemis", "luca", "catsystem2": return false
        case "kirikiri", "siglus": return steamCloudMapped[appID] == true
        default: return true
        }
    }

    /// Brings newer Steam Cloud saves down. Read-only towards Steam.
    func pullSteamCloud(appID: UInt32) async {
        // Nothing to bring down for games without Steam Cloud.
        if steamCloudSupport[appID] == false { return }
        guard usesSteamCloud(appID) else {
            log.notice("Steam Cloud \(appID): skipped, this game's saves aren't the PC's")
            return
        }
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

    /// Whether saves made here may go up to Steam Cloud. Not for games run on a newer Ren'Py
    /// than their PC build: the PC's older engine might not load what the newer one wrote.
    func canUploadSteamCloud(_ appID: UInt32) -> Bool {
        // A debug dry run walks the upload paths without writing anything to Steam.
        guard SteamCloudSync.uploadsEnabled || SteamCloudSync.dryRunUploads, isSteamCloudEnabled(appID) else { return false }
        guard case let .installed(record) = statuses[appID], let engine = record.engine else { return true }
        return RenPyEngine.savesMatchPC(engine)
    }

    /// Uploads changed saves (newer here, different contents) to Steam Cloud, backing up each
    /// cloud copy it replaces first. Returns whether it ran without a failed file; a
    /// successful push is recorded for the next launch's catch-up.
    @discardableResult
    func pushSteamCloud(appID: UInt32) async -> Bool {
        guard uploadsToSteamCloud(appID), case let .installed(record) = statuses[appID],
              case .loggedOn = await session.state
        else { return false }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        let started = Date()
        let newest = SavePushLedger.newestSave(in: saves)
        steamCloud[appID] = .syncing
        do {
            let result = try await SteamCloudSync.push(session: session, appID: appID, saves: saves)
            steamCloud[appID] = .synced(.now, result.summary)
            log.notice("Steam Cloud upload \(appID): \(result.summary, privacy: .public), backup \(result.backupFolder?.path ?? "none", privacy: .public)")
            guard result.dryRun || result.failed.isEmpty else { return false }
            SavePushLedger.record(result.dryRun ? .steamCloudDryRun : .steamCloud, appID: appID, pushedAt: started, newestSave: newest)
            return true
        } catch {
            steamCloud[appID] = .failed(Self.message(for: error))
            log.error("Steam Cloud upload \(appID) failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Whether this game's saves go up to Steam Cloud from here: the upload switches and the
    /// Ren'Py runtime rule (`canUploadSteamCloud`), plus per engine the rules for leaving a
    /// game: KiriKiri and Siglus only when the cloud rules name the save folder; Artemis, Luca
    /// and CatSystem2 never (Shiori's own save format).
    func uploadsToSteamCloud(_ appID: UInt32) -> Bool {
        canUploadSteamCloud(appID) && usesSteamCloud(appID)
    }

    /// Spec order: Steam Cloud first, then iCloud.
    func syncAllSaveLocations(appID: UInt32) async {
        await pullSteamCloud(appID: appID)
        await pushSteamCloud(appID: appID)
        await syncSaves(appID: appID, direction: .both)
    }

    /// Tells Steam a play session is starting (read-only), logging any other device's
    /// operation still pending. Sent where leaving the game ends the session with
    /// `finishSteamCloudSession`.
    private func sendSteamCloudLaunchIntent(appID: UInt32) async {
        guard case .loggedOn = await session.state else { return }
        let pending = (try? await session.cloudLaunchIntent(appID: appID, clientID: SteamCloudSync.clientID)) ?? []
        for operation in pending {
            log.notice("Steam Cloud: \(operation.machineName, privacy: .public) is \(operation.description, privacy: .public)")
        }
    }

    /// For the moment a game quits, just before Shiori exits: upload to Steam Cloud and
    /// tell Steam the session is over, waiting up to `timeout` for it.
    private func finishSteamCloudSession(appID: UInt32) async {
        guard uploadsToSteamCloud(appID), case let .installed(record) = statuses[appID],
              case .loggedOn = await session.state
        else { return }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        let started = Date()
        let newest = SavePushLedger.newestSave(in: saves)
        let result = try? await SteamCloudSync.push(session: session, appID: appID, saves: saves)
        if let result, result.dryRun || result.failed.isEmpty {
            SavePushLedger.record(result.dryRun ? .steamCloudDryRun : .steamCloud, appID: appID, pushedAt: started, newestSave: newest)
        }
        // A dry run tells Steam nothing.
        if !SteamCloudSync.dryRunUploads {
            try? await session.cloudExitSyncDone(appID: appID, clientID: SteamCloudSync.clientID,
                                                 uploadsCompleted: result?.failed.isEmpty ?? false,
                                                 uploadsRequired: !(result?.uploaded.isEmpty ?? true))
        }
        log.notice("Steam Cloud on exit \(appID): \(result?.summary ?? "failed", privacy: .public)")
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

    /// What Play is doing before the game appears.
    enum LaunchPhase: Equatable {
        case steamCloud, iCloud, starting

        var label: String {
            switch self {
            case .steamCloud: "Getting Steam Cloud saves…"
            case .iCloud: "Getting iCloud saves…"
            case .starting: "Starting…"
            }
        }
    }

    /// The library entry for a game (with picked artwork), for the launch cover. Set by the app.
    var libraryEntry: (UInt32) -> LibraryGame? = { _ in nil }

    /// The game being launched and how far along, until the game takes over the screen.
    private(set) var launching: (appID: UInt32, phase: LaunchPhase)?

    func launchPhase(for appID: UInt32) -> LaunchPhase? {
        launching?.appID == appID ? launching?.phase : nil
    }

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
        let started = Date()
        let task = Task.detached(priority: .userInitiated) {
            (SavePushLedger.newestSave(in: saves), Self.syncNow(appID: appID, saves: saves, direction: direction))
        }
        syncTasks[appID] = Task { _ = await task.value }
        let (newest, outcome) = await task.value
        syncTasks[appID] = nil
        noteSyncOutcome(outcome, for: appID, pushed: direction == .pull ? nil : (started, newest))
    }

    private var syncTasks: [UInt32: Task<Void, Never>] = [:]

    /// Syncs every installed game's saves with iCloud at launch: first the catch-up (saves
    /// left behind last time go up), then both ways.
    func syncAllSaves() async {
        let installed = installedAppIDs
        for appID in installed { await catchUpICloud(appID: appID) }
        for appID in installed { await syncSaves(appID: appID, direction: .both) }
    }

    private var installedAppIDs: [UInt32] {
        cells.compactMap { appID, cell in cell.stage == .installed ? appID : nil }.sorted()
    }

    private func savesFolder(_ appID: UInt32) -> URL? {
        guard case let .installed(record) = statuses[appID] else { return nil }
        return folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
    }

    // MARK: - Save catch-up

    // Saves can be left behind: the app force quit or crashed before pushing, or iOS ended
    // its background time first. Each push is recorded (`SavePushLedger`); a game whose save
    // files are newer than its last push gets pushed before anything is pulled over them:
    // iCloud at launch, Steam Cloud once signed in, and both before a game's pre-play pull.
    // The usual rules hold: newest wins per file, and the older copy is kept.

    private nonisolated static func ledgerCheck(_ destination: SavePushLedger.Destination, appID: UInt32, saves: URL) async -> SavePushLedger.Check {
        await Task.detached(priority: .userInitiated) { SavePushLedger.check(destination, appID: appID, saves: saves) }.value
    }

    /// Pushes the game's saves to iCloud if any are newer than its last iCloud push.
    func catchUpICloud(appID: UInt32) async {
        guard isCloudSaveEnabled(appID), let saves = savesFolder(appID) else { return }
        switch await Self.ledgerCheck(.iCloud, appID: appID, saves: saves) {
        case .upToDate:
            return
        case let .pending(newest, lastPush):
            log.notice("Catch-up \(appID): saves from \(newest, privacy: .public) never reached iCloud (last push \(lastPush?.description ?? "none", privacy: .public)); pushing")
        case let .unknown(newest):
            log.notice("Catch-up \(appID): no iCloud push recorded (newest save \(newest, privacy: .public)); pushing")
        }
        await syncSaves(appID: appID, direction: .push)
    }

    private var steamCatchUps: [UInt32: Task<Void, Never>] = [:]

    /// Uploads the game's changed saves to Steam Cloud if any are newer than its last
    /// upload, for games allowed to upload. Without a record yet, the saves on disk become
    /// the baseline instead (nothing is uploaded on the first check).
    func catchUpSteamCloud(appID: UInt32) async {
        if let running = steamCatchUps[appID] { return await running.value }
        guard uploadsToSteamCloud(appID), let saves = savesFolder(appID) else { return }
        let destination: SavePushLedger.Destination = SteamCloudSync.dryRunUploads ? .steamCloudDryRun : .steamCloud
        let task = Task {
            switch await Self.ledgerCheck(destination, appID: appID, saves: saves) {
            case .upToDate:
                return
            case let .unknown(newest):
                SavePushLedger.record(destination, appID: appID, pushedAt: newest, newestSave: newest)
                log.notice("Catch-up \(appID): first Steam Cloud check; saves up to \(newest, privacy: .public) taken as the baseline")
            case let .pending(newest, lastPush):
                guard case .loggedOn = await session.state else {
                    log.notice("Catch-up \(appID): saves from \(newest, privacy: .public) wait for Steam sign-in")
                    return
                }
                log.notice("Catch-up \(appID): saves from \(newest, privacy: .public) never reached Steam Cloud (last upload \(lastPush?.description ?? "none", privacy: .public)); uploading\(destination == .steamCloudDryRun ? " (dry run)" : "", privacy: .public)")
                await pushSteamCloud(appID: appID)
            }
        }
        steamCatchUps[appID] = task
        await task.value
        steamCatchUps[appID] = nil
    }

    /// Once signed in to Steam: every installed game's Steam Cloud catch-up.
    func catchUpSteamCloudAll() async {
        for appID in installedAppIDs { await catchUpSteamCloud(appID: appID) }
    }

    /// Before a game's pre-play pull: send up what this device has that never went up.
    private func catchUp(appID: UInt32) async {
        await catchUpICloud(appID: appID)
        await catchUpSteamCloud(appID: appID)
    }

    // MARK: - Saves on going to the background

    /// How long the background save may take in all; iOS allows about 30 seconds.
    private static let backgroundSaveDeadline: Duration = .seconds(20)
    /// How long to wait for the game's own autosave to land in `saves/`.
    private nonisolated static let autosaveWait: Duration = .seconds(4)

    /// The game being played right now, in any engine.
    var runningGameAppID: UInt32? {
        if let playingAppID { return playingAppID }
        return [artemisSession, kirikiriSession, siglusSession, lucaSession, catSystemSession]
            .compactMap { $0?.appID }.first { $0 != 0 }
    }

    private var backgroundSave: (id: UIBackgroundTaskIdentifier, steps: Task<Void, Never>, deadline: Task<Void, Never>)?

    /// The app went to the background with a game running (the game is still running, so its
    /// Steam Cloud session stays open). Like Steam's sync on exit, inside one background task:
    /// let the game's autosave land, copy the saves to iCloud, then upload changed files to
    /// Steam Cloud where this game may upload. Whatever doesn't finish is caught up next launch.
    func saveRunningGameForBackground() {
        guard backgroundSave == nil, let appID = runningGameAppID, case let .installed(record) = statuses[appID],
              let saves = savesFolder(appID) else { return }
        let engine = record.engine?.engine ?? "?"
        let entered = Date()
        log.notice("Background save \(appID) (\(engine, privacy: .public)): started")
        let id = UIApplication.shared.beginBackgroundTask(withName: "Save sync on background") { [weak self] in
            MainActor.assumeIsolated {
                log.error("Background save \(appID): iOS ended the background time; the rest is caught up next launch")
                if let self, let current = self.backgroundSave { self.endBackgroundSave(current.id, reason: "expired") }
            }
        }
        let steps = Task { [weak self] in
            await self?.backgroundSaveSteps(appID: appID, engine: engine, saves: saves, entered: entered)
            self?.endBackgroundSave(id, reason: "done")
        }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: Self.backgroundSaveDeadline)
            guard !Task.isCancelled else { return }
            log.error("Background save \(appID): deadline reached; the rest is caught up next launch")
            self?.endBackgroundSave(id, reason: "deadline")
        }
        backgroundSave = (id, steps, deadline)
    }

    private func endBackgroundSave(_ id: UIBackgroundTaskIdentifier, reason: String) {
        guard let current = backgroundSave, current.id == id else { return }
        backgroundSave = nil
        current.deadline.cancel()
        if reason != "done" { current.steps.cancel() }
        log.notice("Background save: background task ended (\(reason, privacy: .public))")
        UIApplication.shared.endBackgroundTask(id)
    }

    private func backgroundSaveSteps(appID: UInt32, engine: String, saves: URL, entered: Date) async {
        // 1. The game's own save. Ren'Py autosaves and writes its reload save as it leaves the
        // screen, Luca and CatSystem2 autosave, Siglus saves the place into one of the game's
        // slots (as the app resigns active, while the GPU and the engine are still its);
        // KiriKiri writes its system data then too, and Artemis its globals.
        let written = await Self.waitForSaveWrites(in: saves, since: entered.addingTimeInterval(-3))
        log.notice("Background save \(appID) step 1, game's save (\(engine, privacy: .public)): \(written.isEmpty ? "no new files" : "wrote " + written.joined(separator: ", "), privacy: .public)")
        guard !Task.isCancelled else { return }

        // 2. iCloud.
        if isCloudSaveEnabled(appID) {
            await syncSaves(appID: appID, direction: .push)
            log.notice("Background save \(appID) step 2, iCloud: \(String(describing: self.saveSync[appID] ?? .idle), privacy: .public)")
        } else {
            log.notice("Background save \(appID) step 2, iCloud: off for this game")
        }
        guard !Task.isCancelled else { return }

        // 3. Steam Cloud: changed files only, each replaced cloud copy backed up first; the
        // app session isn't ended (the game is still running).
        guard uploadsToSteamCloud(appID) else {
            log.notice("Background save \(appID) step 3, Steam Cloud: this game doesn't upload from here")
            return
        }
        guard case .loggedOn = await session.state else {
            log.notice("Background save \(appID) step 3, Steam Cloud: not signed in; caught up next launch")
            return
        }
        let pushed = await pushSteamCloud(appID: appID)
        log.notice("Background save \(appID) step 3, Steam Cloud\(SteamCloudSync.dryRunUploads ? " (dry run)" : "", privacy: .public): \(pushed ? "done" : "didn't finish", privacy: .public), \(String(describing: self.steamCloud[appID] ?? .idle), privacy: .public)")
    }

    /// Waits for the game's save files to stop changing (at least a second, at most
    /// `autosaveWait`), then returns the files written since `since`.
    private nonisolated static func waitForSaveWrites(in saves: URL, since: Date) async -> [String] {
        let clock = ContinuousClock()
        let start = clock.now
        var last = await Task.detached { SaveSync.files(in: saves) }.value
        var quietSince = clock.now
        while clock.now - start < autosaveWait, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let now = await Task.detached { SaveSync.files(in: saves) }.value
            if now != last { last = now; quietSince = clock.now }
            if clock.now - start >= .seconds(1), clock.now - quietSince >= .milliseconds(750) { break }
        }
        return last.filter { $0.value >= since }.keys.sorted()
    }

    /// Set once a game has ended, while its saves go up before the app closes.
    private(set) var endingSession: UInt32?
    /// Why the last game couldn't start, shown as an alert.
    var launchFailure: String?

    /// The game returned. Put the hub back with a "saving" screen, sync without blocking the
    /// main thread (iOS kills an app whose main thread can't answer), then close.
    private func gameEnded(appID: UInt32, status: Int32) {
        launching = nil
        // The game never started: nothing to sync, and the app can carry on.
        if status == RenPyEngine.notStarted || status == RenPyEngine.runtimeNotLoaded {
            shiori_renpy_restore_hub()
            launchFailure = RenPyEngine.lastSessionError()
                ?? (status == RenPyEngine.runtimeNotLoaded ? "The game engine couldn't load." : "The game couldn't start.")
            log.error("Ren'Py didn't start (status \(status)): \(self.launchFailure ?? "", privacy: .public)")
            return
        }
        endingSession = appID
        shiori_renpy_restore_hub()
        let background = UIApplication.shared.beginBackgroundTask(withName: "Save sync after game")
        Task {
            // At most 20 s: a task group would wait for a slow upload even after cancelAll,
            // so race the upload against a timer and go on with whichever finishes first.
            await Self.firstOf(seconds: 20) { await self.finishSteamCloudSession(appID: appID) }
            pushRunningGameSaves()
            log.notice("Session \(appID) closed after save sync (game status \(status))")
            UIApplication.shared.endBackgroundTask(background)
            exit(status == 0 ? 0 : 1)
        }
    }

    /// Synchronous iCloud push for the Ren'Py game that just quit, before Shiori exits.
    /// Runs `work`, returning when it finishes or after `seconds`, whichever comes first
    /// (the work carries on in the background if the time runs out).
    nonisolated static func firstOf(seconds: Double, _ work: @escaping @Sendable () async -> Void) async {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await work()
                if once.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if once.claim() { continuation.resume() }
            }
        }
    }

    func pushRunningGameSaves() {
        guard let appID = playingAppID else { return }
        guard isCloudSaveEnabled(appID), case let .installed(record) = statuses[appID] else { return }
        let saves = folder(appID: appID, name: record.name).appendingPathComponent("saves", isDirectory: true)
        let started = Date()
        let newest = SavePushLedger.newestSave(in: saves)
        noteSyncOutcome(Self.syncNow(appID: appID, saves: saves, direction: .push), for: appID, pushed: (started, newest))
    }

    /// `pushed`: for a sync that sends files up, when it started and the newest save then,
    /// recorded on success for the next launch's catch-up.
    private func noteSyncOutcome(_ outcome: Result<SaveSync.Result, Error>, for appID: UInt32, pushed: (at: Date, newest: Date?)? = nil) {
        switch outcome {
        case let .success(result):
            saveSync[appID] = .synced(.now, result.summary)
            log.notice("Saves \(appID): \(result.summary, privacy: .public)")
            if let pushed { SavePushLedger.record(.iCloud, appID: appID, pushedAt: pushed.at, newestSave: pushed.newest) }
        case let .failure(error as SaveSync.Error) where error == .unavailable:
            saveSync[appID] = .unavailable
            log.notice("Saves \(appID): iCloud isn't available, nothing synced")
        case let .failure(error):
            saveSync[appID] = .failed(error.localizedDescription)
            log.error("Save sync \(appID) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func syncNow(appID: UInt32, saves: URL, direction: SaveSync.Direction) -> Result<SaveSync.Result, Error> {
        guard let root = SaveSync.remoteRoot() else { return .failure(SaveSync.Error.unavailable) }
        let remote = root.appendingPathComponent(String(appID), isDirectory: true)
        // Before anything moves: the files the removed "pick up where you left off" left behind.
        let removed = ResumeLeftovers.removeOnce(appID: appID, local: saves, remote: remote)
        if !removed.isEmpty { NSLog("Saves %u: removed Shiori's old resume files %@", appID, removed.joined(separator: ", ")) }
        return Result { try SaveSync.sync(local: saves, remote: remote, direction: direction) }
    }

    // MARK: - Play

    /// Why the game can't be played, or nil if Play should be offered.
    func playBlocker(appID: UInt32) -> String? {
        guard let record = record(for: appID) else { return "Not downloaded." }
        if let message = Playability.unsupportedMessage(record.engine, appID: appID) { return message }
        guard let engine = record.engine else { return "Shiori didn't recognise this game's engine." }
        #if os(tvOS)
        // Their game views aren't in the tvOS app: a session would open nothing.
        if Playability.iOSOnlyEngines.contains(engine.engine) { return Playability.notOnAppleTVMessage(engine.engine) }
        #endif
        if ["artemis", "siglus", "luca", "catsystem2"].contains(engine.engine) { return nil }
        if engine.engine == "kirikiri" {
            #if targetEnvironment(simulator)
            return "KiriKiri games don't run in Simulator."
            #else
            return nil
            #endif
        }
        guard engine.engine == RenPyEngine.id else {
            return "\(EngineDetection.displayName(for: engine.engine)) isn't supported."
        }
        return RenPyEngine.incompatibility(engine)
    }

    /// A game played in-process (Artemis, KiriKiri); leaving returns here.
    struct ArtemisSession: Identifiable {
        let appID: UInt32
        let folder: URL
        /// Shown until the game draws its first frame, like Ren'Py's launch cover.
        var cover = LaunchCover.Art()
        var id: UInt32 { appID }
    }

    var artemisSession: ArtemisSession? {
        didSet {
            // Leaving an Artemis game: send its saves up.
            if let ended = oldValue, artemisSession == nil {
                Task { await syncSaves(appID: ended.appID, direction: .push) }
            }
        }
    }

    /// A KiriKiri game being played (AetherKrkr runs in-process; leaving returns here).
    var kirikiriSession: ArtemisSession? {
        didSet {
            // Leaving: send its saves up.
            if let ended = oldValue, kirikiriSession == nil, ended.appID != 0 {
                Task {
                    await syncSaves(appID: ended.appID, direction: .push)
                    if steamCloudMapped[ended.appID] == true { await finishSteamCloudSession(appID: ended.appID) }
                }
            }
        }
    }

    /// A Siglus game being played (siglus_rs runs in-process; leaving returns here).
    var siglusSession: ArtemisSession? {
        didSet {
            // Leaving: send its saves up.
            if let ended = oldValue, siglusSession == nil, ended.appID != 0 {
                Task {
                    await syncSaves(appID: ended.appID, direction: .push)
                    if steamCloudMapped[ended.appID] == true { await finishSteamCloudSession(appID: ended.appID) }
                }
            }
        }
    }

    /// A Luca System game being played (LucaKit, in-process; leaving returns here).
    var lucaSession: ArtemisSession? {
        didSet {
            // Leaving: send its saves up (Shiori's own format, so iCloud only).
            if let ended = oldValue, lucaSession == nil, ended.appID != 0 {
                Task { await syncSaves(appID: ended.appID, direction: .push) }
            }
        }
    }

    /// A CatSystem2 game being played (CatSystemKit, in-process; leaving returns here).
    var catSystemSession: ArtemisSession? {
        didSet {
            // Leaving: send its saves up (Shiori's own format, so iCloud only).
            if let ended = oldValue, catSystemSession == nil, ended.appID != 0 {
                Task { await syncSaves(appID: ended.appID, direction: .push) }
            }
        }
    }

    /// Hands the app over to the game. Never returns: the app exits when the game quits.
    func play(appID: UInt32) {
        guard playBlocker(appID: appID) == nil, tasks[appID] == nil, launching == nil,
              case let .installed(record) = statuses[appID], let engine = record.engine
        else { return }
        #if os(iOS)
        // The first game on an engine: its controls first, before the engine takes the screen.
        if ControlsGuide.shared.interceptPlay(appID: appID, engine: engine.engine, gameName: record.name) { return }
        #endif
        let folder = folder(appID: appID, name: record.name)
        if ["artemis", "kirikiri", "siglus", "luca", "catsystem2"].contains(engine.engine) {
            // ArtemisKit's saves aren't the PC's format, so no Steam Cloud; iCloud mirrors them.
            // KiriKiri's and Siglus's are the PC's own: Steam Cloud too, for games whose cloud
            // rules name savedata/ (games that write the cloud through Steam's API aren't mapped).
            launching = (appID, .iCloud)
            let entry = libraryEntry(appID)
            let coverFolder = Self.runtimeCache(appID: appID).appendingPathComponent("cover", isDirectory: true)
            Task {
                // The cover's art downloads while saves sync (usually from URLCache).
                async let cover = Self.fetchCover(hero: entry?.hero ?? entry?.header, logo: entry?.logo, into: coverFolder)
                // Saves left behind here go up before anything is pulled over them.
                await catchUp(appID: appID)
                await syncSaves(appID: appID, direction: .pull)
                if !["artemis", "luca", "catsystem2"].contains(engine.engine), steamCloudMapped[appID] == true {
                    await pullSteamCloud(appID: appID)
                    // The session's start, to match finishSteamCloudSession when it's left.
                    if uploadsToSteamCloud(appID) { await sendSteamCloudLaunchIntent(appID: appID) }
                }
                #if !os(tvOS)
                if engine.engine == "kirikiri" {
                    let runtimeCache = URL.cachesDirectory.appendingPathComponent("KiriKiri/\(folder.lastPathComponent)", isDirectory: true)
                    await GARbroDatabase.prepare(appID: appID, runtimeCache: runtimeCache)
                }
                #endif
                let (heroFile, logoFile) = await cover
                let art = LaunchCover.Art(hero: heroFile.flatMap { UIImage(contentsOfFile: $0.path) },
                                          logo: logoFile.flatMap { UIImage(contentsOfFile: $0.path) },
                                          title: record.name)
                launching = nil
                if engine.engine == "kirikiri" {
                    kirikiriSession = ArtemisSession(appID: appID, folder: folder, cover: art)
                } else if engine.engine == "siglus" {
                    siglusSession = ArtemisSession(appID: appID, folder: folder, cover: art)
                } else if engine.engine == "luca" {
                    lucaSession = ArtemisSession(appID: appID, folder: folder, cover: art)
                } else if engine.engine == "catsystem2" {
                    catSystemSession = ArtemisSession(appID: appID, folder: folder, cover: art)
                } else {
                    artemisSession = ArtemisSession(appID: appID, folder: folder, cover: art)
                }
                // Home's "last played" (synced) changes once the launch cover has slid over the
                // library, so Continue Playing doesn't reshuffle under the finger.
                try? await Task.sleep(for: .milliseconds(600))
                PlayHistory.shared.recordLaunch(appID)
            }
            return
        }
        let saves = folder.appendingPathComponent("saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        playingAppID = appID
        let entry = libraryEntry(appID)
        let coverFolder = Self.runtimeCache(appID: appID).appendingPathComponent("cover", isDirectory: true)
        Task {
            // The launch cover's art downloads while saves sync (usually from URLCache).
            async let cover = Self.fetchCover(hero: entry?.hero ?? entry?.header, logo: entry?.logo, into: coverFolder)
            // Saves left behind here go up first, so the pulls never overwrite them.
            await catchUp(appID: appID)
            // Bring down saves made elsewhere first: Steam Cloud (the PC), then iCloud.
            if isSteamCloudEnabled(appID) { launching = (appID, .steamCloud) }
            await pullSteamCloud(appID: appID)
            if canUploadSteamCloud(appID) { await sendSteamCloudLaunchIntent(appID: appID) }
            if isCloudSaveEnabled(appID) { launching = (appID, .iCloud) }
            await syncSaves(appID: appID, direction: .pull)
            launching = (appID, .starting)
            PlayHistory.shared.recordLaunch(appID) // Home's "last played" (synced), as the game takes over.
            let (heroFile, logoFile) = await cover
            for (name, file) in [("SHIORI_COVER_HERO", heroFile), ("SHIORI_COVER_LOGO", logoFile)] {
                if let file { setenv(name, file.path, 1) } else { unsetenv(name) }
            }
            setenv("SHIORI_COVER_TITLE", record.name, 1)
            log.notice("Launching \(appID) with Ren'Py \(engine.version ?? "?", privacy: .public)")
            // Start from a run-loop block, not the main dispatch queue: the game runs inside
            // this call for as long as it plays, and SDL's nested run loop can only drain the
            // main queue (main-actor tasks, timers) if we aren't already occupying it.
            RunLoop.main.perform(inModes: [.default]) {
                let status = RenPyEngine.launch(appID: appID, gameFolder: folder, match: engine, saves: saves,
                                                cache: Self.runtimeCache(appID: appID))
                MainActor.assumeIsolated { self.gameEnded(appID: appID, status: status) }
            }
        }
    }

    /// Saves the cover's banner and logo to files the runtime can load. Gives up quickly:
    /// the cover falls back to the game's name.
    /// The image cropped to its non-transparent pixels, or nil if there's nothing to crop.
    nonisolated static func trimmingTransparentMargins(_ image: UIImage) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width, height = cg.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        let drawn = alpha.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where alpha[y * width + x] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let margin = 4
        let crop = CGRect(x: max(0, minX - margin), y: max(0, minY - margin),
                          width: min(width, maxX + margin + 1) - max(0, minX - margin),
                          height: min(height, maxY + margin + 1) - max(0, minY - margin))
        guard crop.width < CGFloat(width) || crop.height < CGFloat(height),
              let cropped = cg.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }

    nonisolated private static func fetchCover(hero: URL?, logo: URL?, into folder: URL) async -> (URL?, URL?) {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func fetch(_ url: URL?, as name: String) async -> URL? {
            guard let url else { return nil }
            let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 4)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data)
            else { return nil }
            // Steam logos sit on a wide transparent canvas; keep only the mark.
            let saved = name == "logo" ? (trimmingTransparentMargins(image)?.pngData() ?? data) : data
            let file = folder.appendingPathComponent(name)
            return (try? saved.write(to: file)) != nil ? file : nil
        }
        async let heroFile = fetch(hero, as: "hero")
        async let logoFile = fetch(logo, as: "logo")
        return await (heroFile, logoFile)
    }

    #if os(tvOS)
    // MARK: - Games tvOS cleared

    /// Installed games by app id, in UserDefaults, which tvOS keeps: everything else Shiori
    /// writes on Apple TV is in Caches, which tvOS may clear (game.json and the install
    /// bookkeeping included), so this is how Shiori knows what it had.
    private static let installedKey = "tvInstalledGames"

    private static func remember(appID: UInt32, name: String) {
        var games = UserDefaults.standard.dictionary(forKey: installedKey) as? [String: String] ?? [:]
        guard games[String(appID)] != name else { return }
        games[String(appID)] = name
        UserDefaults.standard.set(games, forKey: installedKey)
    }

    private static func forget(appID: UInt32) {
        var games = UserDefaults.standard.dictionary(forKey: installedKey) as? [String: String] ?? [:]
        guard games.removeValue(forKey: String(appID)) != nil else { return }
        UserDefaults.standard.set(games, forKey: installedKey)
    }

    /// Games being downloaded again because tvOS cleared some or all of their files.
    private(set) var restoring: Set<UInt32> = []
    private var checkingCleared = false

    /// Finds installed games that lost files to tvOS and downloads what's missing (only
    /// those files: the depot writer re-fetches a file that's absent or the wrong size).
    /// A game whose folder went entirely is downloaded again from scratch. Needs Steam, so
    /// it runs once signed in, and again when the app comes back to the foreground.
    func restoreClearedGames() {
        guard !checkingCleared else { return }
        checkingCleared = true
        let remembered = UserDefaults.standard.dictionary(forKey: Self.installedKey) as? [String: String] ?? [:]
        var installedChecks: [(UInt32, String, DepotInstall)] = []
        for (key, name) in remembered {
            guard let appID = UInt32(key), tasks[appID] == nil, !queue.contains(appID) else { continue }
            switch statuses[appID] {
            case .installed:
                installedChecks.append((appID, name, install(appID: appID, folder: folder(appID: appID, name: name))))
            case nil, .notInstalled:
                // The whole game, game.json with it.
                log.notice("tvOS cleared \(appID); downloading it again")
                restoring.insert(appID)
                statuses[appID] = .notInstalled
                startDownload(appID: appID, name: name)
            default:
                break // Paused or failed: the person decides.
            }
        }
        let checks = installedChecks
        Task {
            let missing = await Task.detached(priority: .utility) {
                checks.map { ($0.0, $0.1, $0.2.missingFileCount() ?? 0) }
            }.value
            for (appID, name, count) in missing where count > 0 && tasks[appID] == nil {
                log.notice("tvOS cleared \(count) files of \(appID); downloading them again")
                restoring.insert(appID)
                startDownload(appID: appID, name: name)
            }
            checkingCleared = false
        }
    }
    #endif

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
        #if os(tvOS)
        Self.forget(appID: appID)
        restoring.remove(appID)
        #endif
        statuses[appID] = nil
        verifyReports[appID] = nil
        updateIdleTimer()
    }

    // MARK: - Background continuation

    #if os(iOS)
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
    #else
    private func beginBackgroundTask(appID: UInt32, name: String) {}
    private func updateBackgroundTask(_ progress: DownloadProgress) {}
    private func endBackgroundTask(success: Bool) {}
    #endif

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

/// One game's status (`GameLibrary`). Observation is per property: `status` changes with
/// each published progress report, `stage` and `record` only when the game changes state,
/// so lists, shelves and filters that read those don't follow the progress.
@MainActor @Observable
final class StatusCell {
    private(set) var status: GameLibrary.Status
    private(set) var stage: GameLibrary.Stage
    private(set) var record: GameRecord?

    init(_ status: GameLibrary.Status) {
        self.status = status
        stage = .init(status)
        record = Self.record(of: status)
    }

    func update(_ status: GameLibrary.Status) {
        // Assigning an equal value would still notify observers.
        if status != self.status { self.status = status }
        let stage = GameLibrary.Stage(status)
        if stage != self.stage { self.stage = stage }
        let record = Self.record(of: status)
        if record != self.record { self.record = record }
    }

    private static func record(of status: GameLibrary.Status) -> GameRecord? {
        if case let .installed(record) = status { record } else { nil }
    }
}

/// Decides which progress reports are worth showing: at most ten a second, and only when
/// what's on screen would change (a 0.1% step: the bar, the bytes done), so the views
/// following progress don't re-evaluate for nothing.
struct ProgressGate {
    private var lastTime: ContinuousClock.Instant?
    private var lastStep = -1

    static let interval: Duration = .milliseconds(100)

    /// Whether to publish `fraction` now; `force` for a change of phase or the end.
    mutating func admit(_ fraction: Double, force: Bool = false, now: ContinuousClock.Instant = .now) -> Bool {
        let step = Int((fraction * 1000).rounded(.down))
        if !force {
            guard step != lastStep else { return false }
            if let lastTime, now - lastTime < Self.interval { return false }
        }
        lastTime = now
        lastStep = step
        return true
    }
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
