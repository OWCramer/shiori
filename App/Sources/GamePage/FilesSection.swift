#if os(iOS)
import SwiftUI
import UIKit

/// Files and storage: how much room the game takes, where its folder is, opening it in
/// Files, Artemis's archive browser, verifying against Steam, and deleting it.
struct FilesSection: View {
    let game: LibraryGame
    let record: GameRecord
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games

    private var appID: UInt32 { game.appID }
    private var folder: URL { games.folder(appID: appID, name: game.name) }

    var body: some View {
        GamePageSection(title: "Files & Storage",
                        footer: "base holds what Steam delivered, patch your changes, saves the game's saves.") {
            GamePageValueRow(title: "On this \(UIDevice.current.localizedModel)",
                             value: record.sizeBytes.formatted(.byteCount(style: .file)))
            GamePageValueRow(title: "Downloaded", value: record.installedAt.formatted(date: .abbreviated, time: .omitted),
                             detail: record.branch.map { "Steam version: \(GameText.branch($0, of: game))" })
            GamePageRow {
                VStack(alignment: .leading, spacing: 2) {
                    Button("Open in Files", systemImage: "folder", action: openFolder)
                    Text("On My \(UIDevice.current.localizedModel) › Shiori › Games › \(folder.lastPathComponent)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if record.engine?.engine == "artemis" {
                GamePageRow {
                    Button("Browse Archives", systemImage: "archivebox", action: browseArchives)
                }
            }
            GamePageRow {
                Button("Verify Files", systemImage: "checkmark.shield", action: verify)
                    .disabled(isVerifying)
            }
            if let report = games.verifyReports[appID] {
                GamePageRow {
                    VerifyReportView(report: report, patchCount: model.patchFiles.count)
                }
            }
            GamePageRow {
                Button("Delete Download", systemImage: "trash", role: .destructive, action: delete)
            }
        }
    }

    private var isVerifying: Bool {
        if case .verifying = games.status(for: appID) { true } else { false }
    }

    private func openFolder() { openInFiles(folder) }
    private func browseArchives() { model.browsingArchives = true }
    private func verify() { games.verify(appID: appID) }
    private func delete() { model.confirmingDelete = true }
}
#endif
