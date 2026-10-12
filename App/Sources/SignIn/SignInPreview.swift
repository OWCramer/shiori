import Foundation

/// `-ShioriSignInPreview form|working|approve|code|email|qr|scanned|error|expired` (Debug):
/// shows that step of the sign-in screen without talking to Steam, for screenshots. Its
/// buttons still act on the real, idle sign-in, so nothing goes to Steam unless typed in.
enum SignInPreview {
    private static var name: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "ShioriSignInPreview")
        #else
        nil
        #endif
    }

    static var step: SignInStep? {
        switch name {
        case "form", "expired": .form(error: nil)
        case "working": .working
        case "approve":
            .steamGuard(.init(approveInApp: true, confirmByEmail: false, code: .authenticator, emailHint: nil,
                              codeError: nil, isSubmittingCode: false))
        case "code":
            .steamGuard(.init(approveInApp: false, confirmByEmail: false, code: .authenticator, emailHint: nil,
                              codeError: "Steam didn't accept that code. Codes change every 30 seconds; try the one showing now.",
                              isSubmittingCode: false))
        case "email":
            .steamGuard(.init(approveInApp: false, confirmByEmail: true, code: .email, emailHint: "gmail.com",
                              codeError: nil, isSubmittingCode: false))
        case "qr", "scanned": .qr(URL(string: "https://s.team/q/1/1234567890123456789")!, scanned: name == "scanned")
        case "error": .form(error: "The account name or password is incorrect.")
        default: nil
        }
    }

    /// `expired`: the saved sign-in was refused (shown above the form).
    static var expiredMessage: String? {
        name == "expired" ? "Your Steam sign-in has expired. Sign in again to continue." : nil
    }
}
