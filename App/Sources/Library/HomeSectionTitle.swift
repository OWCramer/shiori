// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A Home shelf's heading: a title (with a chevron when it leads to a tab) and a line under it.
struct HomeSectionTitle: View {
    var title: String
    var destination: ShellTab?
    @Environment(ShellModel.self) private var shell

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let destination {
                Button {
                    shell.select(destination)
                } label: {
                    HStack(spacing: 4) {
                        Text(title).font(.title2).bold()
                        Image(systemName: "chevron.right")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: ShowcaseMetrics.minimumTap)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title2).bold()
            }
        }
        .padding(.horizontal, ShowcaseMetrics.margin)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif
