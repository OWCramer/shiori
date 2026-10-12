#if os(iOS)
import SwiftUI

/// Above a filtered grid: how many games show and which filters hide the rest, with Clear.
struct LibraryFilterSummary: View {
    @Binding var filters: LibraryFilters
    let shown: Int
    let total: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Showing \(shown) of \(total)")
                    .font(.subheadline)
                    .bold()
                Text(filters.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Clear", action: clear)
                .buttonStyle(.bordered)
                .accessibilityLabel("Clear Filters")
        }
        .padding(.horizontal, ShowcaseMetrics.margin)
        .padding(.vertical, 4)
    }

    private func clear() { withAnimation { filters = LibraryFilters() } }
}
#endif
