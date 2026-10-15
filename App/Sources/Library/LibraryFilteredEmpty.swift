// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A tab whose filters hide every game: which filters, and Clear Filters.
struct LibraryFilteredEmpty: View {
    @Binding var filters: LibraryFilters
    let total: Int

    var body: some View {
        ContentUnavailableView {
            Label("No Games Match", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("All \(total) games are hidden by: \(filters.summary).")
        } actions: {
            Button("Clear Filters", action: clear)
                .buttonStyle(.borderedProminent)
        }
    }

    private func clear() { withAnimation { filters = LibraryFilters() } }
}
#endif
