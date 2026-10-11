#if os(iOS)
import SwiftUI

/// The Home tab (design A, "Showcase"): the game you last played full-bleed with its
/// actions, then shelves: Continue Playing, Downloading, Ready to Play, games that play in
/// Shiori but aren't downloaded, and the start of your Visual Novels.
struct HomeView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(\.shell) private var shell
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [LibraryGame] = []

    private var history: PlayHistory { .shared }

    /// Everything Home shows, worked out once per update.
    private struct Shelves {
        var featured: LibraryGame?
        var continuePlaying: [LibraryGame] = []
        var downloading: [LibraryGame] = []
        var readyToPlay: [LibraryGame] = []
        var playsInShiori: [LibraryGame] = []
        var visualNovels: [LibraryGame] = []
        var installedCount = 0
        var installedBytes: UInt64 = 0
    }

    private var shelves: Shelves {
        var shelves = Shelves()
        var installed: [(game: LibraryGame, record: GameRecord)] = []
        for game in steam.library {
            if case let .installed(record) = games.status(for: game.appID) { installed.append((game, record)) }
        }
        shelves.installedCount = installed.count
        shelves.installedBytes = installed.reduce(0) { $0 + $1.record.sizeBytes }

        // Played or saved, newest first.
        let active = installed.compactMap { entry in history.lastActivity(entry.game.appID).map { (entry.game, $0.date) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let playable = installed.filter { games.playBlocker(appID: $0.game.appID) == nil }
        shelves.featured = active.first ?? playable.max { $0.record.installedAt < $1.record.installedAt }?.game
        shelves.continuePlaying = active.filter { $0.appID != shelves.featured?.appID }

        let byID = Dictionary(steam.library.map { ($0.appID, $0) }, uniquingKeysWith: { a, _ in a })
        shelves.downloading = games.downloadItems.compactMap { byID[$0] }

        // Downloaded, playable, not started yet: newest download first.
        let started = Set(active.map(\.appID))
        shelves.readyToPlay = playable
            .filter { !started.contains($0.game.appID) && $0.game.appID != shelves.featured?.appID }
            .sorted { $0.record.installedAt > $1.record.installedAt }
            .map(\.game)

        let vns = steam.library.filter { curation.isVisualNovel($0) }
        shelves.visualNovels = vns
        shelves.playsInShiori = vns.filter { game in
            guard games.status(for: game.appID) == .notInstalled,
                  let scan = engineScans.result(for: game.appID), scan.error == nil else { return false }
            return Playability(scan.engine, appID: game.appID) == .playable || scan.playableBranch != nil
        }
        return shelves
    }

    private var wide: Bool { sizeClass == .regular }

    var body: some View {
        let shelves = shelves
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if let featured = shelves.featured {
                        HomeHero(game: featured)
                    }
                    if !shelves.continuePlaying.isEmpty {
                        HomeShelf(title: "Continue Playing", subtitle: "Played or saved most recently") {
                            ForEach(shelves.continuePlaying) { ContinueCard(game: $0) }
                        }
                    }
                    if !shelves.downloading.isEmpty {
                        HomeShelf(title: "Downloading",
                                  subtitle: "\(shelves.downloading.count) in the queue",
                                  action: { shell.select(.downloads) }) {
                            ForEach(shelves.downloading) { LibraryCell(game: $0).frame(width: wide ? 150 : 112) }
                        }
                    }
                    if !shelves.readyToPlay.isEmpty {
                        HomeShelf(title: "Ready to Play",
                                  subtitle: "Downloaded, not started yet",
                                  action: { shell.select(.installed) }) {
                            ForEach(shelves.readyToPlay) { LibraryCell(game: $0).frame(width: wide ? 150 : 112) }
                        }
                    }
                    if !shelves.playsInShiori.isEmpty {
                        HomeShelf(title: "Plays in Shiori",
                                  subtitle: "Checked from Steam's files · \(shelves.playsInShiori.count) not downloaded") {
                            ForEach(shelves.playsInShiori.prefix(30)) { LibraryCell(game: $0).frame(width: wide ? 150 : 112) }
                        }
                    }
                    if !shelves.visualNovels.isEmpty {
                        visualNovels(shelves.visualNovels)
                    }
                }
                .padding(.top, shelves.featured == nil ? 8 : 0)
                .padding(.bottom, 30)
            }
            .ignoresSafeArea(edges: shelves.featured == nil ? [] : .top)
            .overlay { placeholder(shelves) }
            .refreshable { await steam.loadLibrary() }
            .background {
                if let featured = shelves.featured { GameBackdrop(game: featured) } else { Color.black.ignoresSafeArea() }
            }
            .navigationTitle(shelves.featured == nil ? "Home" : "")
            .navigationBarTitleDisplayMode(shelves.featured == nil ? .large : .inline)
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { shell.addGame() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a game to Visual Novels")
                }
                ToolbarItem(placement: .topBarTrailing) { SettingsButton() }
            }
            #if DEBUG
            // `-ShioriOpenGame <appid>` opens that game's screen once the library loads.
            .task(id: steam.library.count) {
                let appID = UserDefaults.standard.integer(forKey: "ShioriOpenGame")
                if path.isEmpty, let game = steam.library.first(where: { $0.appID == appID }) { path = [game] }
            }
            #endif
        }
    }

    private func visualNovels(_ all: [LibraryGame]) -> some View {
        let limit = wide ? 24 : 18
        return VStack(alignment: .leading, spacing: 12) {
            HomeSectionTitle(title: "Your Visual Novels",
                             subtitle: "\(all.count) games · tagged on Steam or added by you",
                             action: { shell.select(.visualNovels) })
            LibraryGrid(games: Array(all.prefix(limit)))
            if all.count > limit {
                Button("Show All \(all.count)") { shell.select(.visualNovels) }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func placeholder(_ shelves: Shelves) -> some View {
        if shelves.featured == nil, shelves.visualNovels.isEmpty, shelves.downloading.isEmpty {
            if steam.isLoadingLibrary, steam.library.isEmpty {
                ProgressView("Loading library…")
            } else if let error = steam.libraryError {
                ContentUnavailableView("Couldn't load your library", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if !steam.library.isEmpty {
                ContentUnavailableView("No visual novels yet", systemImage: "books.vertical",
                                       description: Text("None of your games has Steam's Visual Novel tag. Tap + to add games."))
            } else {
                ContentUnavailableView("No games yet", systemImage: "books.vertical",
                                       description: Text(steam.offlineReason ?? "Your Steam library appears here once it loads."))
            }
        }
    }
}

/// The game you were last playing, full-bleed: its art, logo, what it is, and its actions.
private struct HomeHero: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var record: GameRecord? {
        if case let .installed(record) = games.status(for: game.appID) { record } else { nil }
    }

    /// "Played today · Ren'Py 8 · 2.09 GB".
    private var metaLine: String {
        var parts: [String] = []
        if let activity = PlayHistory.shared.lastActivity(game.appID) { parts.append(activity.description) }
        if let record {
            parts.append(Playability.badge(record.engine, appID: game.appID))
            parts.append(record.sizeBytes.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let wide = sizeClass == .regular
        RemoteImage(url: game.hero, fallback: game.header) { ArtworkPlaceholder(title: game.name) }
            .frame(height: wide ? 540 : 500)
            .backgroundExtensionEffect()
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.6), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            // The art fades into the tinted backdrop instead of ending on an edge.
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: wide ? .bottomLeading : .bottom) {
                VStack(alignment: wide ? .leading : .center, spacing: 14) {
                    Text(PlayHistory.shared.lastActivity(game.appID) == nil ? "READY TO PLAY" : "CONTINUE")
                        .font(.caption.weight(.heavy)).tracking(2)
                        .foregroundStyle(.white.opacity(0.75))
                    GameLogo(game: game, maxWidth: wide ? 420 : 300, maxHeight: wide ? 150 : 110,
                             alignment: wide ? .leading : .center)
                    if !metaLine.isEmpty {
                        Text(metaLine)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(wide ? .leading : .center)
                    }
                    HomeActionRow(game: game, canSync: record != nil)
                }
                .padding(.horizontal, wide ? 48 : 20)
                .padding(.bottom, 28)
            }
    }
}

/// Play (or what the game's state calls for), Details, Sync Now and More, merged on glass.
private struct HomeActionRow: View {
    let game: LibraryGame
    var canSync: Bool

    var body: some View {
        // Narrow screens (the Duo's cover screen) get icon-only buttons.
        ViewThatFits(in: .horizontal) {
            row(labels: 2)
            row(labels: 1)
            row(labels: 0)
        }
    }

    /// `labels`: how many of Play and Details keep their words.
    private func row(labels: Int) -> some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                PrimaryGameButton(game: game, compact: labels < 1)
                NavigationLink(value: game) {
                    Group {
                        if labels < 2 { Image(systemName: "info.circle") } else { Label("Details", systemImage: "info.circle") }
                    }
                    .font(.headline).fixedSize().padding(.vertical, 6)
                    .frame(minWidth: labels < 2 ? 22 : nil)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(labels < 2 ? .circle : .capsule)
                .accessibilityLabel("Details")
                if canSync { SyncSavesButton(appID: game.appID) }
                Menu {
                    LibraryGameMenuItems(game: game)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.headline)
                        .frame(width: 22, height: 22)
                        .padding(6)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
            }
            .fixedSize()
        }
    }
}

/// A shelf's heading: a title (a chevron when it leads somewhere) and a line under it.
private struct HomeSectionTitle: View {
    var title: String
    var subtitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.weight(.bold))
                        Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title2.weight(.bold))
            }
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct HomeShelf<Content: View>: View {
    var title: String
    var subtitle: String?
    var action: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeSectionTitle(title: title, subtitle: subtitle, action: action)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) { content }
                    .padding(.horizontal, 20)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// A game you've played: its landscape art, when you last played, and Play on glass.
private struct ContinueCard: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let canPlay = games.playBlocker(appID: game.appID) == nil
        NavigationLink(value: game) {
            HeaderArt(game: game)
                .frame(width: sizeClass == .regular ? 380 : 290)
                .overlay(alignment: .bottom) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(game.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(PlayHistory.shared.lastActivity(game.appID)?.description ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 44)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .padding(8)
                }
                .clipShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        // Outside the link's label, so it takes its own taps.
        .overlay(alignment: .bottomTrailing) {
            if canPlay {
                Button { games.play(appID: game.appID) } label: {
                    Group {
                        if games.launchPhase(for: game.appID) != nil { ProgressView() } else { Image(systemName: "play.fill") }
                    }
                    .font(.callout)
                    .frame(width: 18, height: 18)
                    .padding(9)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(.green.opacity(0.5)).interactive(), in: .circle)
                .padding(.trailing, 18).padding(.bottom, 14)
                .disabled(games.launchPhase(for: game.appID) != nil)
                .accessibilityLabel("Play \(game.name)")
            }
        }
        .hoverEffect(.lift)
        .contextMenu { LibraryGameMenuItems(game: game) }
    }
}
#endif
