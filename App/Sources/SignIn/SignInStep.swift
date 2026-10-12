import Foundation
import SteamKit

/// The sign-in screen's step, from `SteamModel.SignIn` (or a Debug preview).
enum SignInStep: Equatable {
    /// The account form, with what went wrong last time.
    case form(error: String?)
    case working
    /// Steam Guard: approve in the Steam app, confirm by email, and/or type a code.
    case steamGuard(Guard)
    /// The QR code, for the Steam app on another device; `scanned` once it has.
    case qr(URL, scanned: Bool)

    struct Guard: Equatable {
        var approveInApp: Bool
        var confirmByEmail: Bool
        var code: SteamGuardPrompt.CodeKind?
        var emailHint: String?
        var codeError: String?
        var isSubmittingCode: Bool
    }

    init(_ signIn: SteamModel.SignIn) {
        switch signIn {
        case .idle: self = .form(error: nil)
        case let .failed(message): self = .form(error: message)
        case .working: self = .working
        case let .steamGuard(prompt, codeError, isSubmittingCode):
            self = .steamGuard(Guard(approveInApp: prompt.canApproveInSteamApp, confirmByEmail: prompt.canConfirmByEmail,
                                     code: prompt.code, emailHint: prompt.emailHint, codeError: codeError,
                                     isSubmittingCode: isSubmittingCode))
        case let .qr(url, scanned): self = .qr(url, scanned: scanned)
        }
    }
}
