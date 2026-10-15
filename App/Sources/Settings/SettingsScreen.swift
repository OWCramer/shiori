#if os(iOS)
import SwiftUI

/// Settings on iPhone and iPad (design A): the Steam account, storage with a bar of what
/// each game takes, saves, engines, SteamGridDB, and about.
struct SettingsScreen: View {
    /// In the iPad's sidebar rather than a sheet: no Done button.
    var isTab = false
    @Environment(SteamModel.self) private var steam
    @Environment(\.dismiss) private var dismiss
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
                }
                Section {
                    Toggle(isOn: $uploads) {
                        Label("Upload Saves to Steam Cloud", systemImage: "icloud.and.arrow.up")
                    }
                } header: {
                    Text("Saves")
                } footer: {
                    Text("Saves upload when a game closes and replace older copies in Steam Cloud, which Shiori backs up first.")
                }
                Section {
                    Toggle(isOn: $metalFX) {
                        Label("MetalFX Upscaling", systemImage: "sparkles.tv")
                    }
                    LabeledContent("Ren'Py Versions", value: RenPyEngine.runtimeVersion)
                } header: {
                    Text("Engines")
                } footer: {
                    Text("Sharpens KiriKiri games drawn at 720p. Applies the next time a game starts.")
                }
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
            .onChange(of: uploads) { _, on in SteamCloudSync.uploadsEnabled = on }
            .onChange(of: metalFX) { _, on in KiriKiriGameViewController.upscalingEnabled = on }
        }
    }

    private func close() { dismiss() }
}
#endif
