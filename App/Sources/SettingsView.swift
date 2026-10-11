import SwiftUI

/// Account and storage. Cloud-save toggles join in the cloud phases.
struct SettingsView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false
    @State private var signingInToDenpasoft = false

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

                #if !os(tvOS)
                Section {
                    Toggle("MetalFX upscaling", isOn: Binding(
                        get: { KiriKiriGameViewController.upscalingEnabled },
                        set: { KiriKiriGameViewController.upscalingEnabled = $0 }
                    ))
                } header: {
                    Text("Engines")
                } footer: {
                    Text("KiriKiri: games like NEKOPARA draw at 1280×720. MetalFX enlarges them to the screen with sharper edges and text; off, Shiori uses a smooth bicubic filter. Applies the next time a game starts.")
                }
                #endif

                #if os(iOS)
                DenpasoftSection(signingIn: $signingInToDenpasoft)
                #endif

                SteamGridDBKeySection()

                Section {
                    LabeledContent("Ren'Py runtime", value: RenPyEngine.runtimeVersion)
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                }
            }
            .navigationTitle("Settings")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #if os(iOS)
            // On the Form, not its row: a sheet attached to a Form row is dismissed as it appears.
            .sheet(isPresented: $signingInToDenpasoft) {
                DenpasoftWebSheet(url: DenpasoftAccount.account, title: "Sign In to Denpasoft")
            }
            #endif
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

#if os(iOS)
/// Settings › Denpasoft: the account Shiori downloads Denpasoft's patches with.
private struct DenpasoftSection: View {
    @Binding var signingIn: Bool
    private var account: DenpasoftAccount { .shared }

    var body: some View {
        Section {
            if account.isSignedIn {
                LabeledContent("Patches in your downloads") {
                    if account.isLoading { ProgressView() } else { Text("\(account.downloads.count)") }
                }
                Button("Refresh Downloads") { Task { await account.refresh(force: true) } }
                    .disabled(account.isLoading)
                Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
            } else {
                Button("Sign In to Denpasoft") { signingIn = true }
            }
        } header: {
            Text("Denpasoft")
        } footer: {
            Text("Many of Denpasoft's 18+ patches are free but need an account. Sign in on Denpasoft's own page; Shiori never sees your password, keeps the session on this device, and installs the patches in your Denpasoft downloads from each game's page.")
        }
        .task { if account.isSignedIn { await account.refresh() } }
    }
}
#endif
