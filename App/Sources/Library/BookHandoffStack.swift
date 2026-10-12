#if os(iOS)
import SwiftUI

/// A tab's navigation stack that hands its open game to the opened Duo's left page, and
/// takes it back when the Duo folds. Without it, a game opened on the cover screen stayed
/// pushed in the library when unfolded, beside the same page on the left: two of it.
struct BookHandoffStack<Root: View>: View {
    @Binding var path: [LibraryGame]
    let tab: ShellTab
    @ViewBuilder var root: Root
    @Environment(BookSelection.self) private var book: BookSelection?
    @Environment(ShellModel.self) private var shell

    var body: some View {
        NavigationStack(path: $path) { root }
            .onChange(of: book?.isOpen ?? false) { _, open in
                guard let book else { return }
                if open {
                    // The current tab's game moves to the left page; every tab drops its
                    // pushed pages, which the left page now shows instead.
                    if shell.tab == tab, let last = path.last { book.show(last) }
                    path.removeAll()
                } else if shell.tab == tab, path.isEmpty, let game = book.foldedGame {
                    path.append(game)
                    book.foldedGame = nil
                }
            }
    }
}
#endif
