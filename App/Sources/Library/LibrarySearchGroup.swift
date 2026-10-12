#if os(iOS)
import SwiftUI

/// A titled group of search results, with how many there are.
struct LibrarySearchGroup: View {
    let title: String
    let games: [LibraryGame]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title2).bold()
                Text(games.count.formatted()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, ShowcaseMetrics.margin)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            LibraryGrid(games: games)
        }
    }
}
#endif
