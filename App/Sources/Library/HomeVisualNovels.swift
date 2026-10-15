// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// The start of the Visual Novels tab on Home, with Show All.
struct HomeVisualNovels: View {
    let games: [LibraryGame]
    @Environment(ShellModel.self) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let limit = sizeClass == .regular ? 24 : 18
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionTitle(title: "Your Visual Novels", destination: .visualNovels)
            LibraryGrid(games: Array(games.prefix(limit)))
            if games.count > limit {
                Button("Show All \(games.count)", action: showAll)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func showAll() { shell.select(.visualNovels) }
}
#endif
