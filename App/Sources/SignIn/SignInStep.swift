import Foundation
import SteamKit

/// How the iPhone and iPad sign-in screen signs in: the QR code first (approved with the
/// Steam app on another device), or the account name and password with Steam Guard.
enum SignInMethod: Equatable {
    case qr
    case accountName
}

/// The sign-in screen's step, from `SteamModel.SignIn` and the method (or a Debug preview).
enum SignInStep: Equatable {
    /// The account form, with what went wrong last time.
    case form(error: String?)
    case working
    /// Steam Guard: approve in the Steam app, confirm by email, and/or type a code.
    case steamGuard(Guard)
    /// The QR code, for the Steam app on another device (nil while Steam sends it);
    /// `scanned` once it has been.
    case qr(URL?, scanned: Bool)
    /// The QR code couldn't be fetched, or expired, with why.
    case qrFailed(String)

    struct Guard: Equatable {
        var approveInApp: Bool
        var confirmByEmail: Bool
        var code: SteamGuardPrompt.CodeKind?
        var emailHint: String?
        var codeError: String?
        var isSubmittingCode: Bool
    }

    init(_ signIn: SteamModel.SignIn, method: SignInMethod) {
        switch signIn {
        // On the QR code, idle and working are the moment before Steam sends one.
        case .idle: self = method == .qr ? .qr(nil, scanned: false) : .form(error: nil)
        case let .failed(message): self = method == .qr ? .qrFailed(message) : .form(error: message)
        case .working: self = method == .qr ? .qr(nil, scanned: false) : .working
        case let .steamGuard(prompt, codeError, isSubmittingCode):
            self = .steamGuard(Guard(approveInApp: prompt.canApproveInSteamApp, confirmByEmail: prompt.canConfirmByEmail,
                                     code: prompt.code, emailHint: prompt.emailHint, codeError: codeError,
                                     isSubmittingCode: isSubmittingCode))
        case let .qr(url, scanned): self = .qr(url, scanned: scanned)
        }
    }
}
