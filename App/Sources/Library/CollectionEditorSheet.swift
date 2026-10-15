// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A collection's editor as a sheet (a collection page's Edit, a tile's menu). It closes
/// itself once the collection is hidden, deleted or merged away.
struct CollectionEditorSheet: View {
    let collectionID: String
    @Environment(LibraryCollections.self) private var collections
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CollectionEditor(collectionID: collectionID)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .onChange(of: collections.collection(id: collectionID) == nil) { _, gone in
            if gone { dismiss() }
        }
    }
}
#endif
