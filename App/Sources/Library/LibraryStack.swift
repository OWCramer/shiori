// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A tab's navigation stack, where a game's page zooms out of the cover that opened it and
/// back into it (the zoom navigation transition).
struct LibraryStack<Root: View>: View {
    @Binding var path: [LibraryRoute]
    @ViewBuilder var root: Root
    @Namespace private var namespace
    @State private var zoom = GameZoom()

    var body: some View {
        NavigationStack(path: $path) { root }
            .environment(\.gameZoom, GameZoom.Scope(namespace: namespace, model: zoom))
    }
}

/// Which cover opened the game page on top: the same game can show more than once on a
/// screen (Home's banner and Continue Playing), and the page zooms from the one tapped.
@MainActor @Observable
final class GameZoom {
    var source = ""

    struct Scope {
        let namespace: Namespace.ID
        let model: GameZoom
    }
}

extension EnvironmentValues {
    @Entry var gameZoom: GameZoom.Scope?
}

/// A game's page as a stack pushes it, zooming from the cover tapped.
struct ZoomedGamePage: View {
    let game: LibraryGame
    @Environment(\.gameZoom) private var zoom

    var body: some View {
        if let zoom, !zoom.model.source.isEmpty {
            GameDetailView(game: game)
                .navigationTransition(.zoom(sourceID: zoom.model.source, in: zoom.namespace))
        } else {
            GameDetailView(game: game)
        }
    }
}
#endif
