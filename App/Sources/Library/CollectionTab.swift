// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A collection in the iPad's sidebar: its page, with games pushed over it.
struct CollectionTab: View {
    let collectionID: String
    @State private var path: [LibraryRoute] = []

    var body: some View {
        LibraryStack(path: $path) {
            CollectionPage(collectionID: collectionID)
                .libraryDestinations()
        }
    }
}
#endif
