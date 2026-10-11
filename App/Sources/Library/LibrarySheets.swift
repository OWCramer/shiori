import SwiftUI

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
