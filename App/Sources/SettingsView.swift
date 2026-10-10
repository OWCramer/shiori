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
        #if os(tvOS)
        (try? URL.cachesDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #else
        (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
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
                    #if os(tvOS)
                    Text("tvOS may clear downloaded games when it needs space; Shiori downloads them again. Saves sync off this Apple TV.")
                    #else
                    Text("Downloaded games are kept out of iCloud device backups; they can always be downloaded again.")
                    #endif
                }

                Section {
                    Toggle("Upload saves to Steam Cloud", isOn: Binding(
                        get: { SteamCloudSync.uploadsEnabled },
                        set: { SteamCloudSync.uploadsEnabled = $0 }
                    ))
                } header: {
                    Text("Steam Cloud")
                } footer: {
                    Text("Saves always download from Steam Cloud. With uploads on, saves made here go up when a game closes, replacing the PC's copy if it's older; Shiori keeps a backup of every cloud file it replaces.")
                }

                SteamGridDBKeySection()

                Section {
                    LabeledContent("Ren'Py runtime", value: RenPyEngine.runtimeVersion)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of Steam?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    Task { await steam.signOut() }
                    dismiss()
                }
            } message: {
                Text("Signs out on all your devices that share this sign-in through iCloud Keychain. Downloaded games stay on this device.")
            }
        }
    }
}
