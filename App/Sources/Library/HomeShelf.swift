#if os(iOS)
import SwiftUI

/// A titled, horizontally scrolling row of games on Home.
struct HomeShelf<Content: View>: View {
    var title: String
    var destination: ShellTab?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionTitle(title: title, destination: destination)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: ShowcaseMetrics.itemSpacing) { content }
                    .padding(.horizontal, ShowcaseMetrics.margin)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}
#endif
