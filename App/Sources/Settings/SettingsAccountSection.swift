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
                let profile = steam.profile.info
                let name = profile?.personaName ?? steam.accountName ?? "Steam"
                SteamAvatar(url: profile?.avatar, name: name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.headline)
                    if let account = steam.accountName ?? (steam.hasStoredSession ? nil : "Not signed in") {
                        Text(profile != nil && account != name ? "Steam · \(account)" : "Steam")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(steam.library.count) games · \(visualNovels) visual novels")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            Button("Sign Out of Steam", role: .destructive, action: askToSignOut)
        } header: {
            Text("Account")
        } footer: {
            Text("Adult content follows your Steam store preferences.")
        }
        .confirmationDialog("Sign out of Steam?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive, action: signOut)
        } message: {
            Text("Also signs out your other devices. Downloaded games stay.")
        }
    }

    private func askToSignOut() { confirmingSignOut = true }

    private func signOut() {
        Task { await steam.signOut() }
        dismiss()
    }
}
#endif
