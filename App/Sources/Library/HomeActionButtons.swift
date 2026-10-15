// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// One arrangement of Home's action row. `labels`: how many of Play and Details keep
/// their words (2, 1 or 0).
struct HomeActionButtons: View {
    let game: LibraryGame
    var showsSync: Bool
    var labels: Int

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PrimaryGameButton(game: game, compact: labels < 1)
                GameLink(game: game) {
                    GameActionLabel(title: "Details", systemImage: "info.circle", iconOnly: labels < 2)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(labels < 2 ? .circle : .capsule)
                if showsSync { SyncSavesButton(appID: game.appID) }
                Menu {
                    LibraryGameMenuItems(game: game)
                } label: {
                    GameActionLabel(title: "More", systemImage: "ellipsis", iconOnly: true)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
            .fixedSize()
        }
    }
}
#endif
