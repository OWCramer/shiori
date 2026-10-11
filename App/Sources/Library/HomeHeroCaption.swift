#if os(iOS)
import SwiftUI

/// "CONTINUE · Played 2 hours ago · Ren'Py 8 · 2.09 GB" under Home's lead logo.
struct HomeHeroCaption: View {
    let eyebrow: String
    let detail: String

    var body: some View {
        let label = Text(eyebrow.localizedUppercase).bold().tracking(1.5).foregroundStyle(.white)
        Group {
            if detail.isEmpty {
                label
            } else {
                Text("\(label) · \(detail)")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.85))
    }
}
#endif
