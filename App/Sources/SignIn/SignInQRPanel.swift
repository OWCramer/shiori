#if os(iOS)
import SwiftUI

/// The QR code, the main way in: approved with the Steam app on another device, with the
/// steps, the state once it's scanned, and Use Account Name for anyone with only this device.
struct SignInQRPanel: View {
    /// Nil while Steam sends the code.
    let url: URL?
    let scanned: Bool
    let useAccountName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SignInQRTitle()
            code
                .frame(maxWidth: .infinity)
            if scanned {
                Label("Scanned. Approve the sign-in in the Steam app.", systemImage: "hand.tap")
                    .font(.headline)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SignInQRStep(number: 1, text: "Open the Steam app on another device.")
                    SignInQRStep(number: 2, text: "Tap the Steam Guard shield, then Scan a QR Code.")
                    SignInQRStep(number: 3, text: "Point it at this code and approve.")
                }
            }
            SignInUseAccountNameButton(action: useAccountName)
        }
    }

    @ViewBuilder private var code: some View {
        if let url {
            QRCodeView(text: url.absoluteString)
                .frame(maxWidth: 240, maxHeight: 240)
                .opacity(scanned ? 0.35 : 1)
                .overlay {
                    if scanned {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                    }
                }
                .accessibilityLabel(scanned ? "QR code, scanned" : "Steam sign-in QR code")
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(width: 240, height: 240)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
                .accessibilityLabel("Loading QR code")
        }
    }
}

/// The QR code couldn't be fetched, or expired: why, Try Again, and Use Account Name.
struct SignInQRFailedPanel: View {
    let message: String
    let retry: () -> Void
    let useAccountName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SignInQRTitle()
            SignInMessage(text: message, systemImage: "exclamationmark.triangle.fill")
            Button(action: retry) {
                Text("Try Again").bold().frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .tint(Color(red: 0.80, green: 0.18, blue: 0.22))
            SignInUseAccountNameButton(action: useAccountName)
        }
    }
}

private struct SignInQRTitle: View {
    var body: some View {
        Label("Sign In with a QR Code", systemImage: "qrcode")
            .font(.title2)
            .bold()
    }
}

private struct SignInUseAccountNameButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Use Account Name", systemImage: "person.text.rectangle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .controlSize(.large)
    }
}

/// A numbered step under the QR code.
private struct SignInQRStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number.formatted())
                .font(.footnote)
                .bold()
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.12), in: .circle)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
