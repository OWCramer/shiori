import SwiftUI

/// Nothing while Steam is connected, or while it's reconnecting as it does after every trip
/// to the background. Once a reconnect has failed past its grace period (`SteamModel
/// .showsOffline`), a single icon that explains what still works, since downloads and
/// Steam Cloud quietly wait until Steam is back.
struct ConnectionStatus: View {
    @Environment(SteamModel.self) private var steam
    @State private var explaining = false

    var body: some View {
        if steam.showsOffline {
            Button(action: explain) {
                Label("Can't Reach Steam", systemImage: "wifi.slash")
                    .labelStyle(.iconOnly)
                    .symbolEffect(.pulse, isActive: isRetrying)
            }
            .infoPopover(isPresented: $explaining) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Can't reach Steam").font(.headline)
                    Text(isRetrying
                         ? "Shiori keeps trying. Downloaded games still play; downloads and Steam Cloud saves wait until Steam is back."
                         : "Downloaded games still play; downloads and Steam Cloud saves wait until Steam is back.")
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

    private var isRetrying: Bool {
        switch steam.state {
        case .reconnecting, .connecting: true
        default: false
        }
    }

    private func explain() { explaining = true }
}
