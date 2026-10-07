import Compression
import Foundation

/// Reads the single file inside a PKZip archive, as Steam wraps manifests and some chunks.
/// Only "stored" and "deflate" entries are supported, which is all Steam produces.
enum Zip {
    enum Error: Swift.Error, Equatable {
        case notZip
        case unsupportedMethod(UInt16)
        case corrupt
    }

    /// The contents of the archive's first entry.
    static func firstEntry(_ archive: Data) throws -> Data {
        let archive = Data(archive) // Rebase so indices start at zero.
        // The central directory has the real sizes; local headers may defer them to a data descriptor.
        guard let eocd = endOfCentralDirectory(archive) else { throw Error.notZip }
        var directory = ByteReader(archive)
        _ = try directory.read(Int(try archive.uint32LE(at: eocd + 16)))
        guard try directory.readUInt32LE() == 0x0201_4B50 else { throw Error.corrupt }
        _ = try directory.read(6) // versions, flags
        let method = try directory.readUInt16LE()
        _ = try directory.read(8) // time, date, crc
        let compressedSize = Int(try directory.readUInt32LE())
        let uncompressedSize = Int(try directory.readUInt32LE())
        _ = try directory.read(14) // name/extra/comment lengths, disk, attributes
        let localOffset = Int(try directory.readUInt32LE())

        var local = ByteReader(archive)
        _ = try local.read(localOffset)
        guard try local.readUInt32LE() == 0x0403_4B50 else { throw Error.corrupt }
        _ = try local.read(22)
        let nameLength = Int(try local.readUInt16LE())
        let extraLength = Int(try local.readUInt16LE())
        _ = try local.read(nameLength + extraLength)
        let payload = try local.read(compressedSize)

        switch method {
        case 0:
            return Data(payload)
        case 8:
            return try inflate(payload, expectedSize: uncompressedSize)
        default:
            throw Error.unsupportedMethod(method)
        }
    }

    /// Raw DEFLATE (RFC 1951), which is what Compression calls ZLIB.
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    input.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Error.corrupt }
        return output
    }

    private static func endOfCentralDirectory(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        // The record is 22 bytes plus a comment of up to 64 KiB, scanned from the end.
        let lowest = max(0, data.count - 22 - 0xFFFF)
        for offset in stride(from: data.count - 22, through: lowest, by: -1)
            where data[offset] == 0x50 && data[offset + 1] == 0x4B && data[offset + 2] == 0x05 && data[offset + 3] == 0x06
        {
            return offset
        }
        return nil
    }
}

extension Data {
    func uint32LE(at offset: Int) throws -> UInt32 {
        var reader = ByteReader(self[(startIndex + offset)...])
        return try reader.readUInt32LE()
    }
}

extension ByteReader {
    mutating func readUInt16LE() throws -> UInt16 {
        try read(2).reversed().reduce(0) { $0 << 8 | UInt16($1) }
    }
}
