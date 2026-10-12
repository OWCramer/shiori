#if os(iOS)
import SwiftUI

/// A collection's page (Phase 20): its first game's banner with the collection's name, how
/// many games and how much they weigh, Download All, then its games and sub-groups in
/// release order.
struct CollectionPage: View {
    let collectionID: String
    @Environment(LibraryCollections.self) private var collections
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var overscroll: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var confirmingDownload = false
    @State private var pastHero = false

    private var collection: LibraryCollection? { collections.collection(id: collectionID) }

    var body: some View {
        if let collection {
            page(collection)
        } else {
            ContentUnavailableView("No Collection", systemImage: "square.stack",
                                   description: Text("This collection was removed, maybe on another device."))
        }
    }

    private func page(_ collection: LibraryCollection) -> some View {
        let byID = Dictionary(steam.library.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        let members = collection.inReleaseOrder.compactMap { byID[$0] }
        let summary = CollectionSummary(games: members, library: games, engineScans: engineScans)
        let wide = sizeClass == .regular && width >= GamePageMetrics.twoColumnWidth
        let parentName = collection.parentID.flatMap { collections.collection(id: $0)?.name }
        return ScrollView {
            VStack(spacing: 8) {
                if let lead = members.first {
                    CollectionHero(collection: collection, lead: lead, parentName: parentName, summary: summary,
                                   bannerHeight: GameHeroHeader.height(forViewport: viewportHeight), overscroll: overscroll,
                                   wide: wide) { confirmingDownload = true }
                }
                LibraryGrid(items: LibraryGridItem.page(of: collection, library: byID))
                    .frame(maxWidth: wide ? GamePageMetrics.wideContentWidth : nil)
                    .padding(.vertical, 8)
            }
            .padding(.bottom, 40)
        }
        .scrollOverscroll($overscroll)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewportHeight = size.height
            width = size.width
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > GameHeroHeader.height(forViewport: geometry.containerSize.height) - 120
        } action: { _, past in
            pastHero = past
        }
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Past the banner, a scrim under the status bar and title, as on a game's page.
        .overlay(alignment: .top) {
            LinearGradient(stops: [.init(color: .black.opacity(0.9), location: 0), .init(color: .black.opacity(0.75), location: 0.6),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .ignoresSafeArea(edges: .top)
                .opacity(pastHero ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: pastHero)
                .allowsHitTesting(false)
        }
        .background {
            if let lead = members.first { GameBackdrop(game: lead) } else { Color.black.ignoresSafeArea() }
        }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(downloadTitle(summary), isPresented: $confirmingDownload, titleVisibility: .visible) {
            Button("Download \(summary.toDownload.count == 1 ? "1 Game" : "\(summary.toDownload.count) Games")") {
                downloadAll(summary.toDownload)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(downloadMessage(summary))
        }
    }

    private func downloadTitle(_ summary: CollectionSummary) -> String {
        let count = summary.toDownload.count
        return count == 1 ? "Download 1 game?" : "Download \(count) games?"
    }

    private func downloadMessage(_ summary: CollectionSummary) -> String {
        let size = summary.downloadSize > 0 ? "About \(summary.downloadSize.formatted(.byteCount(style: .file))) in all. " : ""
        let queue = summary.toDownload.count == 1 ? "It joins the download queue."
            : "They join the download queue and download one at a time, in release order."
        return size + queue
    }

    /// Queues every game not downloaded yet, first released first; paused ones resume.
    private func downloadAll(_ targets: [LibraryGame]) {
        for game in targets {
            switch games.status(for: game.appID) {
            case .notInstalled: games.download(game)
            case .paused, .failed: games.resume(appID: game.appID, name: game.name)
            default: break
            }
        }
    }
}
#endif
