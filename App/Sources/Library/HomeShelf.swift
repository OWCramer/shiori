// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
