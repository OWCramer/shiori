// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Something the player should know before playing, on a plain surface tinted by its kind:
/// why a game won't play, which engine it is, another version that plays.
struct GamePageCallout<Actions: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    var message: String?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.12), in: .rect(cornerRadius: GamePageMetrics.sectionRadius))
    }
}

extension GamePageCallout where Actions == EmptyView {
    init(title: String, systemImage: String, tint: Color = .secondary, message: String? = nil) {
        self.init(title: title, systemImage: systemImage, tint: tint, message: message) { EmptyView() }
    }
}
