#if os(iOS)
import SwiftUI

/// A capsule with the game's name and state under it, opening its page.
struct LibraryCell: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        let status = games.status(for: game.appID)
        NavigationLink(value: game) {
            VStack(alignment: .leading, spacing: 6) {
                ShowcaseCapsule(game: game, status: status)
                Text(game.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(libraryStatusLine(for: game, status: status, games: games, history: .shared, engineScans: engineScans))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .contextMenu { LibraryGameMenuItems(game: game) }
        // Drop a patch onto a downloaded game's capsule to import it.
        .modifier(PatchDropTarget(game: game))
        .accessibilityElement(children: .combine)
    }
}
#endif
