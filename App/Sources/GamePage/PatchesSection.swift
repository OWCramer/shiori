// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Patches and DLC: the game's Steam DLC and the patch list's patches (install, update,
/// remove), then what's in its `patch/` folder, Import Patch and Remove All.
/// Before the game is downloaded, only the list, when it has patches for the game: they can
/// be queued to install with the download.
struct PatchesSection: View {
    let game: LibraryGame
    let model: GamePageModel
    /// Whether the game is downloaded and installed; the patch folder exists only then.
    var installed = true
    @Environment(GameLibrary.self) private var games
    @Environment(PatchListStore.self) private var patchList
    @Environment(SteamModel.self) private var steam

    /// Whether the patch list or Steam has anything for this game; its row collapses if not.
    @State private var listHasContent = false

    private var folder: URL { games.folder(appID: game.appID, name: game.name) }

    var body: some View {
        if installed {
            GamePageSection(title: "Patches & DLC",
                            footer: "Files in the patch folder replace or add to the game's files.") {
                list
                installedRows
            }
        } else if !patchList.patches(for: game.appID, allowingAdult: steam.allowsAdultContent).isEmpty {
            // The game's list is read by the page (GamePagePlaySections).
            GamePageSection(title: "Patches & DLC") { list }
        }
    }

    private var list: some View {
        PatchListSection(appID: game.appID, gameFolder: folder, onChange: reloadPatches,
                         onContentChange: { listHasContent = $0 })
            .padding(.vertical, listHasContent ? 12 : 0)
            .containerValue(\.collapsedRow, !listHasContent)
    }

    @ViewBuilder private var installedRows: some View {
        PatchFilesRow(files: model.patchFiles)
        if let progress = model.patchImport {
            GamePageRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Importing \(progress.name)…").font(.subheadline)
                    ProgressView(value: progress.fraction)
                    Text(progress.file.isEmpty ? "Reading the archive" : (progress.file as NSString).lastPathComponent)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } else if let message = model.patchMessage {
            GamePageRow {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        GamePageRow {
            Button("Import Patch…", systemImage: "square.and.arrow.down", action: importPatch)
                .disabled(model.patchImport != nil)
        }
        if !model.patchFiles.isEmpty {
            GamePageRow {
                Button("Remove All Patches", systemImage: "arrow.uturn.backward", role: .destructive, action: removeAll)
            }
        }
    }

    private func reloadPatches() { model.reloadPatches(folder: folder) }
    private func importPatch() { model.importingPatch = true }
    private func removeAll() { model.confirmingRemovePatches = true }
}
#endif
