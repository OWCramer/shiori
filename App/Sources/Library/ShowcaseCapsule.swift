// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SteamKit
import SwiftUI

/// Design A's capsule: the art with its state drawn on it (content, so no Liquid Glass):
/// an engine badge before download, a tick once downloaded, a queue or pause mark, and
/// progress over a scrim at the bottom.
struct ShowcaseCapsule: View {
    let game: LibraryGame
    let status: GameLibrary.Status

    var body: some View {
        CapsuleArt(game: game)
            .overlay(alignment: .bottom) { CapsuleProgress(status: status) }
            .overlay(alignment: .topLeading) {
                if status == .notInstalled { CapsuleEngineBadge(appID: game.appID) }
            }
            .overlay(alignment: .topTrailing) { CapsuleStateIcon(status: status) }
            .clipShape(.rect(cornerRadius: ShowcaseMetrics.capsuleRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ShowcaseMetrics.capsuleRadius)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
            .background {
                RoundedRectangle(cornerRadius: ShowcaseMetrics.capsuleRadius)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
            }
    }
}
