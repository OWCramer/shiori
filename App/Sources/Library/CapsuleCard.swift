// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SteamKit
import SwiftUI

/// A portrait capsule with the game's download state over it.
struct CapsuleCard: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsuleArt(game: game)
                .overlay(alignment: .bottom) { statusOverlay }
                .overlay(alignment: .topLeading) { engineBadge }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(game.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Before download: what the game runs on, from its manifests. Green when playable.
    @ViewBuilder private var engineBadge: some View {
        if status == .notInstalled, let scan = engineScans.result(for: game.appID), scan.error == nil {
            // A beta that plays (WORLD END ECONOMiCA's KiriKiri/Ren'Py originals) counts.
            let beta = Playability(scan.engine, appID: game.appID) == .playable ? nil : scan.playableBranch
            let playable = Playability(scan.engine, appID: game.appID) == .playable || beta != nil
            let label = beta.map { "\(Playability.badge($0.engine)) (beta)" } ?? Playability.badge(scan.engine, appID: game.appID)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playable ? Color.green.opacity(0.85) : Color.black.opacity(0.6), in: .capsule)
                .padding(6)
                .accessibilityLabel(playable ? "Playable, \(label)" : label)
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch status {
        case .installed:
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .padding(6)
                    .accessibilityLabel("Downloaded")
            }
        case let .downloading(progress):
            ProgressView(value: progress.fraction)
                .tint(.white)
                .padding(8)
                .background(.black.opacity(0.45))
        case .preparing, .queued, .verifying:
            HStack {
                Spacer()
                Image(systemName: status == .queued ? "clock.fill" : "ellipsis.circle.fill")
                    .foregroundStyle(.white).font(.title3).padding(6)
            }
        case .paused:
            HStack {
                Spacer()
                Image(systemName: "pause.circle.fill").foregroundStyle(.white).font(.title3).padding(6)
                    .accessibilityLabel("Download paused")
            }
        case .failed:
            HStack {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.title3).padding(6)
            }
        case .notInstalled:
            EmptyView()
        }
    }
}
