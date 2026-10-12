import Darwin
import Foundation

/// Unpacks zip, 7z and rar (4 and 5) archives with the system's libarchive (BSD-2), for
/// patches from the patch list and Import Patch. The library ships in iOS and tvOS but its SDK
/// stub only lists arm64e, so it's opened at runtime rather than linked. Shiori writes each
/// entry itself: only regular files and folders, and never outside the destination.
enum ArchiveExtractor {
    enum Failure: LocalizedError {
        case unavailable
        case unreadable(String)
        case unsafePath(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "This archive can't be opened on this device."
            case let .unreadable(message): "The archive couldn't be read: \(message)"
            case let .unsafePath(path): "The archive has a file outside its own folder (\(path)); nothing was installed."
            }
        }
    }

    /// Bytes written so far, total bytes (uncompressed, 0 when unknown), and the entry's path.
    typealias Progress = (Int64, Int64, String) -> Void

    static let archiveExtensions: Set<String> = ["zip", "7z", "rar"]

    static var isAvailable: Bool { Library.shared != nil }

    /// The entries' paths, without writing anything.
    static func list(_ archive: URL) throws -> [String] {
        guard let lib = Library.shared else { throw Failure.unavailable }
        let reader = try lib.open(archive)
        defer { _ = lib.readFree(reader) }
        var paths: [String] = []
        var entry: OpaquePointer?
        while true {
            let status = lib.nextHeader(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw Failure.unreadable(lib.error(reader)) }
            if let path = lib.path(entry) { paths.append(path) }
            _ = lib.skip(reader)
        }
        return paths
    }

    /// Writes the archive's files under `destination`; returns their relative paths.
    @discardableResult
    static func extract(_ archive: URL, to destination: URL, progress: Progress? = nil) throws -> [String] {
        guard let lib = Library.shared else { throw Failure.unavailable }
        let fm = FileManager.default
        // A first pass for the total size, so progress can show a fraction.
        let total = (try? totalSize(archive, lib: lib)) ?? 0
        let reader = try lib.open(archive)
        defer { _ = lib.readFree(reader) }
        let root = destination.standardizedFileURL
        var written: Int64 = 0
        var paths: [String] = []
        var entry: OpaquePointer?
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let status = lib.nextHeader(reader, &entry)
            if status == ARCHIVE_EOF { break }
            guard status >= ARCHIVE_WARN, let entry else { throw Failure.unreadable(lib.error(reader)) }
            guard let raw = lib.path(entry) else { _ = lib.skip(reader); continue }
            let path = raw.replacingOccurrences(of: "\\", with: "/")
            let components = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
            guard !path.hasPrefix("/"), !components.contains("..") else { throw Failure.unsafePath(path) }
            if components.isEmpty { _ = lib.skip(reader); continue }
            // Relative, with no "..": the target is inside `root`.
            let target = components.reduce(root) { $0.appendingPathComponent(String($1)) }
            let type = lib.fileType(entry)
            if type == AE_IFDIR {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                _ = lib.skip(reader)
                continue
            }
            guard type == AE_IFREG || type == 0 else { _ = lib.skip(reader); continue } // links, devices
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: target.path, contents: nil),
                  let handle = try? FileHandle(forWritingTo: target) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
            defer { try? handle.close() }
            while true {
                let count = buffer.withUnsafeMutableBytes { lib.readData(reader, $0.baseAddress, $0.count) }
                if count == 0 { break }
                guard count > 0 else { throw Failure.unreadable(lib.error(reader)) }
                try handle.write(contentsOf: buffer[0..<count])
                written += Int64(count)
                progress?(written, total, path)
            }
            paths.append(components.joined(separator: "/"))
        }
        return paths
    }

    private static func totalSize(_ archive: URL, lib: Library) throws -> Int64 {
        let reader = try lib.open(archive)
        defer { _ = lib.readFree(reader) }
        var total: Int64 = 0
        var entry: OpaquePointer?
        while lib.nextHeader(reader, &entry) == ARCHIVE_OK, let entry {
            if lib.sizeIsSet(entry) != 0 { total += lib.size(entry) }
            _ = lib.skip(reader)
        }
        return total
    }

    // libarchive's constants.
    private static let ARCHIVE_EOF: Int32 = 1
    private static let ARCHIVE_OK: Int32 = 0
    private static let ARCHIVE_WARN: Int32 = -20
    private static let AE_IFREG: UInt16 = 0o100000
    private static let AE_IFDIR: UInt16 = 0o040000

    /// The functions Shiori uses, looked up once.
    private final class Library: @unchecked Sendable {
        typealias New = @convention(c) () -> OpaquePointer?
        typealias Support = @convention(c) (OpaquePointer?) -> Int32
        typealias OpenFile = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int) -> Int32
        typealias NextHeader = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> Int32
        typealias EntryString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
        typealias EntryType = @convention(c) (OpaquePointer?) -> UInt16
        typealias EntrySize = @convention(c) (OpaquePointer?) -> Int64
        typealias ReadData = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int) -> Int
        typealias ErrorString = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

        static let shared: Library? = Library()

        let readNew: New
        let supportAllFormats: Support
        let supportAllFilters: Support
        let openFilename: OpenFile
        let nextHeader: NextHeader
        let pathUTF8: EntryString
        let pathNative: EntryString
        let fileType: EntryType
        let size: EntrySize
        let sizeIsSet: Support
        let readData: ReadData
        let skip: Support
        let readFree: Support
        let errorString: ErrorString

        private init?() {
            guard let handle = dlopen("/usr/lib/libarchive.2.dylib", RTLD_NOW) ?? dlopen("libarchive.2.dylib", RTLD_NOW) else { return nil }
            func load<T>(_ name: String, _: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let readNew = load("archive_read_new", New.self),
                  let supportAllFormats = load("archive_read_support_format_all", Support.self),
                  let supportAllFilters = load("archive_read_support_filter_all", Support.self),
                  let openFilename = load("archive_read_open_filename", OpenFile.self),
                  let nextHeader = load("archive_read_next_header", NextHeader.self),
                  let pathUTF8 = load("archive_entry_pathname_utf8", EntryString.self),
                  let pathNative = load("archive_entry_pathname", EntryString.self),
                  let fileType = load("archive_entry_filetype", EntryType.self),
                  let size = load("archive_entry_size", EntrySize.self),
                  let sizeIsSet = load("archive_entry_size_is_set", Support.self),
                  let readData = load("archive_read_data", ReadData.self),
                  let skip = load("archive_read_data_skip", Support.self),
                  let readFree = load("archive_read_free", Support.self),
                  let errorString = load("archive_error_string", ErrorString.self)
            else { return nil }
            self.readNew = readNew
            self.supportAllFormats = supportAllFormats
            self.supportAllFilters = supportAllFilters
            self.openFilename = openFilename
            self.nextHeader = nextHeader
            self.pathUTF8 = pathUTF8
            self.pathNative = pathNative
            self.fileType = fileType
            self.size = size
            self.sizeIsSet = sizeIsSet
            self.readData = readData
            self.skip = skip
            self.readFree = readFree
            self.errorString = errorString
        }

        func open(_ url: URL) throws -> OpaquePointer {
            guard let reader = readNew() else { throw Failure.unavailable }
            _ = supportAllFormats(reader)
            _ = supportAllFilters(reader)
            let status = url.withUnsafeFileSystemRepresentation { openFilename(reader, $0, 1 << 16) }
            guard status == ArchiveExtractor.ARCHIVE_OK else {
                let message = error(reader)
                _ = readFree(reader)
                throw Failure.unreadable(message)
            }
            return reader
        }

        func path(_ entry: OpaquePointer) -> String? {
            if let utf8 = pathUTF8(entry) { return String(cString: utf8) }
            if let native = pathNative(entry) { return String(cString: native) }
            return nil
        }

        func error(_ reader: OpaquePointer?) -> String {
            errorString(reader).map { String(cString: $0) } ?? "unknown error"
        }
    }
}
