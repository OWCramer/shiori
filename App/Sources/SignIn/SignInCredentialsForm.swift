#if os(iOS)
import SwiftUI

/// The Steam account name and password, Sign In, the promise about the password, and the
/// QR code as the other way in.
struct SignInCredentialsForm: View {
    let error: String?
    @Environment(SteamModel.self) private var steam
    @State private var accountName = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case account, password }

    private var canSubmit: Bool { !accountName.isEmpty && !password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Sign in to Steam").font(.title2).bold()
            VStack(spacing: 0) {
                TextField("Steam account name", text: $accountName)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .account)
                    .onSubmit { focus = .password }
                    .padding(14)
                Divider()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
                    .padding(14)
            }
            .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
            if let error {
                SignInMessage(text: error, systemImage: "exclamationmark.triangle.fill")
            }
            Button(action: submit) {
                Text("Sign In").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Color(red: 0.80, green: 0.18, blue: 0.22))
            .disabled(!canSubmit)
            Label("Your password goes only to Steam, encrypted, and is never saved.",
                  systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                Text("or").font(.footnote).foregroundStyle(.secondary)
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            }
            .accessibilityHidden(true)
            Button(action: startQR) {
                Label("Sign In with a QR Code", systemImage: "qrcode").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        steam.signIn(accountName: accountName, password: password)
        password = ""
    }

    private func startQR() { steam.startQRSignIn() }
}
#endif
