import Compression
import Foundation

/// Unpacks a .zip into a folder. Handles stored and deflated entries (what every common
/// zip tool writes), including ZIP64 sizes, streaming each entry so large archives
/// (multi-gigabyte .rpa patches) never sit in memory.
enum ZipExtractor {
    enum Error: Swift.Error, LocalizedError {
        case notZip
        case corrupt
        case encrypted
        case unsupportedMethod(UInt16)
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .notZip: "That file isn't a zip archive."
            case .corrupt: "The zip archive is damaged."
            case .encrypted: "Password-protected zip archives aren't supported."
            case let .unsupportedMethod(method): "The zip uses a compression method Shiori can't read (\(method))."
            case let .unsafePath(path): "The zip contains an invalid path: \(path)."
            }
        }
    }

    struct Entry {
        var path: String
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    /// Extracts every entry under `destination`. Returns the number of files written.
    @discardableResult
    static func extract(_ archive: URL, to destination: URL) throws -> Int {
        let data = try Data(contentsOf: archive, options: .alwaysMapped)
        let entries = try centralDirectory(data)
        let fm = FileManager.default
        var written = 0
        for entry in entries {
            let target = try safeURL(entry.path, under: destination)
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // macOS Finder adds resource-fork shadows; they aren't part of any patch.
            if entry.path.hasPrefix("__MACOSX/") || (entry.path as NSString).lastPathComponent == ".DS_Store" { continue }
            guard entry.flags & 1 == 0 else { throw Error.encrypted }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(entry, from: data, to: target)
            written += 1
        }
        return written
    }

    private static func safeURL(_ path: String, under root: URL) throws -> URL {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !parts.contains(".."), !parts.isEmpty else { throw Error.unsafePath(path) }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    // MARK: - Reading

    private static func centralDirectory(_ data: Data) throws -> [Entry] {
        guard let eocd = findSignature(0x0605_4B50, in: data, minimumSize: 22) else { throw Error.notZip }
        var count = UInt64(try data.le16(eocd + 10))
        var directoryOffset = UInt64(try data.le32(eocd + 16))

        // ZIP64: the classic record holds 0xFFFF / 0xFFFFFFFF and a locator points further back.
        if count == 0xFFFF || directoryOffset == 0xFFFF_FFFF, eocd >= 20,
           try data.le32(eocd - 20) == 0x0706_4B50
        {
            let record = Int(try data.le64(eocd - 20 + 8))
            guard try data.le32(record) == 0x0606_4B50 else { throw Error.corrupt }
            count = try data.le64(record + 32)
            directoryOffset = try data.le64(record + 48)
        }

        var entries: [Entry] = []
        var offset = Int(directoryOffset)
        for _ in 0 ..< count {
            guard try data.le32(offset) == 0x0201_4B50 else { throw Error.corrupt }
            let flags = try data.le16(offset + 8)
            let method = try data.le16(offset + 10)
            var compressed = UInt64(try data.le32(offset + 20))
            var uncompressed = UInt64(try data.le32(offset + 24))
            let nameLength = Int(try data.le16(offset + 28))
            let extraLength = Int(try data.le16(offset + 30))
            let commentLength = Int(try data.le16(offset + 32))
            var localOffset = UInt64(try data.le32(offset + 42))
            let nameData = try data.slice(offset + 46, nameLength)
            // Bit 11 marks UTF-8 names; older tools used CP437, which is ASCII for patch files.
            let name = String(decoding: nameData, as: UTF8.self)

            // ZIP64 extended information: only the fields that overflowed are present, in order.
            var extra = offset + 46 + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = try data.le16(extra)
                let size = Int(try data.le16(extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF { uncompressed = try data.le64(field); field += 8 }
                    if compressed == 0xFFFF_FFFF { compressed = try data.le64(field); field += 8 }
                    if localOffset == 0xFFFF_FFFF { localOffset = try data.le64(field) }
                }
                extra += 4 + size
            }

            entries.append(Entry(path: name.replacingOccurrences(of: "\\", with: "/"), method: method, flags: flags,
                                 compressedSize: compressed, uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            offset = extraEnd + commentLength
        }
        return entries
    }

    private static func write(_ entry: Entry, from data: Data, to url: URL) throws {
        let local = Int(entry.localHeaderOffset)
        guard try data.le32(local) == 0x0403_4B50 else { throw Error.corrupt }
        let start = local + 30 + Int(try data.le16(local + 26)) + Int(try data.le16(local + 28))
        let payload = try data.slice(start, Int(entry.compressedSize))

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        switch entry.method {
        case 0:
            try handle.write(contentsOf: payload)
        case 8:
            try inflate(payload, into: handle)
        default:
            throw Error.unsupportedMethod(entry.method)
        }
    }

    /// Streams raw DEFLATE (Compression's ZLIB) into the file, 1 MiB at a time.
    private static func inflate(_ input: Data, into handle: FileHandle) throws {
        guard !input.isEmpty else { return }
        let bufferSize = 1 << 20
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.corrupt
        }
        defer { compression_stream_destroy(streamPointer) }

        try input.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 { try handle.write(contentsOf: Data(bytes: destination, count: produced)) }
                switch status {
                case COMPRESSION_STATUS_END: return
                case COMPRESSION_STATUS_OK: continue
                default: throw Error.corrupt
                }
            }
        }
    }

    private static func findSignature(_ signature: UInt32, in data: Data, minimumSize: Int) -> Int? {
        guard data.count >= minimumSize else { return nil }
        let lowest = max(0, data.count - minimumSize - 0xFFFF)
        for offset in stride(from: data.count - minimumSize, through: lowest, by: -1)
            where (try? data.le32(offset)) == signature
        {
            return offset
        }
        return nil
    }
}

private extension Data {
    func slice(_ offset: Int, _ count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset + count <= self.count else { throw ZipExtractor.Error.corrupt }
        return self[(startIndex + offset) ..< (startIndex + offset + count)]
    }

    func le16(_ offset: Int) throws -> UInt16 {
        try slice(offset, 2).reversed().reduce(0) { $0 << 8 | UInt16($1) }
    }

    func le32(_ offset: Int) throws -> UInt32 {
        try slice(offset, 4).reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }

    func le64(_ offset: Int) throws -> UInt64 {
        try slice(offset, 8).reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }
}
