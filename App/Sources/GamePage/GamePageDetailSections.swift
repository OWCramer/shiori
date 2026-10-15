// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The game page's second half, about the game's files: its version and engine, and its
/// folder and storage. (On a wide iPad these go to the inspector.)
struct GamePageDetailSections: View {
    let game: LibraryGame
    let record: GameRecord?
    let model: GamePageModel

    var body: some View {
        VersionSection(game: game, model: model)
        if let record {
            FilesSection(game: game, record: record, model: model)
        }
    }
}
#endif
