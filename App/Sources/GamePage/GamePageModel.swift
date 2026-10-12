import Foundation
import Observation

/// One game page's own state: the patch files on disk, a patch import under way, and the
/// questions and sheets its sections raise. The game itself lives in `GameLibrary`.
@MainActor @Observable
final class GamePageModel {
    /// A patch import under way: its file name, how far it has got, the entry being unpacked.
    struct PatchImport: Equatable {
        var name: String
        var fraction: Double
        var file: String
    }

    let appID: UInt32
    private(set) var patchFiles: [PatchStore.PatchFile] = []
    private(set) var patchImport: PatchImport?
    /// The outcome of the last import, shown under the patch files.
    private(set) var patchMessage: String?

    var importingPatch = false
    var confirmingRemovePatches = false
    var confirmingDelete = false
    /// A Steam version picked for a game that's already (partly) downloaded, awaiting confirmation.
    var pendingBranch: String?
    var choosingArtwork = false
    var browsingArchives = false
    /// Ren'Py's Phone Layout for this game (synced through `SyncedPreferences`).
    private(set) var phoneLayout: Bool

    init(appID: UInt32) {
        self.appID = appID
        phoneLayout = RenPyEngine.usesPhoneLayout(appID: appID)
    }

    func setPhoneLayout(_ on: Bool) {
        phoneLayout = on
        RenPyEngine.setPhoneLayout(on, appID: appID)
    }

    /// Switches the Steam version: at once before anything is downloaded, else after asking
    /// (the game's files are downloaded again).
    func chooseBranch(_ branch: String, game: LibraryGame, games: GameLibrary) {
        guard branch != games.branch(for: appID) else { return }
        if games.status(for: appID) == .notInstalled {
            games.setBranch(branch, for: appID, name: game.name)
        } else {
            pendingBranch = branch
        }
    }

    func reloadPatches(folder: URL) {
        patchFiles = PatchStore.list(gameFolder: folder)
    }

    func removeAllPatches(folder: URL, installer: PatchInstaller) {
        try? PatchStore.removeAll(gameFolder: folder)
        installer.forgetAll(appID: appID, gameFolder: folder)
        reloadPatches(folder: folder)
    }

    /// Unpacks a picked patch off the main thread (a multi-gigabyte zip takes a while),
    /// reporting how far it has got.
    func importPatch(_ result: Result<URL, Error>, folder: URL) {
        let url: URL
        do { url = try result.get() } catch {
            patchMessage = "Couldn't import the patch: \(error.localizedDescription)"
            return
        }
        importPatch(at: url, folder: folder)
    }

    func importPatch(at url: URL, folder: URL) {
        let name = url.lastPathComponent
        patchImport = PatchImport(name: name, fraction: 0, file: "")
        Task.detached(priority: .userInitiated) { [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var shown = -1.0
            let outcome: Result<Int, Error> = Result {
                try PatchStore.importItem(at: url, gameFolder: folder) { written, total, file in
                    let fraction = total > 0 ? Double(written) / Double(total) : 0
                    // A few hundred updates at most, not one per megabyte.
                    guard fraction - shown >= 0.002 || fraction >= 1 else { return }
                    shown = fraction
                    Task { @MainActor in self?.patchImport = PatchImport(name: name, fraction: fraction, file: file) }
                }
            }
            await self?.finishImport(outcome, name: name, folder: folder)
        }
    }

    private func finishImport(_ outcome: Result<Int, Error>, name: String, folder: URL) {
        patchImport = nil
        switch outcome {
        case let .success(count):
            patchMessage = "Imported \(count) file\(count == 1 ? "" : "s") from \(name)."
        case let .failure(error):
            patchMessage = "Couldn't import the patch: \(error.localizedDescription)"
        }
        reloadPatches(folder: folder)
    }
}
