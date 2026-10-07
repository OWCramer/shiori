import SteamKit
import SwiftUI

struct LibraryView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @State private var query = ""
    @State private var path: [AppInfo] = []

    private var filteredGames: [AppInfo] {
        guard !query.isEmpty else { return steam.library }
        return steam.library.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.appID) == query }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error = steam.libraryError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ForEach(filteredGames) { game in
                        NavigationLink(value: game) {
                            HStack {
                                Text(game.name)
                                Spacer()
                                InstallBadge(status: games.status(for: game.appID))
                                Text(String(game.appID))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    if !steam.library.isEmpty { Text("\(steam.library.count) games") }
                }
            }
            .navigationDestination(for: AppInfo.self) { GameDetailView(app: $0) }
            #if DEBUG
            // `-VNHubOpenGame <appid>` opens that game's screen once the library loads.
            .task(id: steam.library.count) {
                let appID = UserDefaults.standard.integer(forKey: "VNHubOpenGame")
                if path.isEmpty, let app = steam.library.first(where: { $0.appID == appID }) { path = [app] }
            }
            #endif
            .overlay { placeholder }
            .searchable(text: $query, prompt: "Name or app ID")
            .refreshable { await steam.loadLibrary() }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionStatus() }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if let name = steam.accountName { Text("Signed in as \(name)") }
                        Button("Sign out", role: .destructive) { Task { await steam.signOut() } }
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        if steam.library.isEmpty {
            if steam.isLoadingLibrary {
                ProgressView("Loading library…")
            } else if steam.isLoggedOn, steam.libraryError == nil {
                ContentUnavailableView("No games", systemImage: "books.vertical")
            }
        }
    }
}

private struct ConnectionStatus: View {
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

private struct InstallBadge: View {
    let status: GameLibrary.Status

    var body: some View {
        switch status {
        case .installed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        case let .downloading(progress):
            Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit()).foregroundStyle(.tint)
        case .preparing, .verifying:
            ProgressView().controlSize(.mini)
        case .paused:
            Image(systemName: "pause.circle").foregroundStyle(.secondary)
                .accessibilityLabel("Download paused")
        case .failed:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        case .notInstalled:
            EmptyView()
        }
    }
}
