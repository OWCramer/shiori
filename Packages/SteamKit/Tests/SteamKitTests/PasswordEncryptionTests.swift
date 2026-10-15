// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Security
import Testing
@testable import SteamKit

struct PasswordEncryptionTests {
    /// Encrypts with a key rebuilt from hex modulus/exponent (as Steam sends them) and
    /// decrypts with the matching private key.
    @Test func encryptsWithKeyFromHex() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let der = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let (modulus, exponent) = try integers(fromRSAPublicKeyDER: der)
        #expect(PasswordEncryption.publicKeyDER(modulus: modulus, exponent: exponent) == der)

        let hex = { (data: Data) in data.map { String(format: "%02X", $0) }.joined() }
        let encrypted = try PasswordEncryption.encrypt("hunter2 ✓", modulusHex: hex(modulus), exponentHex: hex(exponent))
        let ciphertext = try #require(Data(base64Encoded: encrypted))
        let plaintext = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, ciphertext as CFData, nil)) as Data
        #expect(String(decoding: plaintext, as: UTF8.self) == "hunter2 ✓")
    }

    @Test func rejectsMalformedHex() {
        #expect(throws: PasswordEncryption.Error.badKey) { try PasswordEncryption.encrypt("x", modulusHex: "ABC", exponentHex: "010001") }
    }

    /// Minimal DER reader for SEQUENCE { INTEGER, INTEGER }.
    private func integers(fromRSAPublicKeyDER der: Data) throws -> (Data, Data) {
        var bytes = [UInt8](der)[...]
        func readLength() -> Int {
            let first = Int(bytes.removeFirst())
            guard first & 0x80 != 0 else { return first }
            return (0 ..< (first & 0x7F)).reduce(0) { acc, _ in acc << 8 | Int(bytes.removeFirst()) }
        }
        #expect(bytes.removeFirst() == 0x30)
        _ = readLength()
        var values: [Data] = []
        for _ in 0 ..< 2 {
            #expect(bytes.removeFirst() == 0x02)
            let length = readLength()
            values.append(Data(bytes.prefix(length)))
            bytes = bytes.dropFirst(length)
        }
        return (values[0], values[1])
    }
}
