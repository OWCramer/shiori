import CoreImage.CIFilterBuiltins
import SwiftUI

struct SignInView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("VN Hub")
                .font(.largeTitle.bold())
            Text("Sign in with the Steam app to see your library.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = steam.resumeError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            content
                .frame(maxWidth: 360)
            Spacer()
        }
        .padding()
    }

    @ViewBuilder private var content: some View {
        switch steam.signIn {
        case .idle:
            Button("Sign in with Steam") { steam.startQRSignIn() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

        case .starting:
            ProgressView("Contacting Steam…")

        case let .showing(url, awaitingConfirmation):
            VStack(spacing: 16) {
                QRCodeView(text: url.absoluteString)
                    .frame(width: 240, height: 240)
                    .accessibilityLabel("Steam sign-in QR code")

                if awaitingConfirmation {
                    Label("Approve the sign-in in the Steam app", systemImage: "iphone")
                        .font(.callout)
                } else {
                    Text("Scan with the Steam app on another device, or open it on this one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    openURL(url)
                } label: {
                    Label("Open in Steam app", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .cancel) { steam.cancelSignIn() }
            }

        case let .failed(message):
            VStack(spacing: 12) {
                Text(message).foregroundStyle(.red)
                Button("Try again") { steam.startQRSignIn() }
                    .buttonStyle(.borderedProminent)
            }
        }
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
