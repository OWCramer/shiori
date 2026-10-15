import SwiftUI

#if os(iOS)
/// Settings › Denpasoft: the account Shiori downloads Denpasoft's patches with.
struct DenpasoftSection: View {
    @Binding var signingIn: Bool
    private var account: DenpasoftAccount { .shared }

    var body: some View {
        Section {
            if account.isSignedIn {
                LabeledContent("Patches") {
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
            Text("For Denpasoft's 18+ patches. You sign in on Denpasoft's page; Shiori never sees your password.")
        }
        .task { if account.isSignedIn { await account.refresh() } }
    }
}
#endif
