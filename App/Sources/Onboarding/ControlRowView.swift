#if os(iOS)
import SwiftUI

/// A line of the controls guide: the symbol, the input in bold, what it does beneath.
struct ControlRowView: View {
    let row: ControlRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: row.systemImage)
                .font(.title3)
                .foregroundStyle(.pink)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.input)
                    .font(.body.weight(.semibold))
                Text(row.action)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
