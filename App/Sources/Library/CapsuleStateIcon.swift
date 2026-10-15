// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// The corner mark on a capsule: downloaded, queued, working, paused or failed.
struct CapsuleStateIcon: View {
    let status: GameLibrary.Status

    var body: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.title3)
                .padding(6)
                .accessibilityLabel("Downloaded")
        case .queued:
            mark("clock.fill", label: "Queued", tint: .black.opacity(0.65))
        case .preparing, .verifying:
            mark("ellipsis", label: "Working", tint: .black.opacity(0.65))
        case .paused:
            mark("pause.fill", label: "Download paused", tint: .black.opacity(0.65))
        case .failed:
            mark("exclamationmark", label: "Download failed", tint: .red)
        case .downloading, .notInstalled:
            EmptyView()
        }
    }

    private func mark(_ symbol: String, label: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.callout)
            .bold()
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(tint, in: .circle)
            .padding(6)
            .accessibilityLabel(label)
    }
}
