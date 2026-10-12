#if os(iOS)
import SwiftUI

/// A patch from the patch list downloading or installing (`PatchInstaller`), with Cancel,
/// or what went wrong, with Dismiss.
struct PatchJobRow: View {
    let game: LibraryGame
    let job: PatchInstaller.Job
    @Environment(PatchInstaller.self) private var patches

    private var isFailed: Bool { if case .failed = job.phase { true } else { false } }

    var body: some View {
        GamePageRow {
            HStack(spacing: 12) {
                CapsuleArt(game: game)
                    .frame(width: 44)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.name).font(.headline).lineLimit(1)
                    Text(game.name).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    PatchJobProgress(phase: job.phase)
                }
                Spacer(minLength: 0)
                Button(isFailed ? "Dismiss" : "Cancel", systemImage: "xmark.circle.fill", action: stopOrDismiss)
                    .labelStyle(.iconOnly)
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: ShowcaseMetrics.minimumTap, minHeight: ShowcaseMetrics.minimumTap)
            }
        }
    }

    private func stopOrDismiss() {
        if isFailed { patches.dismissFailure(appID: game.appID) } else { patches.cancel(appID: game.appID) }
    }
}
#endif
