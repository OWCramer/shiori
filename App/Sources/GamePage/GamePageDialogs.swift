// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The game page's confirmations: removing every patch, switching Steam version on a
/// downloaded game, and deleting it.
struct GamePageDialogs: ViewModifier {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games
    @Environment(PatchInstaller.self) private var patchInstaller

    private var folder: URL { games.folder(appID: game.appID, name: game.name) }

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .confirmationDialog("Remove all patches?", isPresented: $model.confirmingRemovePatches, titleVisibility: .visible) {
                Button("Remove \(model.patchFiles.count) Patch Files", role: .destructive, action: removePatches)
            } message: {
                Text("Saves are kept.")
            }
            .confirmationDialog("Download the \(GameText.branch(model.pendingBranch ?? "public", of: game)) version?",
                                isPresented: Binding(get: { model.pendingBranch != nil }, set: { if !$0 { model.pendingBranch = nil } }),
                                titleVisibility: .visible) {
                Button("Download Again", action: switchBranch)
            } message: {
                Text("Saves and patches stay.")
            }
            .confirmationDialog("Delete \(game.name)?", isPresented: $model.confirmingDelete, titleVisibility: .visible) {
                Button("Delete Game Files and Saves", role: .destructive, action: delete)
            } message: {
                Text("Its patches and saves are deleted too.")
            }
    }

    private func removePatches() { model.removeAllPatches(folder: folder, installer: patchInstaller) }

    private func switchBranch() {
        if let branch = model.pendingBranch { games.setBranch(branch, for: game.appID, name: game.name) }
        model.pendingBranch = nil
    }

    private func delete() { games.delete(appID: game.appID, name: game.name) }
}
#endif
