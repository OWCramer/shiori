#if os(iOS)
import SwiftUI

/// The game's entry in the public compatibility list, or an invitation to add one.
struct CompatibilitySection: View {
    let appID: UInt32
    @Environment(CompatibilityStore.self) private var compatibility

    var body: some View {
        GamePageSection(title: "Compatibility") {
            if let (entry, engine) = compatibility.entry(for: appID) {
                GamePageRow {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(entry.status.title, systemImage: entry.status.systemImage)
                            .font(.headline)
                            .foregroundStyle(entry.status.colour)
                        Text(source(entry, engine: engine))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let notes = entry.notes, !notes.isEmpty {
                    GamePageRow {
                        Text(notes).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let branch = entry.branch {
                    GamePageRow {
                        Label("Play the \(branch) beta (Steam Version).", systemImage: "arrow.triangle.branch")
                            .font(.subheadline)
                    }
                }
            } else {
                GamePageRow {
                    Text("Not in the compatibility list yet.").foregroundStyle(.secondary)
                }
            }
            GamePageRow {
                Link(destination: CompatibilityStore.repository) {
                    Label("Report on GitHub", systemImage: "square.and.pencil")
                }
            }
        }
    }

    /// "Ren'Py · tested 2026-10-08 · by Shiori".
    private func source(_ entry: CompatibilityStore.Entry, engine: String) -> String {
        var parts = [engine]
        if let tested = entry.tested { parts.append("tested \(tested)") }
        if let source = entry.source { parts.append(source == "shiori" ? "by Shiori" : "by \(source)") }
        return parts.joined(separator: " · ")
    }
}
#endif
