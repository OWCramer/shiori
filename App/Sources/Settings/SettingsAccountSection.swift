#if os(iOS)
import SwiftUI

/// Settings' first section: who's signed in to Steam, the library's size, and Sign Out.
struct SettingsAccountSection: View {
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingSignOut = false

    var body: some View {
        let visualNovels = steam.library.filter { curation.isVisualNovel($0) }.count
        Section {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue.gradient)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(steam.accountName ?? "Not signed in").font(.headline)
                    Text("Steam · \(steam.library.count) games · \(visualNovels) visual novels")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            Button("Sign Out of Steam", role: .destructive, action: askToSignOut)
        } header: {
            Text("Account")
        }
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive, action: signOut)
        } message: {
            Text("Signs out on all your devices that share this sign-in through iCloud Keychain. Downloaded games stay on this device.")
        }
    }

    private func askToSignOut() { confirmingSignOut = true }

    private func signOut() {
        Task { await steam.signOut() }
        dismiss()
    }
}
#endif
