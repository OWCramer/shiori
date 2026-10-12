#if os(iOS)
import SwiftUI

/// A collection in the iPad's sidebar: its page, with games pushed over it.
struct CollectionTab: View {
    let collectionID: String
    @State private var path: [LibraryRoute] = []

    var body: some View {
        BookHandoffStack(path: $path, tab: .collection(collectionID)) {
            CollectionPage(collectionID: collectionID)
                .libraryDestinations()
        }
    }
}
#endif
