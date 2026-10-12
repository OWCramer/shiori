#if os(iOS)
import SteamKit
import SwiftUI

/// The download under way, large over the game's banner: its logo, how far it has got,
/// the pace and time left, and Pause. Tapping the art opens the game's page.
struct ActiveDownloadCard: View {
    let game: LibraryGame
    @Environment(GameLibrary.self) private var games
    @State private var rate = DownloadRate()

    private var progress: DownloadProgress? {
        if case let .downloading(progress) = games.status(for: game.appID) { progress } else { nil }
    }

    var body: some View {
        let progress = progress
        NavigationLink(value: game) {
            VStack(alignment: .leading, spacing: 14) {
                GameLogo(game: game, maxWidth: 240, maxHeight: 80, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 32)
                HStack(alignment: .lastTextBaseline) {
                    if let progress {
                        Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.largeTitle)
                            .bold()
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    } else {
                        Text("Preparing…").font(.title2).bold()
                    }
                    Spacer()
                    if let progress { DownloadPace(rate: rate, progress: progress) }
                }
                GlassProgressBar(fraction: progress?.fraction ?? 0, tint: .white)
                if let progress {
                    Text(progress.phase == .finishing ? "Finishing…" :
                            "\(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .padding(.bottom, 44)
            .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
            .background {
                HeroArtwork(game: game)
                    .overlay {
                        LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    }
            }
            .clipShape(.rect(cornerRadius: 28))
            .contentShape(.rect(cornerRadius: 28))
        }
        .buttonStyle(.plain)
        // Outside the link's label, so it takes its own taps.
        .overlay(alignment: .bottomTrailing) {
            Button("Pause", systemImage: "pause.fill", action: pause)
                .buttonStyle(.glass)
                .controlSize(.large)
                .padding(16)
        }
        .accessibilityElement(children: .contain)
        .onChange(of: progress?.completedBytes) { _, bytes in
            if let bytes { rate.record(bytes) }
        }
    }

    private func pause() { games.pause(appID: game.appID) }
}
#endif
