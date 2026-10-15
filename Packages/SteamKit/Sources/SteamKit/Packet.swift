// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import SwiftProtobuf

/// Steam's protobuf flag on the EMsg word of a packet.
let protoMask: UInt32 = 0x8000_0000

/// Highest Steam client protocol version SteamKit speaks (SteamKit2 `MsgClientLogon.CurrentProtocol`).
let currentProtocol: UInt32 = 65581

/// One message to or from a CM server.
///
/// Over WebSocket every binary frame is exactly one packet:
/// `u32le (emsg | protoMask) · u32le headerLength · CMsgProtoBufHeader · body`.
struct Packet: Sendable {
    var emsg: UInt32
    var header: CMsgProtoBufHeader
    var body: Data

    init(emsg: EMsg, header: CMsgProtoBufHeader = .init(), body: Data = Data()) {
        self.emsg = UInt32(emsg.rawValue)
        self.header = header
        self.body = body
    }

    init<M: SwiftProtobuf.Message>(emsg: EMsg, header: CMsgProtoBufHeader = .init(), message: M) throws {
        self.init(emsg: emsg, header: header, body: try message.serializedData())
    }

    var knownEMsg: EMsg? { EMsg(rawValue: Int(emsg)) }

    var eresult: EResult { EResult(rawValue: header.hasEresult ? header.eresult : EResult.ok.rawValue) }

    func decode<M: SwiftProtobuf.Message>(_: M.Type = M.self) throws -> M {
        try M(serializedBytes: body)
    }

    func encoded() throws -> Data {
        let headerData = try header.serializedData()
        var out = Data(capacity: 8 + headerData.count + body.count)
        out.appendLE(emsg | protoMask)
        out.appendLE(UInt32(headerData.count))
        out.append(headerData)
        out.append(body)
        return out
    }

    /// Decodes a single packet. Returns nil for legacy non-protobuf packets, which SteamKit
    /// never needs over WebSocket and skips.
    static func decode(_ data: Data) throws -> Packet? {
        var reader = ByteReader(data)
        let rawEMsg = try reader.readUInt32LE()
        guard rawEMsg & protoMask != 0 else { return nil }
        let headerLength = Int(try reader.readUInt32LE())
        let header = try CMsgProtoBufHeader(serializedBytes: try reader.read(headerLength))
        var packet = Packet(emsg: .kEmsgInvalid, header: header, body: reader.remaining())
        packet.emsg = rawEMsg & ~protoMask
        return packet
    }

    /// Expands a packet into the packets it carries. A `Multi` holds an optionally gzipped
    /// run of `u32le size · packet`; anything else is returned as-is.
    static func unpack(_ packet: Packet) throws -> [Packet] {
        guard packet.knownEMsg == .kEmsgMulti else { return [packet] }
        let multi: CMsgMulti = try packet.decode()
        let payload = multi.sizeUnzipped > 0
            ? try Gzip.decompress(multi.messageBody, expectedSize: Int(multi.sizeUnzipped))
            : multi.messageBody

        var reader = ByteReader(payload)
        var packets: [Packet] = []
        while !reader.isAtEnd {
            let size = Int(try reader.readUInt32LE())
            if let inner = try decode(try reader.read(size)) {
                packets += try unpack(inner)
            }
        }
        return packets
    }
}

/// 64-bit job id in the same shape SteamKit2 builds: box 0, process 0, start time, sequence.
struct JobIDGenerator: Sendable {
    private var sequence: UInt64 = 0
    private let startTime: UInt64

    init(now: Date = Date()) {
        // Seconds since 2005-01-01, which is Steam's GID epoch.
        let epoch = Date(timeIntervalSince1970: 1_104_537_600)
        startTime = UInt64(max(0, now.timeIntervalSince(epoch))) & 0x3FFF_FFFF
    }

    mutating func next() -> UInt64 {
        sequence = (sequence + 1) & 0xF_FFFF
        return (startTime << 20) | sequence
    }
}

public struct SteamID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// Public universe, individual account, desktop instance.
    public static func individual(accountID: UInt32) -> SteamID {
        SteamID(rawValue: (1 << 56) | (1 << 52) | (1 << 32) | UInt64(accountID))
    }

    public var accountID: UInt32 { UInt32(truncatingIfNeeded: rawValue) }
    public var description: String { String(rawValue) }
}

struct ByteReader {
    enum Error: Swift.Error { case truncated }

    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset >= data.endIndex }

    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw Error.truncated }
        defer { offset += count }
        return data[offset ..< offset + count]
    }

    mutating func readUInt8() throws -> UInt8 { try read(1).first! }

    mutating func readUInt32LE() throws -> UInt32 {
        try read(4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func readUInt64LE() throws -> UInt64 {
        try read(8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Reads a NUL-terminated UTF-8 string and consumes the terminator.
    mutating func readCString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else { throw Error.truncated }
        defer { offset = end + 1 }
        return String(decoding: data[offset ..< end], as: UTF8.self)
    }

    func remaining() -> Data { Data(data[offset...]) }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendCString(_ string: String) {
        append(contentsOf: Array(string.utf8))
        append(0)
    }
}
