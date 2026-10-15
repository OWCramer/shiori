#if os(iOS)
import SwiftUI

/// The sign-in step in progress, on a plain card (content, so no Liquid Glass).
struct SignInStepCard: View {
    let step: SignInStep
    /// Switches to the account form.
    let useAccountName: () -> Void
    /// Switches to (or fetches a new) QR code.
    let useQR: () -> Void
    @Environment(SteamModel.self) private var steam

    private var expired: String? { SignInPreview.expiredMessage ?? steam.resumeError }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch step {
            case let .form(error):
                expiredMessage
                SignInCredentialsForm(error: error, useQR: useQR)
            case .working:
                SignInWorkingPanel()
            case let .steamGuard(prompt):
                SignInSteamGuardPanel(prompt: prompt)
            case let .qr(url, scanned):
                expiredMessage
                SignInQRPanel(url: url, scanned: scanned, useAccountName: useAccountName)
            case let .qrFailed(message):
                expiredMessage
                SignInQRFailedPanel(message: message, retry: useQR, useAccountName: useAccountName)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.07, green: 0.03, blue: 0.04).opacity(0.88), in: .rect(cornerRadius: 28))
        .overlay {
            RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.08))
        }
        .animation(.smooth, value: step)
    }

    @ViewBuilder private var expiredMessage: some View {
        if let expired { SignInMessage(text: expired, systemImage: "clock.badge.exclamationmark", tint: .orange) }
    }
}

/// A note in the card: an error, or the saved sign-in having expired.
struct SignInMessage: View {
    let text: String
    let systemImage: String
    var tint: Color = .red

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(tint)
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.14), in: .rect(cornerRadius: 14))
    }
}

/// Talking to Steam after Sign In.
private struct SignInWorkingPanel: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("Contacting Steam…").font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
#endif
