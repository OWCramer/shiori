import CoreImage.CIFilterBuiltins
import SteamKit
import SwiftUI

struct SignInView: View {
    @Environment(SteamModel.self) private var steam
    @State private var accountName = ""
    @State private var password = ""
    @State private var code = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Shiori")
                        .font(.largeTitle.bold())
                    Text("Sign in to Steam to see your library.")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 48)

                if let error = steam.resumeError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }

                content
            }
            .frame(maxWidth: 400)
            .padding()
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private var content: some View {
        switch steam.signIn {
        case .idle:
            credentialsForm(error: nil)

        case let .failed(message):
            credentialsForm(error: message)

        case .working:
            ProgressView("Contacting Steam…")

        case let .steamGuard(prompt, codeError, isSubmittingCode):
            steamGuard(prompt, codeError: codeError, isSubmittingCode: isSubmittingCode)

        case let .qr(url, scanned):
            VStack(spacing: 16) {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 240, height: 240)
                    .accessibilityLabel("Steam sign-in QR code")
                Text(scanned
                    ? "Approve the sign-in in the Steam app."
                    : "In the Steam app on another device, open Steam Guard and scan this code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel", role: .cancel) { steam.cancelSignIn() }
            }
        }
    }

    private func credentialsForm(error: String?) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 0) {
                TextField("Steam account name", text: $accountName)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                Divider()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(12)
                    .onSubmit(submitCredentials)
            }
            .background(.fill.tertiary, in: .rect(cornerRadius: 12))

            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            Button(action: submitCredentials) {
                Text("Sign in").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(accountName.isEmpty || password.isEmpty)

            Text("Your password goes straight to Steam, encrypted, and is never saved. Approve the sign-in in the Steam app or enter your Steam Guard code.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Sign in with a QR code instead") { steam.startQRSignIn() }
                .font(.callout)
        }
    }

    private func submitCredentials() {
        guard !accountName.isEmpty, !password.isEmpty else { return }
        steam.signIn(accountName: accountName, password: password)
        password = ""
    }

    private func steamGuard(_ prompt: SteamGuardPrompt, codeError: String?, isSubmittingCode: Bool) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tint)

            if prompt.canApproveInSteamApp {
                Text("Open the Steam app and approve the sign-in request, then come back here.")
                    .multilineTextAlignment(.center)
            }
            if prompt.canConfirmByEmail {
                Text("Or click the confirmation link Steam emailed you.")
                    .multilineTextAlignment(.center)
            }

            if let kind = prompt.code {
                Text(kind == .authenticator
                    ? (prompt.canApproveInSteamApp ? "Or enter the code from Steam Guard in the Steam app:" : "Enter the code from Steam Guard in the Steam app:")
                    : "Enter the code Steam emailed\(prompt.emailHint.map { " to your \($0) address" } ?? " you"):")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack {
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title2.monospaced())
                        .multilineTextAlignment(.center)
                        .padding(10)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 10))
                        .onSubmit { submitCode() }
                    Button("Submit") { submitCode() }
                        .buttonStyle(.borderedProminent)
                        .disabled(code.count < 5 || isSubmittingCode)
                }
                if let codeError {
                    Text(codeError).foregroundStyle(.red).font(.callout)
                }
            }

            ProgressView().padding(.top, 8)
            Button("Cancel", role: .cancel) {
                code = ""
                steam.cancelSignIn()
            }
        }
    }

    private func submitCode() {
        guard code.count >= 5 else { return }
        steam.submitSteamGuardCode(code)
        code = ""
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 12))
        }
    }

    private static func render(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
