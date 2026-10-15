// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

/// Steam result code. Only the values SteamKit reacts to or reports are named;
/// anything else is carried through as its raw number.
public struct EResult: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }

    public static let invalid = EResult(rawValue: 0)
    public static let ok = EResult(rawValue: 1)
    public static let fail = EResult(rawValue: 2)
    public static let noConnection = EResult(rawValue: 3)
    public static let invalidPassword = EResult(rawValue: 5)
    public static let loggedInElsewhere = EResult(rawValue: 6)
    public static let invalidProtocolVer = EResult(rawValue: 7)
    public static let invalidParam = EResult(rawValue: 8)
    public static let fileNotFound = EResult(rawValue: 9)
    public static let busy = EResult(rawValue: 10)
    public static let accessDenied = EResult(rawValue: 15)
    public static let timeout = EResult(rawValue: 16)
    public static let banned = EResult(rawValue: 17)
    public static let serviceUnavailable = EResult(rawValue: 20)
    public static let notLoggedOn = EResult(rawValue: 21)
    public static let revoked = EResult(rawValue: 26)
    public static let expired = EResult(rawValue: 27)
    public static let duplicateRequest = EResult(rawValue: 29)
    public static let tryAnotherCM = EResult(rawValue: 48)
    public static let accountLogonDenied = EResult(rawValue: 63)
    public static let invalidLoginAuthCode = EResult(rawValue: 65)
    public static let rateLimitExceeded = EResult(rawValue: 84)
    public static let twoFactorCodeMismatch = EResult(rawValue: 88)
    public static let invalidSignature = EResult(rawValue: 103) // also returned for a revoked/invalid refresh token

    public var description: String {
        let names: [Int32: String] = [
            0: "Invalid", 1: "OK", 2: "Fail", 3: "NoConnection", 5: "InvalidPassword",
            6: "LoggedInElsewhere", 7: "InvalidProtocolVer", 8: "InvalidParam", 9: "FileNotFound",
            10: "Busy", 15: "AccessDenied", 16: "Timeout", 17: "Banned", 20: "ServiceUnavailable",
            21: "NotLoggedOn", 26: "Revoked", 27: "Expired", 29: "DuplicateRequest", 48: "TryAnotherCM", 63: "AccountLogonDenied", 65: "InvalidLoginAuthCode",
            84: "RateLimitExceeded", 88: "TwoFactorCodeMismatch", 103: "InvalidSignature",
        ]
        return "\(names[rawValue] ?? "EResult") (\(rawValue))"
    }
}
