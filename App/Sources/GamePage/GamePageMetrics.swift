import SwiftUI

/// The game page's shared measurements.
enum GamePageMetrics {
    /// Side margin of the page's content: compact width, then regular.
    static let margin: CGFloat = 20
    static let wideMargin: CGFloat = 32
    /// Between sections.
    static let sectionSpacing: CGFloat = 28
    static let sectionRadius: CGFloat = 20
    /// A row's least height (Apple's minimum tap area).
    static let rowHeight: CGFloat = 44
    /// How wide the page's content grows before it centres (a wide iPad window).
    static let readableWidth: CGFloat = 720
}
