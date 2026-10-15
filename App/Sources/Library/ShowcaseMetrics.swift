// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import SwiftUI

/// Design A's ("Showcase") shared measurements, so the library's screens stay uniform.
enum ShowcaseMetrics {
    /// Side margin of the library's pages: compact width, then regular.
    static let margin: CGFloat = 20
    static let wideMargin: CGFloat = 48
    /// Between Home's shelves.
    static let shelfSpacing: CGFloat = 30
    /// Between the items of a shelf or a grid row.
    static let itemSpacing: CGFloat = 14
    static let gridRowSpacing: CGFloat = 22
    /// Smallest capsule in a grid: compact width, then regular.
    static let gridMinimum: CGFloat = 104
    static let wideGridMinimum: CGFloat = 160
    /// A capsule on a shelf: compact width, then regular.
    static let shelfCapsule: CGFloat = 112
    static let wideShelfCapsule: CGFloat = 150
    /// Continue Playing's landscape cards: compact width, then regular.
    static let card: CGFloat = 290
    static let wideCard: CGFloat = 380
    static let capsuleRadius: CGFloat = 14
    static let cardRadius: CGFloat = 18
    /// Apple's minimum tap area.
    static let minimumTap: CGFloat = 44
}
