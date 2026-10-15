#if os(iOS)
import SteamKit
import SwiftUI

/// Signing in to Steam on iPhone and iPad (design A): Shiori's Hanafuda card and what the
/// app does on the left (or above), and the step in progress on a plain card beside it
/// (or below). It opens on the QR code, for the Steam app on another device; Use Account
/// Name switches to the account form (with Steam Guard) for anyone with only this device.
/// The QR code comes first on every visit: the choice isn't remembered.
struct SignInScreen: View {
    @Environment(SteamModel.self) private var steam
    @State private var size: CGSize = .zero
    @State private var method: SignInMethod = SignInPreview.method ?? .qr

    /// Side by side when there's room (iPad, an iPhone on its side).
    private var twoColumns: Bool { size.width >= 700 }

    /// The step to show: Steam's, or one picked with `-ShioriSignInPreview` (Debug).
    private var step: SignInStep { SignInPreview.step ?? SignInStep(steam.signIn, method: method) }

    private var isForm: Bool {
        if case .form = step { true } else { false }
    }

    var body: some View {
        ScrollView {
            Group {
                if twoColumns {
                    HStack(alignment: .center, spacing: 48) {
                        SignInIntro(alignment: .leading, showsFeatures: true)
                            .frame(maxWidth: 380, alignment: .leading)
                        card
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: 900)
                } else {
                    VStack(spacing: 28) {
                        // On a phone, what Shiori does shows with the form; the QR code and later steps need the room.
                        SignInIntro(alignment: .center, showsFeatures: isForm)
                        card
                    }
                    .frame(maxWidth: 440)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
            // Centred when it fits; scrolls when it doesn't (large text, a phone on its side).
            .frame(minHeight: size.height)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background { SignInBackdrop() }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .preferredColorScheme(.dark)
        .onAppear { if method == .qr, case .idle = steam.signIn { startQR() } }
        // Back to idle on the QR code without being signed in: fetch a new code rather than
        // wait on nothing.
        .onChange(of: steam.signIn) { _, signIn in
            if method == .qr, case .idle = signIn { startQR() }
        }
        // Leaving with a QR code up (signed in some other way): stop asking Steam about it.
        .onDisappear {
            if method == .qr, case .qr = steam.signIn { steam.cancelSignIn() }
        }
    }

    private var card: some View {
        SignInStepCard(step: step, useAccountName: useAccountName, useQR: useQR)
    }

    private func useAccountName() {
        method = .accountName
        steam.cancelSignIn()
    }

    private func useQR() {
        method = .qr
        startQR()
    }

    /// Asks Steam for a QR code, unless a preview is showing or a sign-in is already saved.
    private func startQR() {
        guard SignInPreview.step == nil, !steam.isLoggedOn, !steam.hasStoredSession else { return }
        steam.startQRSignIn()
    }
}
#endif
