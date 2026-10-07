import SwiftUI

/// Account and storage. Cloud-save toggles join in the cloud phases.
struct SettingsView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    private var installed: [GameRecord] {
        games.statuses.values.compactMap { if case let .installed(record) = $0 { record } else { nil } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var freeSpace: Int64? {
        (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Steam account") {
                    if let name = steam.accountName {
                        LabeledContent("Signed in as", value: name)
                    }
                    LabeledContent("Games in library", value: "\(steam.library.count)")
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                }

                Section {
                    ForEach(installed, id: \.appID) { record in
                        LabeledContent(record.name, value: record.sizeBytes.formatted(.byteCount(style: .file)))
                    }
                    LabeledContent("Total", value: installed.reduce(0) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file)))
                        .bold()
                    if let freeSpace {
                        LabeledContent("Free on this \(UIDevice.current.localizedModel)", value: freeSpace.formatted(.byteCount(style: .file)))
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Downloaded games are kept out of iCloud device backups; they can always be downloaded again.")
                }

                Section {
                    LabeledContent("Ren'Py runtime", value: RenPyEngine.runtimeVersion)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Steam?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await steam.signOut() }
                    dismiss()
                }
            } message: {
                Text("Downloaded games stay on this device. You'll need to sign in again to download more.")
            }
        }
    }
}
