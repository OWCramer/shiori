// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// A bar of the device's storage as Shiori uses it: a segment per game (the largest in
/// colours of their own, the rest together), against the space left.
struct StorageBar: View {
    /// Games' sizes, largest first.
    let sizes: [UInt64]
    let free: UInt64?

    private static let palette: [Color] = [.pink, .blue, .orange, .green, .purple, .teal]

    /// The colour of the game at this place in the size order.
    static func colour(_ index: Int) -> Color {
        index < palette.count ? palette[index] : .gray
    }

    var body: some View {
        let own = sizes.prefix(Self.palette.count)
        let rest = sizes.dropFirst(Self.palette.count).reduce(0, +)
        let used = sizes.reduce(0, +)
        let whole = Double(max(1, used + (free ?? 0)))
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(Array(own.enumerated()), id: \.offset) { index, size in
                    Rectangle()
                        .fill(Self.colour(index).gradient)
                        .frame(width: max(3, proxy.size.width * Double(size) / whole))
                }
                if rest > 0 {
                    Rectangle()
                        .fill(Color.gray.gradient)
                        .frame(width: max(3, proxy.size.width * Double(rest) / whole))
                }
                Rectangle().fill(.quaternary)
            }
        }
        .frame(height: 14)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}
