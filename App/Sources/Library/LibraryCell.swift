// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A capsule with the game's name and state under it, opening its page.
struct LibraryCell: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        let _ = RenderProbe.hit("LibraryCell")
        let status = games.status(for: game.appID)
        GameLink(game: game) {
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
        // iPad: drag onto a collection in the sidebar to add it.
        .modifier(GameDragSource(appID: game.appID))
        // Drop a patch onto a downloaded game's capsule to import it.
        .modifier(PatchDropTarget(game: game))
        .accessibilityElement(children: .combine)
    }
}
#endif
