#if os(iOS)
import SwiftUI

/// All Collections in the iPad's sidebar: the list, opening each collection's page.
struct CollectionsTab: View {
    @State private var path: [LibraryRoute] = []

    var body: some View {
        BookHandoffStack(path: $path, tab: .collections) {
            CollectionsScreen(opensPages: true)
                .libraryDestinations()
        }
    }
}
#endif
