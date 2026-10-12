import SwiftUI

#if os(iOS)
/// Settings › Denpasoft: the account Shiori downloads Denpasoft's patches with.
struct DenpasoftSection: View {
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
