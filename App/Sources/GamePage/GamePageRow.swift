// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// One row in a game page section: at least a tap target tall, its content leading.
struct GamePageRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: GamePageMetrics.rowHeight, alignment: .leading)
            .padding(.vertical, 6)
    }
}
