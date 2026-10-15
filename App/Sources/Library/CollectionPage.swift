// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// A collection's page (Phase 20): its first game's banner with the collection's name, how
/// many games and how much they weigh, Download All, then its games and sub-groups in
/// release order.
struct CollectionPage: View {
    let collectionID: String
    /// Opened from Installed or a filtered grid: only that part of it, until Show All.
    var scope: CollectionScope?
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
    @State private var showsAll = false
    @State private var editing = false
    @Environment(\.dismiss) private var dismiss

    private var collection: LibraryCollection? { collections.collection(id: collectionID) }

    var body: some View {
        Group {
            if let collection {
                page(collection)
            } else {
                ContentUnavailableView("No Collection", systemImage: "square.stack",
                                       description: Text("This collection was removed."))
            }
        }
        .toolbar {
            if collection != nil {
                Button("Edit") { editing = true }
            }
        }
        .sheet(isPresented: $editing) { CollectionEditorSheet(collectionID: collectionID) }
        // Hidden, deleted or merged away (here or on another device): back to where it was opened.
        .onChange(of: collection == nil) { _, gone in
            if gone { dismiss() }
        }
    }

    /// The scope in force: none once Show All is on, or when it would leave every game in.
    private func activeScope(_ collection: LibraryCollection) -> CollectionScope? {
        guard let scope, !showsAll else { return nil }
        let kept = collection.inReleaseOrder.filter { scope.admits($0, library: games) }.count
        return kept < collection.inReleaseOrder.count ? scope : nil
    }

    private func page(_ whole: LibraryCollection) -> some View {
        let byID = Dictionary(steam.library.map { ($0.appID, $0) }, uniquingKeysWith: { first, _ in first })
        let scope = activeScope(whole)
        let collection = scope.map { scope in whole.filtered { scope.admits($0, library: games) } } ?? whole
        let members = collection.inReleaseOrder.compactMap { byID[$0] }
        let summary = CollectionSummary(games: members, library: games, engineScans: engineScans)
        let total = whole.inReleaseOrder.count
        let scoped = scope.map { scope in
            (line: scope.line(shown: members.count, of: total), total: total, showAll: { withAnimation { showsAll = true } })
        }
        let wide = sizeClass == .regular && width >= GamePageMetrics.twoColumnWidth
        let parentName = collection.parentID.flatMap { collections.collection(id: $0)?.name }
        return ScrollView {
            VStack(spacing: 8) {
                if let lead = members.first {
                    CollectionHero(collection: collection, lead: lead, parentName: parentName, summary: summary,
                                   bannerHeight: GameHeroHeader.height(forViewport: viewportHeight), overscroll: overscroll,
                                   wide: wide, scoped: scoped) { confirmingDownload = true }
                }
                LibraryGrid(items: LibraryGridItem.page(of: collection, library: byID))
                    .frame(maxWidth: wide ? GamePageMetrics.wideContentWidth : nil)
                    .padding(.vertical, 8)
                    // Sub-groups open on the same part as this page.
                    .environment(\.collectionScope, scope)
                if let scoped {
                    // As Apple Music ends a downloaded album: the way to the rest.
                    scopeRow("Show All \(total) Games", systemImage: "square.stack", wide: wide, action: scoped.showAll)
                } else if self.scope != nil, showsAll {
                    scopeRow(self.scope == .downloaded ? "Show Only Downloaded" : "Show Only Filtered Games",
                             systemImage: "line.3.horizontal.decrease", wide: wide) { withAnimation { showsAll = false } }
                }
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

    private func scopeRow(_ title: String, systemImage: String, wide: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .padding(.horizontal, ShowcaseMetrics.margin)
        .frame(maxWidth: wide ? GamePageMetrics.wideContentWidth : nil)
    }

    private func downloadTitle(_ summary: CollectionSummary) -> String {
        let count = summary.toDownload.count
        return count == 1 ? "Download 1 game?" : "Download \(count) games?"
    }

    private func downloadMessage(_ summary: CollectionSummary) -> String {
        summary.downloadSize > 0 ? "About \(summary.downloadSize.formatted(.byteCount(style: .file)))." : ""
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
