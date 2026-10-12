#if os(iOS)
import SwiftUI

/// A downloaded game in Settings › Storage: its colour in the bar, name and size.
struct StorageGameRow: View {
    let record: GameRecord
    let colour: Color

    var body: some View {
        LabeledContent {
            Text(record.sizeBytes.formatted(.byteCount(style: .file)))
        } label: {
            Label {
                Text(record.name).lineLimit(1)
            } icon: {
                Circle()
                    .fill(colour)
                    .frame(width: 10, height: 10)
            }
        }
    }
}
#endif
