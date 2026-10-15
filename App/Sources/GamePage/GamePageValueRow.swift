// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

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
