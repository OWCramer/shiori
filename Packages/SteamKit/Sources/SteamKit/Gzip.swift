import Compression
import Foundation

/// Minimal gzip (RFC 1952) decoder on top of the Compression framework's raw DEFLATE.
enum Gzip {
    enum Error: Swift.Error { case notGzip, corrupt }

    /// `expectedSize` defaults to the uncompressed size recorded in the gzip trailer.
    static func decompress(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        var reader = ByteReader(data)
        guard try reader.readUInt8() == 0x1F, try reader.readUInt8() == 0x8B,
              try reader.readUInt8() == 8 // DEFLATE
        else { throw Error.notGzip }
        let flags = try reader.readUInt8()
        _ = try reader.read(6) // mtime, xfl, os
        if flags & 0x04 != 0 { // FEXTRA
            let length = Int(try reader.readUInt8()) | Int(try reader.readUInt8()) << 8
            _ = try reader.read(length)
        }
        if flags & 0x08 != 0 { _ = try reader.readCString() } // FNAME
        if flags & 0x10 != 0 { _ = try reader.readCString() } // FCOMMENT
        if flags & 0x02 != 0 { _ = try reader.read(2) } // FHCRC

        let deflated = reader.remaining()
        guard deflated.count >= 8 else { throw Error.corrupt }
        let stream = deflated.prefix(deflated.count - 8)
        var trailer = ByteReader(deflated.suffix(4))
        let expectedSize = try expectedSize ?? Int(trailer.readUInt32LE())
        guard expectedSize > 0, !stream.isEmpty else { throw Error.corrupt }

        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dst in
            stream.withUnsafeBytes { src in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, stream.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else { throw Error.corrupt }
        return output
    }
}
