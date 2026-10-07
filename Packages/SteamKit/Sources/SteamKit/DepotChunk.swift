import CDecoders
import CommonCrypto
import CryptoKit
import Foundation

/// Turns a chunk as served by the CDN into its original bytes: AES-256 decrypt with the
/// depot key, decompress (VZip LZMA, VZstd or PKZip), then check length and checksum.
enum DepotChunk {
    enum Error: Swift.Error, Equatable {
        case decryptionFailed
        case unknownCompression(String)
        case decompressionFailed
        case lengthMismatch(expected: Int, actual: Int)
        case checksumMismatch
    }

    static func process(_ data: Data, key: Data, uncompressedLength: Int, checksum: UInt32) throws -> Data {
        let decrypted = try decrypt(data, key: key)
        let output = try decompress(decrypted, expectedSize: uncompressedLength)
        guard output.count == uncompressedLength else {
            throw Error.lengthMismatch(expected: uncompressedLength, actual: output.count)
        }
        guard adler32(output) == checksum else { throw Error.checksumMismatch }
        return output
    }

    /// Steam's symmetric scheme: the first block is the IV encrypted with AES-ECB,
    /// the rest is AES-CBC with PKCS#7 padding. Also used for manifest filenames.
    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES256, data.count > kCCBlockSizeAES128 else { throw Error.decryptionFailed }
        let encryptedIV = data.prefix(kCCBlockSizeAES128)
        let body = data.dropFirst(kCCBlockSizeAES128)
        let iv = try aes(encryptedIV, key: key, iv: nil, options: CCOptions(kCCOptionECBMode))
        return try aes(body, key: key, iv: iv, options: CCOptions(kCCOptionPKCS7Padding))
    }

    private static func aes(_ input: Data, key: Data, iv: Data?, options: CCOptions) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    (iv ?? Data()).withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), options,
                            keyBytes.baseAddress, key.count,
                            iv == nil ? nil : ivBytes.baseAddress,
                            inBytes.baseAddress, input.count,
                            out.baseAddress, out.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.decryptionFailed }
        output.count = written
        return output
    }

    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        let data = Data(data)
        let magic = Array(data.prefix(4))
        if magic == Array("VSZa".utf8) { return try vzstd(data, expectedSize: expectedSize) }
        if magic.prefix(3) == ArraySlice("VZa".utf8) { return try vzip(data, expectedSize: expectedSize) }
        if magic == [0x50, 0x4B, 0x03, 0x04] { return try Zip.firstEntry(data) }
        throw Error.unknownCompression(magic.map { String(format: "%02X", $0) }.joined())
    }

    /// `VZa` · u32 crc · 5 bytes LZMA properties · LZMA stream · u32 crc · u32 size · `zv`.
    private static func vzip(_ data: Data, expectedSize: Int) throws -> Data {
        let headerLength = 7, propsLength = 5, footerLength = 10
        guard data.count >= headerLength + propsLength + footerLength,
              data[data.count - 2] == UInt8(ascii: "z"), data[data.count - 1] == UInt8(ascii: "v")
        else { throw Error.decompressionFailed }
        let size = Int(try data.uint32LE(at: data.count - 6))
        guard size == expectedSize else { throw Error.lengthMismatch(expected: expectedSize, actual: size) }

        let props = data.subdata(in: headerLength ..< headerLength + propsLength)
        let stream = data.subdata(in: headerLength + propsLength ..< data.count - footerLength)
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            stream.withUnsafeBytes { input in
                props.withUnsafeBytes { p in
                    vnhub_lzma_decode(
                        out.bindMemory(to: UInt8.self).baseAddress, size,
                        input.bindMemory(to: UInt8.self).baseAddress, stream.count,
                        p.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }
        guard written == size else { throw Error.decompressionFailed }
        return output
    }

    /// `VSZa` · u32 crc · Zstandard frame · u32 crc · u32 size · 4 bytes · `zsv`.
    private static func vzstd(_ data: Data, expectedSize: Int) throws -> Data {
        let headerLength = 8, footerLength = 15
        guard data.count >= headerLength + footerLength,
              Array(data.suffix(3)) == Array("zsv".utf8)
        else { throw Error.decompressionFailed }
        let size = Int(try data.uint32LE(at: data.count - 11))
        guard size == expectedSize else { throw Error.lengthMismatch(expected: expectedSize, actual: size) }

        let frame = data.subdata(in: headerLength ..< data.count - footerLength)
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            frame.withUnsafeBytes { input in
                ZSTD_decompress(out.baseAddress, size, input.baseAddress, frame.count)
            }
        }
        guard ZSTD_isError(written) == 0, written == size else { throw Error.decompressionFailed }
        return output
    }

    /// Adler-32 with a starting value of 0 rather than zlib's 1, as Steam computes chunk checksums.
    static func adler32(_ data: Data) -> UInt32 {
        let base: UInt32 = 65521, nmax = 5552
        var s1: UInt32 = 0, s2: UInt32 = 0
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var index = 0
            while index < bytes.count {
                let end = min(index + nmax, bytes.count)
                while index < end {
                    s1 &+= UInt32(bytes[index])
                    s2 &+= s1
                    index += 1
                }
                s1 %= base
                s2 %= base
            }
        }
        return s2 << 16 | s1
    }

    static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }
}
