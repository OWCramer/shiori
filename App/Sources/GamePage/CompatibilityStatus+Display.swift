// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

extension CompatibilityStore.Status {
    var title: String {
        switch self {
        case .complete: "Complete"
        case .plays: "Plays"
        case .boots: "Boots"
        case .unsupported: "Unsupported"
        }
    }

    var systemImage: String {
        switch self {
        case .complete: "checkmark.seal.fill"
        case .plays: "checkmark.circle.fill"
        case .boots: "circle.lefthalf.filled"
        case .unsupported: "xmark.octagon"
        }
    }

    var colour: Color {
        switch self {
        case .complete, .plays: .green
        case .boots: .yellow
        case .unsupported: .red
        }
    }
}
