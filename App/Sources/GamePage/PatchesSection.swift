#if os(iOS)
import SwiftUI

/// Patches and DLC: the game's Steam DLC and the patch list's patches (install, update,
/// remove, Denpasoft), then what's in its `patch/` folder, Import Patch and Remove All.
struct PatchesSection: View {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games

    /// Whether the patch list or Steam has anything for this game; its row collapses if not.
    @State private var listHasContent = false

    private var folder: URL { games.folder(appID: game.appID, name: game.name) }

    var body: some View {
        GamePageSection(title: "Patches & DLC",
                        footer: "Files in the game's patch folder replace or add to its own files, and are picked up the next time you play. Shiori never runs anything from a patch.") {
            PatchListSection(appID: game.appID, gameFolder: folder, onChange: reloadPatches,
                             onContentChange: { listHasContent = $0 })
                .padding(.vertical, listHasContent ? 12 : 0)
                .containerValue(\.collapsedRow, !listHasContent)
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
    }

    private func reloadPatches() { model.reloadPatches(folder: folder) }
    private func importPatch() { model.importingPatch = true }
    private func removeAll() { model.confirmingRemovePatches = true }
}
#endif
