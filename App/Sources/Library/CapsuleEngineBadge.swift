// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Before download: what the game runs on, from its manifests, green when Shiori plays it.
struct CapsuleEngineBadge: View {
    let appID: UInt32
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        if let scan = engineScans.result(for: appID), scan.error == nil {
            // A beta that plays (WORLD END ECONOMiCA's KiriKiri/Ren'Py originals) counts.
            let plays = Playability(scan.engine, appID: appID) == .playable
            let beta = plays ? nil : scan.playableBranch
            let playable = plays || beta != nil
            let label = beta.map { "\(Playability.badge($0.engine)) (beta)" } ?? Playability.badge(scan.engine, appID: appID)
            Text(label)
                .font(.caption)
                .bold()
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(playable ? AnyShapeStyle(.green.opacity(0.9)) : AnyShapeStyle(.black.opacity(0.65)), in: .capsule)
                .padding(6)
                .accessibilityLabel(playable ? "Playable, \(label)" : label)
        }
    }
}
