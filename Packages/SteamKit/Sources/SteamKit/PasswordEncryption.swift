import Foundation
import Security

/// Encrypts the password for `BeginAuthSessionViaCredentials`: RSA PKCS#1 v1.5 with the
/// per-account key from `GetPasswordRSAPublicKey`, base64-encoded.
enum PasswordEncryption {
    enum Error: Swift.Error { case badKey, encryptionFailed }

    static func encrypt(_ password: String, modulusHex: String, exponentHex: String) throws -> String {
        guard let modulus = Data(hex: modulusHex), let exponent = Data(hex: exponentHex) else { throw Error.badKey }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(publicKeyDER(modulus: modulus, exponent: exponent) as CFData, attributes as CFDictionary, nil)
        else { throw Error.badKey }
        guard let encrypted = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(password.utf8) as CFData, nil)
        else { throw Error.encryptionFailed }
        return (encrypted as Data).base64EncodedString()
    }

    /// PKCS#1 `RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }`,
    /// the format `SecKeyCreateWithData` takes for RSA public keys.
    static func publicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ bytes: Data) -> Data {
            var value = Data(bytes.drop { $0 == 0 })
            if value.isEmpty || value.first! & 0x80 != 0 { value.insert(0, at: 0) }
            return Data([0x02]) + length(value.count) + value
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    private static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 {
            bytes.insert(UInt8(n & 0xFF), at: 0)
            n >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(decoding: chars[i ..< i + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }
}
