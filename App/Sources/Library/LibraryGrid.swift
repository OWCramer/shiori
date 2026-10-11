#if os(iOS)
import SwiftUI

/// An adaptive grid of capsules.
struct LibraryGrid: View {
    let games: [LibraryGame]
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let minimum = sizeClass == .regular ? ShowcaseMetrics.wideGridMinimum : ShowcaseMetrics.gridMinimum
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 16, alignment: .top)],
                  spacing: ShowcaseMetrics.gridRowSpacing) {
            ForEach(games) { LibraryCell(game: $0) }
        }
        .padding(.horizontal, ShowcaseMetrics.margin)
    }
}
#endif
