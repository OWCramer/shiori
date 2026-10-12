#if os(iOS)
import SwiftUI

/// Lets a patch (zip, 7z, rar or folder) be dropped onto a downloaded game, in the library
/// or on its page, and imports it after asking. The view lights up while a patch is over it.
struct PatchDropTarget: ViewModifier {
    let game: LibraryGame
    var cornerRadius: CGFloat = ShowcaseMetrics.capsuleRadius
    @Environment(GameLibrary.self) private var games
    @State private var targeted = false
    @State private var pending: DroppedPatch?
    @State private var asking = false

    private var isInstalled: Bool {
        games.stage(for: game.appID) == .installed
    }

    func body(content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.tint, lineWidth: 3)
                        .background(.tint.opacity(0.15), in: .rect(cornerRadius: cornerRadius))
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: DroppedPatch.self) { items, _ in
                guard isInstalled, let item = items.first else { return false }
                pending = item
                asking = true
                return true
            } isTargeted: { over in
                targeted = over && isInstalled
            }
            .confirmationDialog("Import \(pending?.url.lastPathComponent ?? "the patch") into \(game.name)?",
                                isPresented: $asking,
                                titleVisibility: .visible) {
                Button("Import Patch", action: importPending)
                Button("Cancel", role: .cancel, action: discard)
            } message: {
                Text("Its files go into the game's patch folder.")
            }
    }

    private func importPending() {
        guard let pending else { return }
        PatchImports.shared.start(appID: game.appID, url: pending.url,
                                  gameFolder: games.folder(appID: game.appID, name: game.name), ownsFile: true)
        self.pending = nil
    }

    /// Cancelled: the copy of the dropped file goes. (Dismissed another way, it stays in tmp/,
    /// which iOS clears.)
    private func discard() {
        if let pending { try? FileManager.default.removeItem(at: pending.url.deletingLastPathComponent()) }
        pending = nil
    }
}
#endif
