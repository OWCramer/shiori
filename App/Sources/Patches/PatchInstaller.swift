import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Downloads and installs patches from the patch list, one at a time per game, and keeps
/// each game's `patches.json`: which listed patches are installed and the files each wrote,
/// so Remove takes out exactly those and the list can say when a newer version is out.
@MainActor
@Observable
final class PatchInstaller {
    struct InstalledPatch: Codable, Hashable, Sendable {
        var id: String
        var name: String
        var version: String?
        /// The listed files' hashes (or links) when installed; differs when the list has a new version.
        var fingerprint: String
        var installedAt: Date
        /// Paths relative to `patch/` that this patch wrote and no later patch replaced.
        var files: [String]
    }

    enum Phase: Equatable {
        case downloading(written: Int64, total: Int64, part: Int, parts: Int)
        case checking
        case installing(fraction: Double)
        case failed(String)

        var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    /// One patch on its way. Its own observable object, so progress re-evaluates only the
    /// views showing it: `jobs` changes when a job starts or ends, `phase` with progress
    /// (published at most ten times a second, when the bar or bytes would move: downloads
    /// report every network chunk, often 100+ times a second), `isFailure` once.
    @MainActor @Observable
    final class Job {
        let patchID: String
        let name: String
        private(set) var phase: Phase
        private(set) var isFailure = false
        @ObservationIgnored private var gate = ProgressGate()

        init(patchID: String, name: String, phase: Phase) {
            self.patchID = patchID
            self.name = name
            self.phase = phase
        }

        func update(_ new: Phase) {
            switch (phase, new) {
            case let (.downloading(_, _, oldPart, _), .downloading(written, total, part, _)) where oldPart == part:
                // Unknown size: a step per megabyte.
                let fraction = total > 0 ? Double(written) / Double(total) : Double(written) / 1_000_000_000
                guard gate.admit(fraction, force: total > 0 && written >= total) else { return }
            case let (.installing, .installing(fraction)):
                guard gate.admit(fraction, force: fraction >= 1) else { return }
            default:
                gate = ProgressGate()
            }
            if new != phase { phase = new }
            if new.isFailure != isFailure { isFailure = new.isFailure }
        }
    }

    /// Jobs by app id.
    private(set) var jobs: [UInt32: Job] = [:]
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    /// Installed patches by app id, read from each game's patches.json.
    private(set) var installed: [UInt32: [InstalledPatch]] = [:]
    /// Patches chosen on the page of a game that isn't downloaded yet, by app id, in the order
    /// chosen: installed one after another when the game's download finishes.
    private(set) var queued: [UInt32: [PatchListStore.Patch]] = [:]

    /// Whether the account's Steam store preferences allow adult content (18+ patches). Set by the app.
    @ObservationIgnored var allowsAdultContent: () -> Bool = { false }

    nonisolated private static let queueFile = URL.shioriSupport.appendingPathComponent("patch-queue.json")

