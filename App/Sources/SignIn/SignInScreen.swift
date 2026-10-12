#if os(iOS)
import SteamKit
import SwiftUI

/// Signing in to Steam on iPhone and iPad (design A): Shiori's Hanafuda card and what the
/// app does on the left (or above), and the step in progress on a plain card beside it
/// (or below): the account form, waiting on Steam Guard, the QR code, or what went wrong.
struct SignInScreen: View {
    @Environment(SteamModel.self) private var steam
    @State private var size: CGSize = .zero

    /// Side by side when there's room (iPad, an iPhone on its side).
    private var twoColumns: Bool { size.width >= 700 }

    /// The step to show: Steam's, or one picked with `-ShioriSignInPreview` (Debug).
    private var step: SignInStep { SignInPreview.step ?? SignInStep(steam.signIn) }

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
                        SignInStepCard(step: step)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: 900)
                } else {
                    VStack(spacing: 28) {
                        // On a phone, what Shiori does shows with the form; later steps need the room.
                        SignInIntro(alignment: .center, showsFeatures: isForm)
                        SignInStepCard(step: step)
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
    }
}
#endif
