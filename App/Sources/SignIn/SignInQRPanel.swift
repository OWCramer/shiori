#if os(iOS)
import SwiftUI

/// The QR code, for approving this sign-in with the Steam app on another device, with the
/// steps, and the state once it's scanned.
struct SignInQRPanel: View {
    let url: URL
    let scanned: Bool
    @Environment(SteamModel.self) private var steam

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Sign In with a QR Code", systemImage: "qrcode")
                .font(.title2)
                .bold()
            QRCodeView(text: url.absoluteString)
                .frame(maxWidth: 240, maxHeight: 240)
                .frame(maxWidth: .infinity)
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
            Text("The code changes now and then; keep this screen open until you're in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(action: cancel) {
                Label("Use Account Name and Password", systemImage: "person.text.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private func cancel() { steam.cancelSignIn() }
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
