#if os(iOS)
import SwiftUI

/// A collection in a grid: its games stacked, its name, and where its downloads stand,
/// opening the collection's page.
struct CollectionCell: View {
    let collection: LibraryCollection
    /// The collection's games in this grid, front one first.
    let games: [LibraryGame]
    @Environment(GameLibrary.self) private var library
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        let summary = CollectionSummary(games: games, library: library, engineScans: engineScans)
        NavigationLink(value: LibraryRoute.collection(collection.id)) {
            VStack(alignment: .leading, spacing: 6) {
                CollectionStack(games: games)
                Text(collection.name)
                    .font(.footnote)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(summary.line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.lift)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(collection.name), collection")
        .accessibilityValue(summary.line)
    }
}
#endif
