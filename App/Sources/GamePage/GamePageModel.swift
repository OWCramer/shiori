// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// One game page's own state: the patch files on disk, a patch import under way, and the
/// questions and sheets its sections raise. The game itself lives in `GameLibrary`.
@MainActor @Observable
final class GamePageModel {
    let appID: UInt32
    private(set) var patchFiles: [PatchStore.PatchFile] = []
    /// The game this page shows, kept current by the page (the keyboard's commands use it).
    var game: LibraryGame?
    /// An import under way for this game (here, or dropped on its capsule).
    var patchImport: PatchImports.Progress? { PatchImports.shared.running[appID] }
    /// The outcome of the last import, shown under the patch files.
    var patchMessage: String? { PatchImports.shared.messages[appID] }

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
        if !games.isOnDevice(appID) {
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

    /// Imports a patch picked in Files (`PatchImports` unpacks it off the main thread).
    func importPatch(_ result: Result<URL, Error>, folder: URL) {
        switch result {
        case let .success(url): PatchImports.shared.start(appID: appID, url: url, gameFolder: folder)
        case let .failure(error): PatchImports.shared.fail(appID: appID, "Couldn't import the patch: \(error.localizedDescription)")
        }
    }
}