    init() {
        if let data = try? Data(contentsOf: Self.queueFile),
           let saved = try? JSONDecoder().decode([String: [PatchListStore.Patch]].self, from: data) {
            queued = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UInt32(key).map { ($0, value) } })
        }
    }

    nonisolated private static let downloads = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("patch-downloads", isDirectory: true)

    nonisolated static func recordFile(_ gameFolder: URL) -> URL { gameFolder.appendingPathComponent("patches.json") }

    func load(appID: UInt32, gameFolder: URL) {
        installed[appID] = Self.read(gameFolder)
    }

    nonisolated static func read(_ gameFolder: URL) -> [InstalledPatch] {
        guard let data = try? Data(contentsOf: recordFile(gameFolder)) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([InstalledPatch].self, from: data)) ?? []
    }

    nonisolated static func write(_ records: [InstalledPatch], to gameFolder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if records.isEmpty {
            try? FileManager.default.removeItem(at: recordFile(gameFolder))
        } else {
            try encoder.encode(records).write(to: recordFile(gameFolder), options: .atomic)
        }
    }

    func installedPatch(_ id: String, appID: UInt32) -> InstalledPatch? {
        installed[appID]?.first { $0.id == id }
    }

    /// Downloads and installs a listed patch. An 18+ patch only while the account allows adult content.
    func install(_ patch: PatchListStore.Patch, appID: UInt32, gameFolder: URL) {
        guard tasks[appID] == nil, !patch.adult || allowsAdultContent() else { return }
        jobs[appID] = Job(patchID: patch.id, name: patch.name,
                          phase: .downloading(written: 0, total: patch.totalSize ?? 0, part: 1, parts: patch.files.count))
        #if canImport(UIKit) && !os(tvOS)
        let background = UIApplication.shared.beginBackgroundTask(withName: "Patch download")
        #endif
        tasks[appID] = Task { [weak self] in
            defer {
                #if canImport(UIKit) && !os(tvOS)
                UIApplication.shared.endBackgroundTask(background)
                #endif
            }
            var succeeded = false
            do {
                try await self?.run(patch, appID: appID, gameFolder: gameFolder)
                self?.jobs[appID] = nil
                succeeded = true
            } catch is CancellationError {
                self?.jobs[appID] = nil
            } catch {
                self?.jobs[appID]?.update(.failed(error.localizedDescription))
            }
            self?.tasks[appID] = nil
            self?.load(appID: appID, gameFolder: gameFolder)
            // The next patch chosen before the download; after a failure or Cancel the rest
            // wait for the player, as Install buttons.
            if succeeded { self?.installQueued(appID: appID, gameFolder: gameFolder) } else { self?.clearQueue(appID: appID) }
        }
    }

    // MARK: - Chosen before the download

    func isQueued(_ patchID: String, appID: UInt32) -> Bool {
        queued[appID]?.contains { $0.id == patchID } ?? false
    }

    /// Installs `patch` once the game finishes downloading.
    func enqueue(_ patch: PatchListStore.Patch, appID: UInt32) {
        guard !isQueued(patch.id, appID: appID) else { return }
        queued[appID, default: []].append(patch)
        saveQueue()
    }

    func dequeue(_ patchID: String, appID: UInt32) {
        queued[appID]?.removeAll { $0.id == patchID }
        if queued[appID]?.isEmpty == true { queued[appID] = nil }
        saveQueue()
    }

    /// Starts the first patch waiting for this game; each one that installs starts the next.
    /// Called when the game's download finishes.
    func installQueued(appID: UInt32, gameFolder: URL) {
        guard tasks[appID] == nil, let next = queued[appID]?.first else { return }
        dequeue(next.id, appID: appID)
        load(appID: appID, gameFolder: gameFolder)
        // Already installed, or 18+ while the account's preferences no longer allow it: skipped.
        if installedPatch(next.id, appID: appID)?.fingerprint == next.fingerprint || (next.adult && !allowsAdultContent()) {
            return installQueued(appID: appID, gameFolder: gameFolder)
        }
        install(next, appID: appID, gameFolder: gameFolder)
    }

    private func clearQueue(appID: UInt32) {
        guard queued[appID] != nil else { return }
        queued[appID] = nil
        saveQueue()
    }

    private func saveQueue() {
        let saved = Dictionary(uniqueKeysWithValues: queued.map { (String($0.key), $0.value) })
        if saved.isEmpty {
            try? FileManager.default.removeItem(at: Self.queueFile)
        } else if let data = try? JSONEncoder().encode(saved) {
            try? FileManager.default.createDirectory(at: Self.queueFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.queueFile, options: .atomic)
        }
    }

    #if DEBUG
    /// A patch download for show (`-ShioriFakePatch`): progress reported as URLSession hands
    /// over data (a 64 KB chunk every 10 ms, a 300 MB file), with nothing fetched or written.
    func startFakeJob(appID: UInt32, patchID: String) {
        guard tasks[appID] == nil else { return }
        let total: Int64 = 300_000_000
        jobs[appID] = Job(patchID: patchID, name: "Fake patch", phase: .downloading(written: 0, total: total, part: 1, parts: 1))
        tasks[appID] = Task { [weak self] in
            var written: Int64 = 0
            while !Task.isCancelled, written < total {
                try? await Task.sleep(for: .milliseconds(10))
                written = min(total, written + 65_536)
                self?.jobs[appID]?.update(.downloading(written: written, total: total, part: 1, parts: 1))
            }
            self?.jobs[appID] = nil
            self?.tasks[appID] = nil
        }
    }
    #endif

    func cancel(appID: UInt32) {
        tasks[appID]?.cancel()
    }

    func dismissFailure(appID: UInt32) {
        if jobs[appID]?.isFailure == true { jobs[appID] = nil }
    }

    /// Deletes the files this patch wrote (those no later patch replaced) and its record.
    func remove(_ id: String, appID: UInt32, gameFolder: URL) throws {
        var records = Self.read(gameFolder)
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let patch = PatchStore.patchFolder(gameFolder)
        for path in records[index].files {
            try? FileManager.default.removeItem(at: patch.appendingPathComponent(path))
        }
        Self.pruneEmptyFolders(patch)
        records.remove(at: index)
        try Self.write(records, to: gameFolder)
        load(appID: appID, gameFolder: gameFolder)
    }

    /// Forgets every record (Remove All empties patch/ itself).
    func forgetAll(appID: UInt32, gameFolder: URL) {
        try? Self.write([], to: gameFolder)
        installed[appID] = []
    }

    // MARK: - The work

    private enum Failure: LocalizedError {
        case hashMismatch(String)
        case windowsInstaller

        var errorDescription: String? {
            switch self {
            case let .hashMismatch(name): "\(name) didn't match the patch list's checksum, so it wasn't installed."
            case .windowsInstaller: "This patch is a Windows installer, which can't run here."
            }
        }
    }

    private func run(_ patch: PatchListStore.Patch, appID: UInt32, gameFolder: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
        var downloaded: [(url: URL, name: String)] = []
        for (n, file) in patch.files.enumerated() {
            let partial = Self.downloads.appendingPathComponent("\(appID)-\(patch.id)-\(n).part")
            let result = try await downloadFile(file, to: partial, appID: appID, part: n + 1, parts: patch.files.count)
            try Task.checkCancellation()
            jobs[appID]?.update(.checking)
            if let expected = file.sha256, expected != result.sha256 {
                try? fm.removeItem(at: partial)
                throw Failure.hashMismatch(result.name)
            }
            downloaded.append((result.file, file.name ?? result.name))
        }

        jobs[appID]?.update(.installing(fraction: 0))
        let install = patch.install
        let progress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor [weak self] in self?.jobs[appID]?.update(.installing(fraction: fraction)) }
        }
        let parts = downloaded
        let written = try await Task.detached(priority: .userInitiated) {
            try Self.unpackAndPlace(parts, gameFolder: gameFolder, into: install?.into, strip: install?.strip, progress: progress)
        }.value

        var records = Self.read(gameFolder)
        let mine = Set(written)
        // A file now belongs to this patch; earlier patches no longer remove it.
        for i in records.indices { records[i].files.removeAll { mine.contains($0) } }
        records.removeAll { $0.id == patch.id }
        records.append(InstalledPatch(id: patch.id, name: patch.name, version: patch.version,
                                      fingerprint: patch.fingerprint, installedAt: Date(), files: written.sorted()))
        try Self.write(records, to: gameFolder)
        for item in downloaded { try? fm.removeItem(at: item.url) }
    }

    private func downloadFile(_ file: PatchListStore.Patch.File, to partial: URL, appID: UInt32, part: Int, parts: Int)
        async throws -> PatchDownloader.Result {
        let sources = [(file.host, file.url)] + (file.mirrors ?? []).map { ($0.host, $0.url) }
        var lastError: Error = PatchDownloader.Failure.unsupportedLink
        for (host, link) in sources where ["direct", "gdrive", "mega", "wetransfer"].contains(host) {
            guard let url = URL(string: link) else { continue }
            let downloader = PatchDownloader(destination: partial) { written, total in
                Task { @MainActor [weak self] in
                    self?.jobs[appID]?.update(.downloading(written: written, total: total > 0 ? total : (file.size ?? 0), part: part, parts: parts))
                }
            }
            do {
                return try await downloader.download(host: host, url: url)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
                // A mirror is a different file; don't resume into it.
                try? FileManager.default.removeItem(at: partial)
            }
        }
        throw lastError
    }

    nonisolated private static func unpackAndPlace(_ files: [(url: URL, name: String)], gameFolder: URL, into: String?, strip: String?,
                                                   progress: @escaping @Sendable (Double) -> Void) throws -> [String] {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("patch-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        for (index, file) in files.enumerated() {
            let ext = (file.name as NSString).pathExtension.lowercased()
            if ArchiveExtractor.archiveExtensions.contains(ext) {
                let paths = try ArchiveExtractor.extract(file.url, to: staging) { written, total, _ in
                    guard total > 0 else { return }
                    progress((Double(index) + Double(written) / Double(total)) / Double(files.count))
                }
                let exes = paths.filter { $0.lowercased().hasSuffix(".exe") }
                if !exes.isEmpty, exes.count * 2 >= paths.count { throw Failure.windowsInstaller }
            } else if ext == "exe" {
                throw Failure.windowsInstaller
            } else {
                // A loose file (an .rpa, an .xp3): placed as Import Patch places one.
                try fm.createDirectory(at: staging.appendingPathComponent("game"), withIntermediateDirectories: true)
                let base = gameFolder.appendingPathComponent("base", isDirectory: true)
                let renpy = fm.fileExists(atPath: base.appendingPathComponent("game").path)
                let target = renpy ? staging.appendingPathComponent("game").appendingPathComponent(file.name)
                                   : staging.appendingPathComponent(file.name)
                try fm.copyItem(at: file.url, to: target)
            }
        }
        progress(1)
        return try PatchStore.place(staging, gameFolder: gameFolder, into: into, strip: strip)
    }

    nonisolated private static func pruneEmptyFolders(_ folder: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            pruneEmptyFolders(item)
            if (try? fm.contentsOfDirectory(atPath: item.path))?.isEmpty == true, item.lastPathComponent != "game" {
                try? fm.removeItem(at: item)
            }
        }
    }
}
