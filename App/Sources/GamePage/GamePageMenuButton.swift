// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The More menu's circular glass button. Equatable on what its items show, so a game
/// downloading (a new status with every progress report) doesn't rebuild it while open.
struct GamePageMenuButton: View, Equatable {
    struct State: Equatable, Sendable {
        var isVisualNovel: Bool
        var installedEngine: String?
        var hasPartialDownload: Bool
        var hasPatches: Bool
        var branch: String
        var isLoggedOn: Bool
        var phoneLayout: Bool
        /// Another version that should play (`BranchHint`): marked in the menu.
        var suggestedBranch: String?
    }

    let state: State
    let items: (State) -> AnyView

    nonisolated static func == (a: GamePageMenuButton, b: GamePageMenuButton) -> Bool { a.state == b.state }

    var body: some View {
        Menu {
            items(state)
        } label: {
            GameActionLabel(title: "More", systemImage: "ellipsis", iconOnly: true)
                // Another Steam version may play: the menu's Steam Version entry says which.
                .overlay(alignment: .topTrailing) {
                    if state.suggestedBranch != nil {
                        Circle().fill(.orange).frame(width: 9, height: 9).offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
}
#endif
