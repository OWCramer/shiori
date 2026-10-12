import SwiftUI

/// One row in a game page section: at least a tap target tall, its content leading.
struct GamePageRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: GamePageMetrics.rowHeight, alignment: .leading)
            .padding(.vertical, 6)
    }
}
