#if os(iOS)
import SwiftUI

/// The game page's More menu: everything the page's sections offer, in one place (the
/// Visual Novels list, artwork, Steam version, engine check, Phone Layout, files, patches,
/// delete).
struct GamePageMoreMenu: View {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility

    private var appID: UInt32 { game.appID }

    /// What the menu shows, without download progress.
    private var state: GamePageMenuButton.State {
        let record = games.record(for: appID)
        return GamePageMenuButton.State(
            isVisualNovel: curation.isVisualNovel(game),
            installedEngine: record.map { $0.engine?.engine ?? "" },
            hasPartialDownload: record == nil && games.isOnDevice(appID),
            hasPatches: !model.patchFiles.isEmpty,
            branch: games.branch(for: appID),
            isLoggedOn: steam.isLoggedOn,
            phoneLayout: model.phoneLayout,
            suggestedBranch: BranchHint.find(for: game, games: games, engineScans: engineScans, compatibility: compatibility)?.branch
        )
    }

    var body: some View {
        // Rebuilt only when what the menu shows changes: during a download the status
        // changes with every progress report, which made an open menu blink.
        GamePageMenuButton(state: state) { AnyView(items($0)) }
            .equatable()
    }

    /// Built from the snapshot alone: anything observable read here would tie the open menu
    /// to it again. Live objects are only touched in the actions, when tapped.
    @ViewBuilder private func items(_ state: GamePageMenuButton.State) -> some View {
        Button(state.isVisualNovel ? "Remove from Visual Novels" : "Add to Visual Novels",
               systemImage: state.isVisualNovel ? "eye.slash" : "plus.circle", action: toggleVisualNovel)
        Button("Change Artwork…", systemImage: "photo.on.rectangle", action: changeArtwork)
        if let branches = game.branches, branches.count > 1 {
            Picker(selection: Binding(get: { state.branch }, set: chooseBranch)) {
                ForEach(branches, id: \.name) { branch in
                    VStack {
                        Text(GameText.branch(branch.name, of: game))
                        if branch.name == state.suggestedBranch { Text("Should work") }
                    }
                    .tag(branch.name)
                }
            } label: {
                Label("Steam Version", systemImage: state.suggestedBranch != nil ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.triangle.branch")
            }
            .pickerStyle(.menu)
        }
        if state.installedEngine == nil {
            Button("Check Engine Again", systemImage: "magnifyingglass", action: checkEngine)
                .disabled(!state.isLoggedOn)
        }
        Divider()
        if state.installedEngine == RenPyEngine.id {
            Toggle(isOn: Binding(get: { state.phoneLayout }, set: setPhoneLayout)) {
                Label("Phone Layout", systemImage: "iphone")
            }
        }
        if state.installedEngine != nil {
            if let engine = state.installedEngine, !engine.isEmpty {
                Button("Controls…", systemImage: "hand.tap", action: showControls)
            }
            if state.installedEngine == "artemis" {
                Button("Browse Archives", systemImage: "archivebox", action: browseArchives)
            }
            Button("Verify Files", systemImage: "checkmark.shield", action: verify)
            Button("Import Patch…", systemImage: "square.and.arrow.down", action: importPatch)
            Button("Open Folder in Files", systemImage: "folder", action: openFolder)
            if state.hasPatches {
                Button("Remove All Patches", systemImage: "arrow.uturn.backward", action: removePatches)
            }
            Divider()
            Button("Delete Download", systemImage: "trash", role: .destructive, action: delete)
        } else if state.hasPartialDownload {
            Button("Delete Partial Download", systemImage: "trash", role: .destructive, action: delete)
        }
    }

    private func toggleVisualNovel() { curation.toggle(game) }
    private func changeArtwork() { model.choosingArtwork = true }
    private func checkEngine() { engineScans.scan([appID], force: true) }
    private func setPhoneLayout(_ on: Bool) { model.setPhoneLayout(on) }
    private func browseArchives() { model.browsingArchives = true }
    private func verify() { games.verify(appID: appID) }
    private func importPatch() { model.importingPatch = true }
    private func openFolder() { openInFiles(games.folder(appID: appID, name: game.name)) }
    private func removePatches() { model.confirmingRemovePatches = true }
    private func delete() { model.confirmingDelete = true }
    private func showControls() {
        guard let record = games.record(for: appID), let engine = record.engine?.engine else { return }
        ControlsGuide.shared.show(engine: engine, gameName: game.name)
    }

    private func chooseBranch(_ branch: String) { model.chooseBranch(branch, game: game, games: games) }
}
#endif
