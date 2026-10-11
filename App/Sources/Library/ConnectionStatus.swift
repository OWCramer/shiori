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
                Label(isReconnecting ? "Reconnecting to Steam" : "Offline", systemImage: "wifi.slash")
                    .labelStyle(.iconOnly)
                    .symbolEffect(.pulse, isActive: isReconnecting)
            }
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
