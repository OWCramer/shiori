#if os(tvOS)
import SwiftUI

/// The library on Apple TV (Phase 15, design A "Shelf"): the focused game's art fills the
/// screen, its logo and actions sit at the left, and a shelf of capsules runs along the
/// bottom. Everything is driven by the focus engine, so the Siri Remote and a controller
/// work the same way.
struct TVHomeView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @AppStorage("libraryFilter") private var filter: LibraryFilter = .visualNovels
    @State private var path: [LibraryGame] = []
    @State private var featured: LibraryGame?
    @State private var showingDownloads = false
    @State private var showingSettings = false
    @FocusState private var focusedCard: UInt32?

    private var shelf: [LibraryGame] {
        steam.library.filter { game in
            switch filter {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.isOnDevice(game.appID)
            }
        }
    }

    /// The game behind the shelf: the last capsule that had focus, else the first.
    private var hero: LibraryGame? {
        if let featured, shelf.contains(where: { $0.appID == featured.appID }) { return featured }
        return shelf.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .topLeading) {
                TVBackdrop(game: hero)
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    Spacer(minLength: 20)
                    if let hero {
                        info(for: hero)
                    } else {
                        placeholder
                    }
                    Spacer(minLength: 30)
                    shelfRow
                }
            }
            .navigationDestination(for: LibraryGame.self) { TVGamePage(game: $0) }
            // The shelf, not the top bar, has focus when the library appears.
            .defaultFocus($focusedCard, hero?.appID)
            #if DEBUG
            // `-ShioriOpenGame <appid>` opens that game's page once the library loads.
            .task(id: steam.library.count) {
                let appID = UserDefaults.standard.integer(forKey: "ShioriOpenGame")
                if path.isEmpty, let game = steam.library.first(where: { $0.appID == appID }) { path = [game] }
                // `-ShioriOpenScreen downloads|settings` opens that screen.
                switch UserDefaults.standard.string(forKey: "ShioriOpenScreen") {
                case "downloads": showingDownloads = true
                case "settings": showingSettings = true
                default: break
                }
            }
            #endif
        }
        .environment(\.colorScheme, .dark)
        .fullScreenCover(isPresented: $showingDownloads) {
            DownloadsView(library: steam.library)
                .background { TVCoverBackground(game: hero) }
                .environment(\.colorScheme, .dark)
        }
        .fullScreenCover(isPresented: $showingSettings) {
            SettingsView()
                .background { TVCoverBackground(game: hero) }
                .environment(\.colorScheme, .dark)
        }
        .onAppear { ControllerInput.tabSwitch = { step in switchTab(step) } }
        .onDisappear { ControllerInput.tabSwitch = nil }
        .onChange(of: focusedCard) { _, id in
            guard let id, let game = shelf.first(where: { $0.appID == id }) else { return }
            withAnimation(.smooth(duration: 0.35)) { featured = game }
        }
    }

    /// The shoulder buttons: the previous or next tab, on the library itself (not a game
    /// page or a cover over it).
    private func switchTab(_ step: Int) {
        guard path.isEmpty, !showingDownloads, !showingSettings,
              games.artemisSession == nil, games.lucaSession == nil, shiori_renpy_is_running() == 0 else { return }
        let all = LibraryFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        let next = index + step
        guard all.indices.contains(next) else { return }
        withAnimation(.smooth(duration: 0.25)) { filter = all[next] }
        focusedCard = nil
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 16) {
            ForEach(LibraryFilter.allCases) { tab in
                Button(tab.rawValue) { filter = tab }
                    .buttonStyle(TVPillButtonStyle(selected: tab == filter))
            }
            Spacer()
            // Downloads and Settings open screens over the library rather than switching
            // what it shows, so they sit apart from the tabs, at the right.
            Button {
                showingDownloads = true
            } label: {
                Image(systemName: games.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .symbolEffect(.pulse, isActive: games.isDownloading)
                    .overlay(alignment: .topTrailing) {
                        if !games.downloadItems.isEmpty {
                            Text("\(games.downloadItems.count)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 1)
                                .background(.blue, in: .capsule)
                                .offset(x: 14, y: -10)
                        }
                    }
            }
            .buttonStyle(TVPillButtonStyle(selected: false))
            .accessibilityLabel(games.downloadItems.isEmpty ? "Downloads" : "Downloads, \(games.downloadItems.count)")
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(TVPillButtonStyle(selected: false))
            .accessibilityLabel("Settings")
        }
        .focusSection()
    }

    // MARK: - The focused game

    private func info(for game: LibraryGame) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            TVGameTitle(game: game, maxWidth: 640, maxHeight: 220)
            Text(TVGameText.statusLine(game, games: games))
                .font(.title3)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 6)
            if case let .downloading(progress) = games.status(for: game.appID) {
                ProgressView(value: progress.fraction).frame(maxWidth: 520)
            }
            HStack(spacing: 24) {
                let primary = TVGameText.primaryAction(game, games: games, steam: steam)
                Button {
                    primary.run()
                } label: {
                    Label(primary.title, systemImage: primary.symbol).padding(.horizontal, 18)
                }
                .disabled(!primary.isEnabled)
                Button("Details") { path.append(game) }
            }
        }
        .frame(maxWidth: 900, alignment: .leading)
        .id(game.appID)
        .transition(.opacity)
        .focusSection()
    }

    @ViewBuilder private var placeholder: some View {
        if steam.isLoadingLibrary, steam.library.isEmpty {
            ProgressView("Loading library…")
        } else if filter == .installed {
            ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                   description: Text("Choose Visual Novels, pick a game and download it."))
        } else {
            ContentUnavailableView("No visual novels", systemImage: "books.vertical",
                                   description: Text("None of your games has Steam's Visual Novel tag."))
        }
    }

    // MARK: - Shelf

    private var shelfRow: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(filter.rawValue)
                .font(.headline)
                .foregroundStyle(.white.opacity(0.9))
            ScrollView(.horizontal) {
                LazyHStack(spacing: 44) {
                    ForEach(shelf) { game in
                        Button {
                            path.append(game)
                        } label: {
                            TVCapsule(game: game, status: games.status(for: game.appID))
                        }
                        .buttonStyle(.card)
                        .focused($focusedCard, equals: game.appID)
                        .contextMenu {
                            Button(curation.isVisualNovel(game) ? "Remove from Visual Novels" : "Add to Visual Novels") {
                                curation.toggle(game)
                            }
                        }
                    }
                }
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
            // A fresh scroll position per tab: a shorter list left scrolled past its end
            // showed nothing to select.
            .id(filter)
        }
        .focusSection()
    }
}

