import Kingfisher
import SteamKit
import SwiftUI

/// The owned-games grid: capsule art, filters, search, downloads and settings.
struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case visualNovels = "Visual Novels"
        case installed = "Installed"
        var id: Self { self }
    }

    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("libraryFilter") private var filter: Filter = .visualNovels
    @State private var query = ""
    @State private var path: [LibraryGame] = []
    @State private var showingDownloads = false
    @State private var showingSettings = false
    @State private var showingAddGame = false

    private var filteredGames: [LibraryGame] {
        steam.library.filter { game in
            switch filter {
            case .visualNovels: curation.isVisualNovel(game)
            case .installed: games.status(for: game.appID) != .notInstalled
            }
        }
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.appID) == query }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 104), spacing: 14, alignment: .top)]
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // In the scrolling content, under the large title, so it never covers it.
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                if let error = steam.libraryError {
                    Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredGames) { game in
                        NavigationLink(value: game) {
                            CapsuleCard(game: game, status: games.status(for: game.appID))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(curation.isVisualNovel(game) ? "Remove from Visual Novels" : "Add to Visual Novels",
                                   systemImage: curation.isVisualNovel(game) ? "eye.slash" : "plus.circle") {
                                withAnimation { curation.toggle(game) }
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .overlay { placeholder }
            .searchable(text: $query, prompt: "Search your library")
            .refreshable { await steam.loadLibrary() }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            #if DEBUG
            // `-ShioriOpenGame <appid>` opens that game's screen once the library loads.
            .task(id: steam.library.count) {
                let appID = UserDefaults.standard.integer(forKey: "ShioriOpenGame")
                if path.isEmpty, let game = steam.library.first(where: { $0.appID == appID }) { path = [game] }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingAddGame = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a game to Visual Novels")
                    Button {
                        showingDownloads = true
                    } label: {
                        Image(systemName: games.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .symbolEffect(.pulse, isActive: games.isDownloading)
                    }
                    .countBadge(games.downloadItems.count)
                    .accessibilityLabel("Downloads")
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingDownloads) { DownloadsView(library: steam.library) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingAddGame) { AddVisualNovelView() }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if filteredGames.isEmpty {
            if steam.isLoadingLibrary, steam.library.isEmpty {
                ProgressView("Loading library…")
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if filter == .installed {
                ContentUnavailableView("Nothing downloaded yet", systemImage: "arrow.down.circle",
                                       description: Text("Open a game and tap Download."))
            } else if filter == .visualNovels, !steam.library.isEmpty {
                ContentUnavailableView("No visual novels", systemImage: "books.vertical",
                                       description: Text("None of your games has Steam's Visual Novel tag. Tap + to add games."))
            } else if steam.isLoggedOn, steam.libraryError == nil {
                ContentUnavailableView("No games", systemImage: "books.vertical")
            }
        }
    }
}

/// A portrait capsule with the game's download state over it.
struct CapsuleCard: View {
    let game: LibraryGame
    let status: GameLibrary.Status
    @Environment(EngineScanStore.self) private var engineScans

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsuleArt(game: game)
                .overlay(alignment: .bottom) { statusOverlay }
                .overlay(alignment: .topLeading) { engineBadge }
                .clipShape(.rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(game.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.primary)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }

    /// Before download: what the game runs on, from its manifests. Green when playable.
    @ViewBuilder private var engineBadge: some View {
        if status == .notInstalled, let scan = engineScans.result(for: game.appID), scan.error == nil {
            let playable = Playability(scan.engine) == .playable
            Text(Playability.badge(scan.engine))
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(playable ? Color.green.opacity(0.85) : Color.black.opacity(0.6), in: .capsule)
                .padding(6)
                .accessibilityLabel(playable ? "Playable, \(Playability.badge(scan.engine))" : Playability.badge(scan.engine))
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        switch status {
        case .installed:
            HStack {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .font(.title3)
                    .padding(6)
                    .accessibilityLabel("Downloaded")
            }
        case let .downloading(progress):
            ProgressView(value: progress.fraction)
                .tint(.white)
                .padding(8)
                .background(.black.opacity(0.45))
        case .preparing, .queued, .verifying:
            HStack {
                Spacer()
                Image(systemName: status == .queued ? "clock.fill" : "ellipsis.circle.fill")
                    .foregroundStyle(.white).font(.title3).padding(6)
            }
        case .paused:
            HStack {
                Spacer()
                Image(systemName: "pause.circle.fill").foregroundStyle(.white).font(.title3).padding(6)
                    .accessibilityLabel("Download paused")
            }
        case .failed:
            HStack {
                Spacer()
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white, .red).font(.title3).padding(6)
            }
        case .notInstalled:
            EmptyView()
        }
    }
}

/// 600×900 library art, falling back to the landscape header, then to the name.
struct CapsuleArt: View {
    let game: LibraryGame

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                // Decoded at grid size, cached in memory and on disk (Kingfisher).
                KFImage(game.capsule)
                    .placeholder { Rectangle().fill(.fill.tertiary) }
                    .onFailureView { fallback }
                    .downsampling(size: CGSize(width: 400, height: 600))
                    .cacheOriginalImage()
                    .cancelOnDisappear(true)
                    .fade(duration: 0.2)
                    .resizable()
                    .scaledToFill()
            }
            .clipped()
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                KFImage(game.header)
                    .placeholder { EmptyView() }
                    .onFailureView { EmptyView() }
                    .downsampling(size: CGSize(width: 460, height: 215))
                    .resizable()
                    .scaledToFit()
                Text(game.name)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
            }
        }
    }
}

struct ConnectionStatus: View {
    @Environment(SteamModel.self) private var steam
    @State private var explaining = false

    var body: some View {
        // Nothing while connected. When Steam can't be reached, a single icon that explains
        // what still works, since downloads and Steam Cloud quietly wait until it's back.
        switch steam.state {
        case .loggedOn, .connecting, .connectedAnonymously:
            EmptyView()
        case .reconnecting, .signedOut:
            Button { explaining = true } label: {
                Image(systemName: "wifi.slash")
                    .symbolEffect(.pulse, isActive: isReconnecting)
            }
            .accessibilityLabel(isReconnecting ? "Reconnecting to Steam" : "Offline")
            .infoPopover(isPresented: $explaining) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isReconnecting ? "Reconnecting to Steam…" : "Can't reach Steam").font(.headline)
                    Text("Downloaded games still play. Downloads and Steam Cloud saves wait until Steam is back.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .frame(idealWidth: 280)
                .presentationCompactAdaptation(.popover)
            }
        }
    }

    private var isReconnecting: Bool {
        if case .reconnecting = steam.state { return true }
        return false
    }
}

/// Owned games that aren't in the Visual Novels tab, to add by hand.
struct AddVisualNovelView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var candidates: [LibraryGame] {
        steam.library
            .filter { !curation.isVisualNovel($0) }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { game in
                Button {
                    withAnimation { curation.add(game) }
                } label: {
                    HStack(spacing: 12) {
                        CapsuleArt(game: game)
                            .frame(width: 36)
                            .clipShape(.rect(cornerRadius: 4))
                        Text(game.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(.tint)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .alwaysSearchable(text: $query, prompt: "Your Steam games")
            .navigationTitle("Add to Visual Novels")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
