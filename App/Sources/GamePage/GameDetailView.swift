// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The page for one game (design A, Phase 18). The top is Home's: the stretchy banner with
/// the logo, and the art extended below it behind a line on the game and Play's row. Below, on
/// plain grouped surfaces, what a player needs in the order they need it: anything stopping
/// play, the saves, patches and DLC, compatibility, then the version, engine and files. On a
/// wide window (an iPad in landscape) those last two go in a second column beside the rest.
struct GameDetailView: View {
    /// The game as navigated to; `game` follows the live library, so artwork picks show at once.
    private let opened: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(PatchInstaller.self) private var patchInstaller
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.portraitHero) private var portraitHero
    @State private var model: GamePageModel
    @State private var overscroll: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    /// On screen (not covered by a page pushed over it): the keyboard's Game commands act on it.
    @State private var isVisible = false
    /// Scrolled past the banner: the navigation bar gets its background, so the sections
    /// don't run under the title.
    @State private var pastHero = false

    init(game: LibraryGame) {
        opened = game
        _model = State(initialValue: GamePageModel(appID: game.appID))
    }

    private var game: LibraryGame { steam.library.first { $0.appID == opened.appID } ?? opened }
    private var appID: UInt32 { opened.appID }
    private var folder: URL { games.folder(appID: appID, name: game.name) }
    private var stage: GameLibrary.Stage { games.stage(for: appID) }
    private var record: GameRecord? { games.record(for: appID) }

    /// "Played yesterday · Ren'Py 8 · 2.09 GB", as on Home; before download, what Steam's
    /// manifests say the game is and weighs.
    private var metaLine: String {
        var parts: [String] = []
        if let record {
            if let activity = PlayHistory.shared.lastActivity(appID) { parts.append(activity.description) }
            parts.append(Playability.badge(record.engine, appID: appID))
            parts.append(record.sizeBytes.formatted(.byteCount(style: .file)))
        } else {
            let scan = engineScans.result(for: appID)
            if let scan, scan.error == nil { parts.append(Playability.badge(scan.engine, appID: appID)) }
            let size = scan.flatMap { $0.installSize > 0 ? $0.installSize : nil } ?? game.estimatedSize
            if let size { parts.append(size.formatted(.byteCount(style: .file))) }
        }
        return parts.joined(separator: " · ")
    }

    /// Wide enough for the details in a column of their own.
    private var twoColumns: Bool { sizeClass == .regular && width >= GamePageMetrics.twoColumnWidth }

    /// The banner's height for this screen (shorter on short screens).
    private var bannerHeight: CGFloat {
        // Room for the cover card, with the line on the game and Play still in view.
        if portraitHero, viewportHeight > 0 { return viewportHeight * 0.64 }
        return GameHeroHeader.height(forViewport: viewportHeight)
    }

    var body: some View {
        let _ = RenderProbe.hit("GameDetailView")
        let margin = sizeClass == .regular ? GamePageMetrics.wideMargin : GamePageMetrics.margin
        ScrollView {
            VStack(spacing: 8) {
                GamePageHero(game: game, model: model, metaLine: metaLine, bannerHeight: bannerHeight, overscroll: overscroll,
                             contentWidth: twoColumns ? GamePageMetrics.wideContentWidth : GamePageMetrics.readableWidth,
                             margin: margin, wide: twoColumns)
                if twoColumns {
                    HStack(alignment: .top, spacing: GamePageMetrics.sectionSpacing) {
                        VStack(alignment: .leading, spacing: GamePageMetrics.sectionSpacing) {
                            GamePagePlaySections(game: game, record: record, model: model)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: GamePageMetrics.sectionSpacing) {
                            GamePageDetailSections(game: game, record: record, model: model)
                        }
                        .frame(width: GamePageMetrics.detailColumnWidth)
                    }
                    .frame(maxWidth: GamePageMetrics.wideContentWidth)
                    .padding(.horizontal, margin)
                } else {
                    VStack(alignment: .leading, spacing: GamePageMetrics.sectionSpacing) {
                        GamePagePlaySections(game: game, record: record, model: model)
                        GamePageDetailSections(game: game, record: record, model: model)
                    }
                    .frame(maxWidth: GamePageMetrics.readableWidth)
                    .padding(.horizontal, margin)
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
        // Past the banner, a dark scrim under the status bar and title, so the sections
        // don't run unreadably beneath them. (Decoration: it takes no touches.)
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
        .background { GameBackdrop(game: game) }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $model.browsingArchives) { ArchiveBrowserView(gameFolder: folder) }
        .sheet(isPresented: $model.choosingArtwork) {
            ArtworkPickerView(appID: appID)
                .environment(steam.artwork)
        }
        .fileImporter(isPresented: $model.importingPatch, allowedContentTypes: [.zip, .folder, .item]) { result in
            model.importPatch(result, folder: folder)
        }
        .modifier(GamePageDialogs(game: game, model: model))
        // A patch dropped anywhere on the page (iPad) is imported after asking.
        .modifier(PatchDropTarget(game: game, cornerRadius: 0))
        .focusedSceneValue(isVisible ? model : nil)
        .onDisappear { isVisible = false }
        .onChange(of: PatchImports.shared.finished[appID]) { reloadPatches() }
        .onChange(of: game, initial: true) { _, game in model.game = game }
        .onAppear(perform: appeared)
        .task(id: steam.isLoggedOn) { await checkGame() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadPatches() } }
        .onChange(of: stage) { reloadPatches() }
    }

    private func appeared() {
        isVisible = true
        reloadPatches()
        #if DEBUG
        // `-ShioriBrowseArchives YES` (with -ShioriOpenGame) opens the archive browser.
        if UserDefaults.standard.bool(forKey: "ShioriBrowseArchives") { model.browsingArchives = true }
        #endif
    }

    /// Engine scans for games that don't play as they are (a beta might), and whether the
    /// game uses Steam Cloud at all.
    private func checkGame() async {
        let unplayable = record.map { Playability($0.engine) != .playable } ?? true
        if unplayable, steam.isLoggedOn { engineScans.scan([appID]) }
        if steam.isLoggedOn { await games.loadSteamCloudSupport(appID) }
    }

    private func reloadPatches() {
        model.reloadPatches(folder: folder)
    }
}
#endif