/// A capsule on the TV shelf, with the game's state in its corner.
struct TVCapsule: View {
    let game: LibraryGame
    let status: GameLibrary.Status

    var body: some View {
        CapsuleArt(game: game)
            .frame(width: 220, height: 330)
            .overlay(alignment: .bottomTrailing) { badge.padding(12) }
            .overlay(alignment: .bottom) {
                if case let .downloading(progress) = status {
                    ProgressView(value: progress.fraction).tint(.white).padding(12)
                }
            }
    }

    @ViewBuilder private var badge: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .green)
                .font(.title3)
        case .queued, .preparing, .verifying:
            Image(systemName: "clock.fill").foregroundStyle(.white).font(.title3)
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.white).font(.title3)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .red)
                .font(.title3)
        case .downloading, .notInstalled:
            EmptyView()
        }
    }
}

/// Behind a screen opened over the library (Downloads, Settings): the library's art,
/// blurred and dimmed, as tvOS's own full-screen sheets look.
struct TVCoverBackground: View {
    let game: LibraryGame?

    var body: some View {
        ZStack {
            Color.black
            if let game {
                RemoteImage(url: game.hero, fallback: game.header) { Color.black }
                    .blur(radius: 60)
                    .scaleEffect(1.15)
            }
            Color.black.opacity(0.62)
        }
        .ignoresSafeArea()
    }
}

/// The game's hero art across the whole screen, darkened at the left and bottom for text.
struct TVBackdrop: View {
    let game: LibraryGame?

