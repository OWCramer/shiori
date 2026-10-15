import Compression
import Foundation

/// Looks at a KiriKiri game's `data.xp3` before the engine starts, to tell a CxDec-encrypted
/// title Shiori has no scheme for apart from a broken game: the engine itself only reports
/// "corrupted execution file" once its startup script fails to parse.
enum KiriKiriArchiveCheck {
    enum Encryption {
        /// CxDec: needs the title's scheme from GARbro's database (GARbroDatabase).
        case cx
        /// KiriKiri Z's Hx (an `Hxv4` index chunk): the engine opens it when GARbro has the
        /// title's keys.
        case hx
    }

    /// Encryption on the game's `data.xp3` that the engine can't undo on its own, if any.
    /// NEKO WORKs archives are encrypted too, and handled.
    static func unhandledEncryption(base: URL) -> Encryption? {
        guard let entry = startupEntry(in: base.appendingPathComponent("data.xp3")) else { return nil }
        if entry.hasHxIndex { return .hx }
        // Hashed names (hnfn) come with CxDec; the named startup.tjs is then a plain decoy.
        if entry.hasHashedNames && entry.isProtected && !entry.hasNekoNames { return .cx }
        return entry.isProtected && !entry.hasNekoNames && !looksPlain(entry.head) ? .cx : nil
    }

    /// Why Shiori's KiriKiri engine can't open the game yet, if it can't.
    enum ShioriEngineBlocker {
        /// NEKO WORKs archives (`neko` or `eliF` index chunks): NEKOPARA and its family.
        case nekoWorks
        /// KiriKiri Z's Hx (playable when `GARbroDatabase.hxPlayable`).
        case hx
        /// CxDec with no scheme for the title.
        case cxWithoutScheme
    }

    /// `hasScheme`: the title's CxDec scheme is ready (GARbroDatabase), or known to exist.
    static func shioriEngineBlocker(base: URL, hasScheme: Bool) -> ShioriEngineBlocker? {
        guard let entry = startupEntry(in: base.appendingPathComponent("data.xp3")) else { return nil }
        if entry.hasNekoNames { return .nekoWorks }
        if entry.hasHxIndex { return .hx }
        if unhandledEncryption(base: base) == .cx, !hasScheme { return .cxWithoutScheme }
        return nil
    }

    private struct Entry {
        var isProtected = false
        var hasNekoNames = false
        var hasHxIndex = false
        var hasHashedNames = false
        var head = Data()
    }

    private static func startupEntry(in archive: URL) -> Entry? {
        guard let handle = try? FileHandle(forReadingFrom: archive) else { return nil }
        defer { try? handle.close() }
        func read(_ offset: UInt64, _ count: Int) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }
        guard let header = read(0, 32), header.starts(with: [0x58, 0x50, 0x33, 0x0D, 0x0A, 0x20, 0x0A, 0x1A]) else {
            return nil
        }
        var indexOffset = header.u64(11)
        if indexOffset == 0x17, let next = read(0x20, 8) { indexOffset = next.u64(0) }
        guard let flag = read(indexOffset, 1)?.first else { return nil }
        let index: Data
        if flag & 1 != 0 {
            guard let sizes = read(indexOffset + 1, 16), sizes.u64(8) < 64 << 20,
                  let packed = read(indexOffset + 17, Int(sizes.u64(0))),
                  let unpacked = inflate(packed, size: Int(sizes.u64(8))) else { return nil }
            index = unpacked
        } else {
            guard let size = read(indexOffset + 1, 8), size.u64(0) < 64 << 20,
                  let raw = read(indexOffset + 9, Int(size.u64(0))) else { return nil }
            index = raw
        }

        var hasNekoNames = false, hasHxIndex = false, hasHashedNames = false
        var startup: (isProtected: Bool, offset: UInt64, compressed: Bool, packedSize: UInt64)?
        var at = 0
        while at + 12 <= index.count {
            let tag = index.subdata(in: at..<at + 4)
            let size = Int(index.u64(at + 4))
            guard size >= 0, at + 12 + size <= index.count else { break }
            let body = index.subdata(in: at + 12..<at + 12 + size)
            at += 12 + size
            // NEKO WORKs: `neko` name chunks, or the older `eliF` entries (NEKOPARA Vol. 0-2).
            if tag == Data("neko".utf8) || tag == Data("eliF".utf8) { hasNekoNames = true }
            if tag == Data("Hxv4".utf8) { hasHxIndex = true }
            if tag == Data("hnfn".utf8) { hasHashedNames = true }
            guard tag == Data("File".utf8) else { continue }
            var name = "", isProtected = false
            var segment: (UInt64, Bool, UInt64)?
            var inner = 0
            while inner + 12 <= body.count {
                let chunk = body.subdata(in: inner..<inner + 4)
                let length = Int(body.u64(inner + 4))
                guard length >= 0, inner + 12 + length <= body.count else { break }
                let data = body.subdata(in: inner + 12..<inner + 12 + length)
                inner += 12 + length
                if chunk == Data("info".utf8), data.count >= 22 {
                    isProtected = data.u32(0) != 0
                    let characters = Int(data.u16(20))
                    if data.count >= 22 + characters * 2 {
                        name = String(data: data.subdata(in: 22..<22 + characters * 2), encoding: .utf16LittleEndian) ?? ""
                    }
                } else if chunk == Data("segm".utf8), data.count >= 28 {
                    segment = (data.u64(4), data.u32(0) & 7 != 0, data.u64(20))
                }
            }
            // Some archives carry a plain decoy startup.tjs besides the protected real one.
            if name == "startup.tjs", let segment, startup == nil || (isProtected && startup?.isProtected == false) {
                startup = (isProtected, segment.0, segment.1, segment.2)
            }
        }
        guard let startup else {
            return hasHxIndex || hasNekoNames ? Entry(hasNekoNames: hasNekoNames, hasHxIndex: hasHxIndex) : nil
        }
        var entry = Entry(isProtected: startup.isProtected, hasNekoNames: hasNekoNames, hasHxIndex: hasHxIndex,
                          hasHashedNames: hasHashedNames)
        let count = Int(min(startup.packedSize, 1 << 20))
        if let raw = read(startup.offset, count) {
            entry.head = startup.compressed ? (inflate(raw, size: 64, partial: true) ?? Data()) : raw.prefix(64)
        }
        return entry
    }

    /// A startup script KiriKiri can read as is: compiled TJS, or text (UTF-16 with a BOM,
    /// KiriKiri's own FE FE text scrambling, or plain ASCII/UTF-8).
    private static func looksPlain(_ head: Data) -> Bool {
        guard head.count >= 4 else { return true }
        if head.starts(with: Data("TJS2".utf8)) || head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFE])
            || head.starts(with: [0xEF, 0xBB, 0xBF]) {
            return true
        }
        // Encrypted bytes can happen to be printable, but not to read as lines of script.
        let text = head.prefix(64)
        return text.allSatisfy { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D || (0x20..<0x7F).contains($0) }
            && text.contains { $0 == 0x20 || $0 == 0x0A }
    }

    /// zlib data (a 2-byte header, then raw deflate).
    private static func inflate(_ data: Data, size: Int, partial: Bool = false) -> Data? {
        guard data.count > 2, size > 0 else { return nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { out in
            data.dropFirst(2).withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size || (partial && written > 0) else { return nil }
        return output.prefix(written)
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8
    }

    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + at + $1]) << (8 * $1) }
    }

    func u64(_ at: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(self[startIndex + at + $1]) << (8 * $1) }
    }
}
