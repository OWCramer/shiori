import SwiftUI

/// A title and its value, with an optional line under it.
struct GamePageValueRow: View {
    let title: String
    let value: String
    var detail: String?
    var valueStyle: Color?

    var body: some View {
        GamePageRow {
            VStack(alignment: .leading, spacing: 2) {
                LabeledContent(title) {
                    Text(value)
                        .foregroundStyle(valueStyle.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                        .multilineTextAlignment(.trailing)
                }
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
