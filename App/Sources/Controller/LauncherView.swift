import SteamKit
import SwiftUI

/// The library as a console launcher, for when a game controller is in hand: the focused
/// game's art fills the screen, a shelf of capsules runs along the bottom, and every
/// action is a button press.
struct LauncherView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(ControllerInput.self) private var pad
    @Environment(LibraryCuration.self) private var curation
    @AppStorage("libraryFilter") private var filter: LibraryFilter = .visualNovels
    @State private var selection = 0
    @State private var menu: LauncherMenu?
    @State private var detail: LibraryGame?

    private var shelf: [LibraryGame] {
        steam.library.filter { game in
            switch filter {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.isOnDevice(game.appID)
            }
        }
    }

    private var focused: LibraryGame? {
        shelf.indices.contains(selection) ? shelf[selection] : shelf.first
    }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.height < 500
            ZStack(alignment: .bottomLeading) {
                background
                VStack(alignment: .leading, spacing: compact ? 10 : 18) {
                    Spacer(minLength: 0)
                    if let focused { info(for: focused, compact: compact) }
                    filterTabs
                    shelfRow(height: compact ? 150 : 230)
                    hintBar
                }
                .padding(.bottom, compact ? 8 : 20)
                if let menu {
                    LauncherMenuView(menu: menu) { self.menu = nil }
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .environment(\.colorScheme, .dark)
        .background(.black)
        .animation(.smooth(duration: 0.25), value: selection)
        .animation(.smooth(duration: 0.2), value: menu?.id)
        .onAppear { pad.handler = handle }
        .onChange(of: filter) { selection = 0 }
        #if os(iOS)
        // (The launcher is iPhone and iPad only; the Apple TV has its own game page.)
        .sheet(item: $detail) { game in
            NavigationStack { GameDetailView(game: game) }
        }
        #endif
    }

    // MARK: - Layout

    private var background: some View {
        ZStack {
            if let focused {
                GameBackdrop(game: focused)
                RemoteImage(url: focused.hero, fallback: focused.header) { ArtworkPlaceholder(title: focused.name) }
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0.35), .init(color: .clear, location: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
                    .id(focused.appID)
                    .transition(.opacity)
            } else {
                Color.black
            }
        }
        .ignoresSafeArea()
    }

    private func info(for game: LibraryGame, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let logo = game.logo {
                RemoteImage(url: logo, contentMode: .fit, alignment: .bottomLeading) { title(game) }
                    .frame(maxWidth: compact ? 260 : 380, maxHeight: compact ? 70 : 110, alignment: .leading)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
            } else {
                title(game)
            }
            Text(statusLine(game))
                .font(compact ? .subheadline : .title3)
                .foregroundStyle(.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 4)
            if case let .downloading(progress) = games.status(for: game.appID) {
                GlassProgressBar(fraction: progress.fraction, tint: .blue).frame(maxWidth: 360)
            }
        }
        .padding(.horizontal, 32)
        .id(game.appID)
        .transition(.opacity)
    }

    private func title(_ game: LibraryGame) -> some View {
        Text(game.name)
            .font(.largeTitle.weight(.heavy))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
    }

    private func statusLine(_ game: LibraryGame) -> String {
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

    private var filterTabs: some View {
        HStack(spacing: 14) {
            Image(systemName: pad.symbol(for: .leftShoulder)).foregroundStyle(.secondary)
            ForEach(LibraryFilter.allCases) { tab in
                Text(tab.rawValue)
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(tab == filter ? .white : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(tab == filter ? .regular.tint(.white.opacity(0.2)) : .identity, in: .capsule)
            }
            Image(systemName: pad.symbol(for: .rightShoulder)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }

    private func shelfRow(height: CGFloat) -> some View {
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(Array(shelf.enumerated()), id: \.element.appID) { index, game in
                        CapsuleCard(game: game, status: games.status(for: game.appID))
                            .frame(width: height * 2 / 3)
                            .scaleEffect(index == selection ? 1.08 : 0.94)
                            .overlay {
                                if index == selection {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(.white, lineWidth: 3)
                                        .padding(.bottom, 22)
                                        .scaleEffect(1.08)
                                }
                            }
                            .opacity(index == selection ? 1 : 0.75)
                            .id(game.appID)
                            .onTapGesture {
                                selection = index
                                activate()
                            }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 14)
            }
            .scrollIndicators(.hidden)
            .frame(height: height + 50)
            .onChange(of: selection) { _, index in
                guard shelf.indices.contains(index) else { return }
                withAnimation(.smooth) { reader.scrollTo(shelf[index].appID, anchor: .center) }
            }
        }
    }

    private var hintBar: some View {
        HStack(spacing: 22) {
            hint(.a, primaryLabel)
            hint(.x, secondaryLabel)
            hint(.y, "More")
            hint(.menu, "Settings")
            Spacer(minLength: 0)
            if let name = pad.controllerName {
                Label(name, systemImage: "gamecontroller.fill")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 32)
        // Too narrow for every hint on one line (an iPhone held upright): let it scroll.
        .viewThatFitsWrapper()
    }

    private func hint(_ action: PadAction, _ label: String?) -> some View {
        Group {
            if let label {
                Label(label, systemImage: pad.symbol(for: action))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var primaryLabel: String? {
        guard let focused else { return nil }
        switch games.status(for: focused.appID) {
        case .installed: return games.playBlocker(appID: focused.appID) == nil ? "Play" : "Details"
        case .notInstalled: return "Download"
        default: return "Details"
        }
    }

    private var secondaryLabel: String? {
        guard let focused else { return nil }
        switch games.status(for: focused.appID) {
        case .notInstalled: return "Download"
        case .queued, .preparing, .downloading: return "Pause"
        case .paused, .failed: return "Resume"
        default: return nil
        }
    }

    // MARK: - Input

    private func handle(_ action: PadAction) {
        if detail != nil {
            if action == .b { detail = nil }
            return
        }
        if let menu {
            menu.handle(action, close: { self.menu = nil })
            pad.tick()
            return
        }
        switch action {
        case .left:
            if selection > 0 { selection -= 1; pad.tick() }
        case .right:
            if selection < shelf.count - 1 { selection += 1; pad.tick() }
        case .leftShoulder:
            cycleFilter(-1)
        case .rightShoulder:
            cycleFilter(1)
        case .a:
            pad.tick(strong: true)
            activate()
        case .x:
            toggleDownload()
        case .y:
            if let focused { menu = actionsMenu(for: focused) }
        case .menu:
            menu = settingsMenu()
        case .b, .up, .down:
            break
        }
    }

    private func cycleFilter(_ step: Int) {
        let all = LibraryFilter.allCases
        guard let index = all.firstIndex(of: filter) else { return }
        filter = all[(index + step + all.count) % all.count]
        pad.tick()
    }

    private func activate() {
        guard let focused else { return }
        switch games.status(for: focused.appID) {
        case .installed where games.playBlocker(appID: focused.appID) == nil:
            games.play(appID: focused.appID)
        case .notInstalled:
            if steam.isLoggedOn { games.download(focused) }
        default:
            detail = focused
        }
    }

    private func toggleDownload() {
        guard let focused else { return }
        switch games.status(for: focused.appID) {
        case .notInstalled: if steam.isLoggedOn { games.download(focused) }
        case .queued, .preparing, .downloading: games.pause(appID: focused.appID)
        case .paused, .failed: if steam.isLoggedOn { games.resume(appID: focused.appID, name: focused.name) }
        default: return
        }
        pad.tick(strong: true)
    }

    // MARK: - Menus

    private func actionsMenu(for game: LibraryGame) -> LauncherMenu {
        var items: [LauncherMenu.Item] = []
        let status = games.status(for: game.appID)
        if case .installed = status {
            if games.playBlocker(appID: game.appID) == nil {
                items.append(.init("Play", "play.fill") { games.play(appID: game.appID) })
            }
            items.append(.init("Verify Files", "checkmark.shield") { games.verify(appID: game.appID) })
            items.append(.init("Sync Saves", "arrow.triangle.2.circlepath") {
                Task { await games.syncAllSaveLocations(appID: game.appID) }
            })
        }
        if let label = secondaryLabel {
            items.append(.init(label, label == "Pause" ? "pause.fill" : "arrow.down.circle") { toggleDownload() })
        }
        items.append(.init("Details", "info.circle") { detail = game })
        if status != .notInstalled {
            items.append(.init("Delete…", "trash", destructive: true) {
                menu = LauncherMenu(title: "Delete \(game.name)?", subtitle: "Its patches and saves are deleted too.", items: [
                    .init("Delete", "trash", destructive: true) { games.delete(appID: game.appID, name: game.name) },
                    .init("Cancel", "xmark") {},
                ])
            })
        }
        return LauncherMenu(title: game.name, subtitle: nil, items: items)
    }

    private func settingsMenu() -> LauncherMenu {
        LauncherMenu(title: "Settings", subtitle: steam.accountName.map { "Signed in as \($0)" }, items: [
            .init(SteamCloudSync.uploadsEnabled ? "Steam Cloud uploads: On" : "Steam Cloud uploads: Off", "cloud") {
                SteamCloudSync.uploadsEnabled.toggle()
            },
            .init("Sync All Saves", "arrow.triangle.2.circlepath") {
                Task {
                    for game in steam.library where games.isOnDevice(game.appID) {
                        await games.syncAllSaveLocations(appID: game.appID)
                    }
                }
            },
            .init("Refresh Library", "arrow.clockwise") { Task { await steam.loadLibrary() } },
            .init("Sign Out…", "rectangle.portrait.and.arrow.right", destructive: true) {
                menu = LauncherMenu(title: "Sign out of Steam?", subtitle: "Downloaded games stay on this device.", items: [
                    .init("Sign Out", "rectangle.portrait.and.arrow.right", destructive: true) { Task { await steam.signOut() } },
                    .init("Cancel", "xmark") {},
                ])
            },
        ])
    }
}

/// A list of actions navigated with the D-pad: A chooses, B closes.
@Observable
final class LauncherMenu: Identifiable {
    struct Item: Identifiable {
        let id = UUID()
        var title: String
        var systemImage: String
        var destructive = false
        var action: () -> Void

        init(_ title: String, _ systemImage: String, destructive: Bool = false, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.destructive = destructive
            self.action = action
        }
    }

    let id = UUID()
    let title: String
    let subtitle: String?
    let items: [Item]
    var selection = 0

    init(title: String, subtitle: String?, items: [Item]) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
    }

    /// Runs the chosen item after closing, so an item can open a follow-up menu.
    @MainActor func handle(_ action: PadAction, close: () -> Void) {
        switch action {
        case .up: selection = max(0, selection - 1)
        case .down: selection = min(items.count - 1, selection + 1)
        case .b: close()
        case .a:
            let item = items[selection]
            close()
            item.action()
        default: break
        }
    }
}

private struct LauncherMenuView: View {
    let menu: LauncherMenu
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 6) {
                Text(menu.title).font(.title2.weight(.bold))
                if let subtitle = menu.subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                        Label(item.title, systemImage: item.systemImage)
                            .font(.headline)
                            .foregroundStyle(item.destructive ? .red : .white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background {
                                if index == menu.selection {
                                    RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.18))
                                }
                            }
                            .contentShape(.rect)
                            .onTapGesture {
                                menu.selection = index
                                menu.handle(.a, close: close)
                            }
                    }
                }
                .padding(.top, 8)
            }
            .padding(22)
            .frame(maxWidth: 420)
            .glassEffect(.regular, in: .rect(cornerRadius: 26))
            .padding()
        }
    }
}

private extension View {
    func viewThatFitsWrapper() -> some View {
        ViewThatFits(in: .horizontal) {
            self
            ScrollView(.horizontal) { self }.scrollIndicators(.hidden)
        }
    }
}
