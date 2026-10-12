#if os(iOS)
import SwiftUI
import UIKit

/// What downloaded games take: the total, what's free, a bar with a segment per game, and
/// each game's size, largest first.
struct SettingsStorageSection: View {
    @Environment(GameLibrary.self) private var games

    /// How many games get a colour of their own in the bar; the rest share one.
    static let coloured = 6

    private var installed: [GameRecord] {
        games.statuses.values.compactMap { if case let .installed(record) = $0 { record } else { nil } }
            .sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private var freeSpace: Int64? {
        (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    var body: some View {
        let installed = installed
        let total = installed.reduce(0) { $0 + $1.sizeBytes }
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(total.formatted(.byteCount(style: .file)))
                        .font(.title)
                        .bold()
                    Text("in \(installed.count) game\(installed.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let freeSpace {
                        Text("\(freeSpace.formatted(.byteCount(style: .file))) free")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if total > 0 {
                    StorageBar(sizes: installed.map(\.sizeBytes), free: freeSpace.map { UInt64(max(0, $0)) })
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
            ForEach(Array(installed.prefix(Self.coloured).enumerated()), id: \.element.appID) { index, record in
                StorageGameRow(record: record, colour: StorageBar.colour(index))
            }
            let rest = Array(installed.dropFirst(Self.coloured))
            if !rest.isEmpty {
                DisclosureGroup {
                    ForEach(rest, id: \.appID) { record in
                        StorageGameRow(record: record, colour: .gray)
                    }
                } label: {
                    LabeledContent("\(rest.count) More Game\(rest.count == 1 ? "" : "s")",
                                   value: rest.reduce(0) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file)))
                }
            }
        } header: {
            Text("Storage on This \(UIDevice.current.localizedModel)")
        } footer: {
            Text("Downloaded games are kept out of iCloud device backups; they can always be downloaded again. Delete one from its page.")
        }
    }
}
#endif
