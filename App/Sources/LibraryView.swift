import SteamKit
import SwiftUI

struct LibraryView: View {
    @Environment(SteamModel.self) private var steam
    @State private var query = ""

    private var games: [AppInfo] {
        guard !query.isEmpty else { return steam.library }
        return steam.library.filter { $0.name.localizedCaseInsensitiveContains(query) || String($0.appID) == query }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error = steam.libraryError {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    ForEach(games) { game in
                        HStack {
                            Text(game.name)
                            Spacer()
                            Text(String(game.appID))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    if !steam.library.isEmpty { Text("\(steam.library.count) games") }
                }
            }
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
