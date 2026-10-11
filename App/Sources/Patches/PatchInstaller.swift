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
    }

    struct Job: Equatable {
        var patchID: String
        var name: String
        var phase: Phase
    }

    /// Jobs by app id.
    private(set) var jobs: [UInt32: Job] = [:]
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    /// Installed patches by app id, read from each game's patches.json.
    private(set) var installed: [UInt32: [InstalledPatch]] = [:]

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

    /// `chosenFile` names which of a product's files to install, when a shop account has several.
    func install(_ patch: PatchListStore.Patch, appID: UInt32, gameFolder: URL, chosenFile: String? = nil) {
        guard tasks[appID] == nil else { return }
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
            do {
                try await self?.run(patch, appID: appID, gameFolder: gameFolder, chosenFile: chosenFile)
                self?.jobs[appID] = nil
            } catch is CancellationError {
                self?.jobs[appID] = nil
            } catch {
                self?.jobs[appID]?.phase = .failed(error.localizedDescription)
            }
            self?.tasks[appID] = nil
            self?.load(appID: appID, gameFolder: gameFolder)
        }
    }

    func cancel(appID: UInt32) {
        tasks[appID]?.cancel()
    }

    func dismissFailure(appID: UInt32) {
        if case .failed = jobs[appID]?.phase { jobs[appID] = nil }
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
            case let .hashMismatch(name): "\(name) didn't match the patch list's checksum, so it wasn't installed. The file may have changed since it was listed."
            case .windowsInstaller: "This patch is a Windows installer program, which can't run here. Shiori can only install patches that are plain game files."
            }
        }
    }

    private func run(_ patch: PatchListStore.Patch, appID: UInt32, gameFolder: URL, chosenFile: String?) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: Self.downloads, withIntermediateDirectories: true)
        var downloaded: [(url: URL, name: String)] = []
        for (n, file) in patch.files.enumerated() {
            let partial = Self.downloads.appendingPathComponent("\(appID)-\(patch.id)-\(n).part")
            let result = try await downloadFile(file, to: partial, appID: appID, part: n + 1, parts: patch.files.count, chosenFile: chosenFile)
            try Task.checkCancellation()
            jobs[appID]?.phase = .checking
            if let expected = file.sha256, expected != result.sha256 {
                try? fm.removeItem(at: partial)
                throw Failure.hashMismatch(result.name)
            }
            downloaded.append((result.file, file.name ?? result.name))
        }

        jobs[appID]?.phase = .installing(fraction: 0)
        let install = patch.install
        let progress: @Sendable (Double) -> Void = { fraction in
            Task { @MainActor [weak self] in self?.jobs[appID]?.phase = .installing(fraction: fraction) }
        }
        let written = try await Task.detached(priority: .userInitiated) {
            try Self.unpackAndPlace(downloaded, gameFolder: gameFolder, into: install?.into, strip: install?.strip, progress: progress)
        }.value

        var records = Self.read(gameFolder)
        let mine = Set(written)
        // A file now belongs to this patch; earlier patches no longer remove it.
        for i in records.indices { records[i].files.removeAll { mine.contains($0) } }
        records.removeAll { $0.id == patch.id }
        records.append(InstalledPatch(id: patch.id, name: patch.name, version: chosenFile ?? patch.version,
                                      fingerprint: patch.fingerprint, installedAt: Date(), files: written.sorted()))
        try Self.write(records, to: gameFolder)
        for item in downloaded { try? fm.removeItem(at: item.url) }
    }

    private func downloadFile(_ file: PatchListStore.Patch.File, to partial: URL, appID: UInt32, part: Int, parts: Int,
                              chosenFile: String? = nil) async throws -> PatchDownloader.Result {
        #if os(iOS)
        // A Denpasoft product: downloaded through the player's signed-in Denpasoft session.
        if file.host == "store", file.url.contains("denpasoft.com") {
            let account = DenpasoftAccount.shared
            await account.refresh()
            let items = account.downloads(forProductURL: file.url)
            guard let item = items.first(where: { $0.fileName == chosenFile }) ?? items.first else {
                throw DenpasoftAccount.Failure.notInAccount
            }
            let saved = try await account.fetch(item, to: partial) { [weak self] written, total in
                self?.jobs[appID]?.phase = .downloading(written: written, total: total, part: part, parts: parts)
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: saved.path)[.size]) as? Int64) ?? 0
            let hash = try await Task.detached { try PatchDownloader.sha256(of: saved) }.value
            return PatchDownloader.Result(file: saved, name: saved.lastPathComponent, size: size, sha256: hash)
        }
        #endif
        let sources = [(file.host, file.url)] + (file.mirrors ?? []).map { ($0.host, $0.url) }
        var lastError: Error = PatchDownloader.Failure.unsupportedLink
        for (host, link) in sources where ["direct", "gdrive", "mega", "wetransfer"].contains(host) {
            guard let url = URL(string: link) else { continue }
            let downloader = PatchDownloader(destination: partial) { written, total in
                Task { @MainActor [weak self] in
                    self?.jobs[appID]?.phase = .downloading(written: written, total: total > 0 ? total : (file.size ?? 0), part: part, parts: parts)
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
