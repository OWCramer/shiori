// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The game page's first half, about playing: what stands in the way, the saves, patches
/// and DLC, and how well it plays in Shiori. (On a wide iPad this becomes the main column.)
struct GamePagePlaySections: View {
    let game: LibraryGame
    let record: GameRecord?
    let model: GamePageModel
    @Environment(PatchListStore.self) private var patchList

    var body: some View {
        GamePageNotices(game: game, model: model)
        if let record {
            SavesSection(game: game, record: record)
            PatchesSection(game: game, model: model)
        } else {
            PatchesSection(game: game, model: model, installed: false)
        }
        CompatibilitySection(appID: game.appID, name: game.name, engine: record?.engine?.engine)
            // The game's patch list, read here so a game not yet downloaded shows its section.
            .task(id: game.appID) { await patchList.load(appID: game.appID) }
    }
}
#endif
