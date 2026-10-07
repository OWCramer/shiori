import SteamKit
import SwiftUI

/// The owned-games grid: capsule art, filters, search, downloads and settings.
struct LibraryView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case visualNovels = "Visual Novels"
        case installed = "Installed"
        var id: Self { self }
    }

    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("libraryFilter") private var filter: Filter = .visualNovels
    @State private var query = ""
    @State private var path: [LibraryGame] = []
    @State private var showingDownloads = false
    @State private var showingSettings = false

    private var filteredGames: [LibraryGame] {
        steam.library.filter { game in
            switch filter {
            case .all: true
            case .visualNovels: game.isVisualNovel
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
                if let error = steam.libraryError {
                    Text(error).foregroundStyle(.red).font(.callout).padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(filteredGames) { game in
                        NavigationLink(value: game) {
                            CapsuleCard(game: game, status: games.status(for: game.appID))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
            .overlay { placeholder }
            .searchable(text: $query, prompt: "Search your library")
            .refreshable { await steam.loadLibrary() }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryGame.self) { GameDetailView(game: $0) }
            #if DEBUG
            // `-VNHubOpenGame <appid>` opens that game's screen once the library loads.
            .task(id: steam.library.count) {
                let appID = UserDefaults.standard.integer(forKey: "VNHubOpenGame")
                if path.isEmpty, let game = steam.library.first(where: { $0.appID == appID }) { path = [game] }
            }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingDownloads = true
                    } label: {
                        Image(systemName: games.isDownloading ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .symbolEffect(.pulse, isActive: games.isDownloading)
                    }
                    .badge(games.downloadItems.count)
                    .accessibilityLabel("Downloads")
                    Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingDownloads) { DownloadsView(library: steam.library) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
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
                                       description: Text("None of your games has Steam's Visual Novel tag. Switch to All."))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsuleArt(game: game)
                .overlay(alignment: .bottom) { statusOverlay }
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
                AsyncImage(url: game.capsule) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else if phase.error != nil {
                        fallback
                    } else {
                        Rectangle().fill(.fill.tertiary)
                    }
                }
            }
            .clipped()
    }

    private var fallback: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .purple.opacity(0.7)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                AsyncImage(url: game.header) { $0.resizable().scaledToFit() } placeholder: { EmptyView() }
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

    var body: some View {
        switch steam.state {
        case .loggedOn:
            Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
                .accessibilityLabel("Connected to Steam")
        case .connecting, .connectedAnonymously:
            ProgressView()
        case let .reconnecting(attempt):
            Label("Reconnecting (\(attempt))", systemImage: "wifi.exclamationmark")
                .labelStyle(.titleAndIcon).font(.caption)
        case .signedOut:
            Image(systemName: "circle").foregroundStyle(.secondary).font(.caption2)
        }
    }
}
