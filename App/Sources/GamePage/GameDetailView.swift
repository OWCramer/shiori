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
    @State private var model: GamePageModel
    @State private var overscroll: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var width: CGFloat = 0
    /// On screen (not covered by a page pushed over it): the keyboard's Game commands act on it.
    @State private var isVisible = false

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
    private var bannerHeight: CGFloat { GameHeroHeader.height(forViewport: viewportHeight) }

    var body: some View {
        let _ = RenderProbe.hit("GameDetailView")
        let margin = sizeClass == .regular ? GamePageMetrics.wideMargin : GamePageMetrics.margin
        Group {
            if sideBySide {
                sideBySideBody
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                        viewportHeight = size.height
                        width = size.width
                    }
            } else {
                scrollingBody(margin: margin)
            }
        }
        .background { GameBackdrop(game: game) }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        // Laid out wide, the box art carries the name: no title over it (the back menu keeps
        // it). Otherwise the name is the bar's own item, so it stays while the page scrolls.
        .toolbar {
            ToolbarItem(placement: .principal) {
                if sideBySide {
                    Color.clear.frame(width: 1, height: 1)
                } else {
                    Text(game.name).font(.headline).lineLimit(1)
                }
            }
        }
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

    /// A wide, short screen (the opened iPhone Duo, a phone held sideways): as Music's album
    /// page, the game's art, logo and Play held on the left, the sections scrolling beside it.
    private var sideBySide: Bool {
        width >= 700 && viewportHeight > 0 && width > viewportHeight * 1.2 && viewportHeight < 800
    }

    private var sideBySideBody: some View {
        HStack(spacing: 0) {
            GamePageCover(game: game, model: model, metaLine: metaLine)
                .frame(width: (width * 0.46).rounded())
                // Up under the bar, which holds only Back here: no empty band above the art,
                // and the cover doesn't grow as the bar's background comes and goes.
                .ignoresSafeArea(.container, edges: .top)
            ScrollView {
                VStack(alignment: .leading, spacing: GamePageMetrics.sectionSpacing) {
                    GamePagePlaySections(game: game, record: record, model: model)
                    GamePageDetailSections(game: game, record: record, model: model)
                }
                .padding(.horizontal, GamePageMetrics.wideMargin)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }

    private func scrollingBody(margin: CGFloat) -> some View {
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
        // The viewport as before the page runs under the status bar: the banner's height
        // follows it.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewportHeight = size.height
            width = size.width
        }
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
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
