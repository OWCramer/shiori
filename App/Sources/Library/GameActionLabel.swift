// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A button label with its title, or its icon alone where room is short (VoiceOver and
/// Voice Control still get the title).
struct GameActionLabel: View {
    let title: String
    let systemImage: String
    var iconOnly = false

    var body: some View {
        if iconOnly {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 22, minHeight: 22)
        } else {
            Label(title, systemImage: systemImage)
                .fixedSize()
        }
    }
}
