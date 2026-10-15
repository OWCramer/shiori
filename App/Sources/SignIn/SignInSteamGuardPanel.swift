// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SteamKit
import SwiftUI

/// Steam Guard: approve the sign-in in the Steam app (waiting for it), confirm the email
/// Steam sent, and/or type a code.
struct SignInSteamGuardPanel: View {
    let prompt: SignInStep.Guard
    @Environment(SteamModel.self) private var steam
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var canSubmit: Bool { code.count >= 5 && !prompt.isSubmittingCode }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Steam Guard", systemImage: "lock.shield.fill")
                .font(.title2)
                .bold()
            if prompt.approveInApp {
                SignInWaitingRow(title: "Approve in the Steam app",
                                 detail: "Tap Approve on the sign-in request in the Steam app.")
            }
            if prompt.confirmByEmail {
                SignInWaitingRow(title: "Check your email",
                                 detail: "Steam sent a confirmation link\(prompt.emailHint.map { " to your \($0) address" } ?? ""). Open it to finish.")
            }
            if let kind = prompt.code {
                VStack(alignment: .leading, spacing: 10) {
                    Text(codeHeading(kind)).font(.headline).fixedSize(horizontal: false, vertical: true)
                    TextField("Code", text: $code)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.title.monospaced())
                        .multilineTextAlignment(.center)
                        .focused($codeFocused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .padding(12)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 14))
                        .accessibilityLabel("Steam Guard code")
                    if let error = prompt.codeError {
                        SignInMessage(text: error, systemImage: "exclamationmark.triangle.fill")
                    }
                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if prompt.isSubmittingCode { ProgressView() }
                            Text(prompt.isSubmittingCode ? "Checking…" : "Submit Code").bold()
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .tint(Color(red: 0.80, green: 0.18, blue: 0.22))
                    .disabled(!canSubmit)
                }
            }
            Button("Cancel", role: .cancel, action: cancel)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
    }

    private func codeHeading(_ kind: SteamGuardPrompt.CodeKind) -> String {
        switch kind {
        case .authenticator: prompt.approveInApp ? "Or enter the code from Steam Guard in the Steam app" : "Enter the code from Steam Guard in the Steam app"
        case .email: "Enter the code Steam emailed\(prompt.emailHint.map { " to your \($0) address" } ?? " you")"
        }
    }

    private func submit() {
        guard canSubmit else { return }
        steam.submitSteamGuardCode(code)
        code = ""
    }

    private func cancel() {
        code = ""
        steam.cancelSignIn()
    }
}

/// Something Steam is waiting for, elsewhere: a spinner, what to do, and how.
private struct SignInWaitingRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ProgressView().padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
#endif
