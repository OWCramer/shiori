import SwiftUI

/// A titled group on the game page: a heading, rows on a plain grouped surface (content,
/// so no Liquid Glass), and an optional note under it, like an inset grouped list.
struct GamePageSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3)
                .bold()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows) { row in
                        row
                        if row.id != rows.last?.id {
                            Rectangle()
                                .fill(.white.opacity(0.14))
                                .frame(height: 0.5)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(.fill.quaternary, in: .rect(cornerRadius: GamePageMetrics.sectionRadius))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}
