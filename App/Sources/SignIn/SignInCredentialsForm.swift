#if os(iOS)
import SwiftUI

/// The Steam account name and password (then Steam Guard), for anyone without a second
/// device to scan the QR code with: Sign In, the promise about the password, and Use QR
/// Code back to the main way in.
struct SignInCredentialsForm: View {
    let error: String?
    let useQR: () -> Void
    @Environment(SteamModel.self) private var steam
    @State private var accountName = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case account, password }

    private var canSubmit: Bool { !accountName.isEmpty && !password.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sign In to Steam", systemImage: "person.text.rectangle")
                .font(.title2)
                .bold()
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
            Button(action: useQR) {
                Label("Use QR Code", systemImage: "qrcode").frame(maxWidth: .infinity)
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
}
#endif
