#if os(iOS)
import SwiftUI

/// How far a patch job has got: bytes downloaded, checking, installing, or its error.
struct PatchJobProgress: View {
    let phase: PatchInstaller.Phase

    var body: some View {
        let _ = RenderProbe.hit("PatchJobProgress")
        switch phase {
        case let .downloading(written, total, part, parts):
            if total > 0 {
                GlassProgressBar(fraction: Double(written) / Double(max(total, written)), tint: .pink)
            }
            Text(bytes(written: written, total: total) + (parts > 1 ? " · part \(part) of \(parts)" : ""))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        case .checking:
            Text("Checking the download…").font(.footnote).foregroundStyle(.secondary)
        case let .installing(fraction):
            GlassProgressBar(fraction: fraction, tint: .pink)
            Text("Installing…").font(.footnote).foregroundStyle(.secondary)
        case let .failed(message):
            Text(message).font(.footnote).foregroundStyle(.red).lineLimit(3)
        }
    }

    private func bytes(written: Int64, total: Int64) -> String {
        total > 0 ? "\(written.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))"
                  : written.formatted(.byteCount(style: .file))
    }
}
#endif
