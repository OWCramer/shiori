// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SteamKit
import SwiftUI

/// Download or verify progress at the foot of a capsule, over a dark scrim.
struct CapsuleProgress: View {
    let status: GameLibrary.Status

    private var fraction: Double? {
        switch status {
        case let .downloading(progress): progress.fraction
        case let .paused(progress?): progress.fraction
        case let .verifying(progress): progress.fraction
        default: nil
        }
    }

    var body: some View {
        let _ = RenderProbe.hit("CapsuleProgress")
        if let fraction {
            GlassProgressBar(fraction: fraction, tint: .white)
                .padding(10)
                .padding(.top, 24)
                .background {
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                }
        }
    }
}
