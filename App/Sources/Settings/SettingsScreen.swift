#if os(iOS)
import SwiftUI

/// Settings on iPhone and iPad (design A): the Steam account, storage with a bar of what
/// each game takes, saves, engines, Denpasoft, SteamGridDB, and about.
struct SettingsScreen: View {
    /// In the iPad's sidebar rather than a sheet: no Done button.
    var isTab = false
    @Environment(SteamModel.self) private var steam
    @Environment(\.dismiss) private var dismiss
    @State private var signingInToDenpasoft = false
    @State private var uploads = SteamCloudSync.uploadsEnabled
    @State private var metalFX = KiriKiriGameViewController.upscalingEnabled

    var body: some View {
        NavigationStack {
            Form {
                SettingsAccountSection()
                SettingsStorageSection()
                Section {
                    NavigationLink {
                        CollectionsScreen()
                    } label: {
                        Label("Collections", systemImage: "square.stack")
                    }
                } footer: {
                    Text("Series grouped in Visual Novels and Installed: rename, merge, hide or make your own.")
                }
                Section {
                    Toggle(isOn: $uploads) {
                        Label("Upload Saves to Steam Cloud", systemImage: "icloud.and.arrow.up")
                    }
                } header: {
                    Text("Saves")
                } footer: {
                    Text("Saves always download from Steam Cloud. With uploads on, saves made here go up when a game closes, replacing the PC's copy if it's older; Shiori keeps a backup of every cloud file it replaces. iCloud is set per game, on its page.")
                }
                Section {
                    Toggle(isOn: $metalFX) {
                        Label("MetalFX Upscaling", systemImage: "sparkles.tv")
                    }
                    LabeledContent("Ren'Py runtimes", value: RenPyEngine.runtimeVersion)
                } header: {
                    Text("Engines")
                } footer: {
                    Text("KiriKiri: games like NEKOPARA draw at 1280×720. MetalFX enlarges them to the screen with sharper edges and text; off, Shiori uses a smooth bicubic filter. Applies the next time a game starts.")
                }
                DenpasoftSection(signingIn: $signingInToDenpasoft)
                SteamGridDBKeySection()
                SettingsAboutSection()
            }
            .navigationTitle("Settings")
            .toolbar {
                if !isTab {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: close)
                    }
                }
            }
            // On the Form, not its row: a sheet attached to a Form row is dismissed as it appears.
            // Checked again when it closes, as well as live while it's open.
            .sheet(isPresented: $signingInToDenpasoft, onDismiss: checkDenpasoft) {
                DenpasoftWebSheet(url: DenpasoftAccount.account, title: "Sign In to Denpasoft")
            }
            .onChange(of: uploads) { _, on in SteamCloudSync.uploadsEnabled = on }
            .onChange(of: metalFX) { _, on in KiriKiriGameViewController.upscalingEnabled = on }
        }
    }

    private func close() { dismiss() }

    private func checkDenpasoft() {
        Task { await DenpasoftAccount.shared.checkSession() }
    }
}
#endif
