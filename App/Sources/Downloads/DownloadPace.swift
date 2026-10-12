import SteamKit
import SwiftUI

/// "24.6 MB/s · About 3 minutes left", once there's enough to measure.
struct DownloadPace: View {
    let rate: DownloadRate
    let progress: DownloadProgress

    var body: some View {
        if let speed = rate.bytesPerSecond {
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int64(speed).formatted(.byteCount(style: .file)))/s")
                    .font(.headline.monospacedDigit())
                if let left = rate.timeLeft(remaining: progress.totalBytes - min(progress.completedBytes, progress.totalBytes)) {
                    Text("About \(Duration.seconds(left).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))) left")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
    }
}