    var body: some View {
        ZStack {
            Color.black
            if let game {
                RemoteImage(url: game.hero, fallback: game.header) { ArtworkPlaceholder(title: game.name) }
                    .id(game.appID)
                    .transition(.opacity)
            }
            LinearGradient(stops: [.init(color: .black.opacity(0.92), location: 0), .init(color: .black.opacity(0.5), location: 0.4),
                                   .init(color: .clear, location: 0.72)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.6), location: 0.3),
                                   .init(color: .clear, location: 0.6)],
                           startPoint: .bottom, endPoint: .top)
        }
        .ignoresSafeArea()
    }
}

/// The game's logo, or its name when it has none.
struct TVGameTitle: View {
    let game: LibraryGame
    var maxWidth: CGFloat
    var maxHeight: CGFloat

    var body: some View {
        Group {
            if let logo = game.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading) { name }
            } else {
                name
            }
        }
        .frame(maxWidth: maxWidth, maxHeight: maxHeight, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.6), radius: 10, y: 3)
    }

    private var name: some View {
        Text(game.name)
            .font(.system(size: 76, weight: .heavy))
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
    }
}

/// A rounded tab-like button for the top bar; white when selected or focused.
struct TVPillButtonStyle: ButtonStyle {
    var selected: Bool
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(selected || isFocused ? .black : .white.opacity(0.8))
            .padding(.horizontal, 30)
            .padding(.vertical, 14)
            .background(selected || isFocused ? .white : .white.opacity(isFocused ? 0.3 : 0.001), in: .capsule)
            .scaleEffect(isFocused ? 1.08 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.4 : 0), radius: 12, y: 6)
            .animation(.smooth(duration: 0.2), value: isFocused)
    }
}

/// Shared wording and the main action, for the shelf and the game page.
@MainActor
enum TVGameText {
    struct Action {
        var title: String
        var symbol: String
        var isEnabled = true
        var run: () -> Void
    }

    static func statusLine(_ game: LibraryGame, games: GameLibrary) -> String {
        if games.restoring.contains(game.appID), case let .downloading(progress) = games.status(for: game.appID) {
            return "Restoring files tvOS cleared · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
        }
        switch games.status(for: game.appID) {
        case let .installed(record):
            if let phase = games.launchPhase(for: game.appID) { return phase.label }
            if let blocker = games.playBlocker(appID: game.appID) { return blocker }
            return "Ready to play · \(record.sizeBytes.formatted(.byteCount(style: .file)))"
        case .notInstalled:
            return game.estimatedSize.map { "Not downloaded · \($0.formatted(.byteCount(style: .file)))" } ?? "Not downloaded"
        case .queued: return "Queued"
        case .preparing: return "Preparing download…"
        case let .downloading(progress): return "Downloading · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))"
        case .paused: return "Download paused"
        case .verifying: return "Verifying files…"
        case let .failed(message, _): return message
        }
    }

    static func primaryAction(_ game: LibraryGame, games: GameLibrary, steam: SteamModel) -> Action {
        let appID = game.appID
        switch games.status(for: appID) {
        case .installed:
            if let phase = games.launchPhase(for: appID) { return Action(title: phase.label, symbol: "hourglass", isEnabled: false) {} }
            if games.playBlocker(appID: appID) != nil { return Action(title: "Not playable yet", symbol: "exclamationmark.triangle", isEnabled: false) {} }
            return Action(title: "Play", symbol: "play.fill") { games.play(appID: appID) }
        case .notInstalled:
            return Action(title: "Download", symbol: "arrow.down.circle.fill", isEnabled: steam.isLoggedOn) { games.download(game) }
        case .queued, .preparing, .downloading:
            return Action(title: "Pause", symbol: "pause.fill") { games.pause(appID: appID) }
        case .paused, .failed:
            return Action(title: "Resume", symbol: "arrow.down.circle.fill", isEnabled: steam.isLoggedOn) {
                games.resume(appID: appID, name: game.name)
            }
        case .verifying:
            return Action(title: "Verifying…", symbol: "checkmark.shield", isEnabled: false) {}
        }
    }
}
#endif
