import Foundation

/// KiriKiri CxDec schemes from GARbro's game database (`Formats.dat`, MIT licence,
/// github.com/crskycode/GARbro), read on the device: the app downloads the database and
/// keeps it in Caches, so a title GARbro adds plays without an app update. Which GARbro
/// title a Steam game is comes from the compatibility list's `garbro` field.
///
/// `Formats.dat` is a 12-byte header and a zlib stream of .NET BinaryFormatter records
/// (MS-NRBF); each title is a dictionary entry whose value is a `CxEncryption`. A scheme is
/// written in the engine's layout (`AETHERKIRI_CX_SCHEME`, AetherKrkr patch 0015), as
/// `Scripts/kirikiri/garbro-cx.py` does on the Mac.
///
/// KiriKiri Z's Hx titles (an `HxCrypt`) are written as SHCX version 2, which only Shiori's own
/// engine reads (`Engine/shiori_hx.cpp`): the CxDec part, then the index keys per archive, the
/// filter key, the random type, and GARbro's names list for the title (`NamesFile`, beside
/// `Formats.dat`) when GARbro publishes one. An Hx archive's index holds only hashes of its
/// files' names, so a title plays once that list exists (`hxPlayable`).
enum GARbroDatabase {
    static let source = URL(string: "https://raw.githubusercontent.com/crskycode/GARbro/master/ArcFormats/Resources/Formats.dat")!

    /// The GARbro title for a Steam game: the compatibility list's `garbro` field, else the
    /// titles mapped before the list carried it.
    static func title(appID: UInt32) -> String? {
        if let title = CompatibilityStore.cachedEntry(appID: appID, engine: "kirikiri")?.garbro { return title }
        return [1094930: "KARAKARA 2", 487430: "KARAKARA 2", 745850: "KARAKARA 2",
                555640: "Japanese School Life",
                1829980: "Café Stella to Shinigami no Chou [Steam]",
                1637370: "Tsuyuchiru Letter ~Umi to Shiori ni Amaoto o~"][appID]
    }

    /// Puts the game's scheme where KiriKiriRuntime looks for it (or clears a stale one).
    static func prepare(appID: UInt32, runtimeCache: URL) async {
        let target = runtimeCache.appendingPathComponent("scheme.shcx")
        try? FileManager.default.removeItem(at: target)
        guard let title = title(appID: appID), let scheme = await schemeFile(title: title) else { return }
        try? FileManager.default.createDirectory(at: runtimeCache, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: scheme, to: target)
    }

    private static var folder: URL { URL.cachesDirectory.appendingPathComponent("garbro", isDirectory: true) }
    private static var databaseFile: URL { folder.appendingPathComponent("Formats.dat") }
    private static var etagFile: URL { folder.appendingPathComponent("Formats.etag") }

    /// The scheme file for a GARbro title, from the cached database, refreshed from GitHub
    /// when it has changed (an ETag check; a day between checks). Nil when the title isn't
    /// in the database or has no embedded control block.
    static func schemeFile(title: String) async -> URL? {
        await refreshIfNeeded()
        let safe = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let file = folder.appendingPathComponent("\(safe).shcx")
        let fm = FileManager.default
        // A scheme exported from the current database is reused.
        if let schemeDate = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           let databaseDate = (try? fm.attributesOfItem(atPath: databaseFile.path))?[.modificationDate] as? Date,
           schemeDate >= databaseDate,
           // An Hx scheme is built again daily: GARbro's names list can arrive on its own.
           !isHxScheme(file) || Date.now.timeIntervalSince(schemeDate) < 24 * 3600
        {
            return file
        }
        guard let data = try? Data(contentsOf: databaseFile),
              let scheme = try? await export(title: title, from: data, names: { await namesList($0) })
        else { return nil }
        try? scheme.write(to: file, options: .atomic)
        return file
    }

    private static func refreshIfNeeded() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let checked = (try? fm.attributesOfItem(atPath: etagFile.path))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(checked) < 24 * 3600, fm.fileExists(atPath: databaseFile.path)
        {
            return
        }
        var request = URLRequest(url: source, timeoutInterval: 30)
        if fm.fileExists(atPath: databaseFile.path), let etag = try? String(contentsOf: etagFile, encoding: .utf8) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return } // Offline: the cached copy, if any, stands.
        if http.statusCode == 200, data.count > 12 {
            try? data.write(to: databaseFile, options: .atomic)
        }
        if http.statusCode == 200 || http.statusCode == 304 {
            let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
            try? etag.write(to: etagFile, atomically: true, encoding: .utf8)
        }
    }

    /// GARbro's names list for an Hx title (`hash:name` lines), downloaded from beside the
    /// database and kept in Caches; nil when GARbro has none.
    private static func namesList(_ name: String) async -> String? {
        guard !name.isEmpty, !name.contains("/"), let url = URL(string: name, relativeTo: source) else { return nil }
        let file = folder.appendingPathComponent(name)
        let fm = FileManager.default
        if let date = (try? fm.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
           Date.now.timeIntervalSince(date) < 24 * 3600
        {
            return try? String(contentsOf: file, encoding: .utf8)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30)),
              let http = response as? HTTPURLResponse
        else { return try? String(contentsOf: file, encoding: .utf8) } // Offline: the cached copy, if any.
        guard http.statusCode == 200, let text = String(data: data, encoding: .utf8) else {
            if http.statusCode == 404 { try? fm.removeItem(at: file) }
            return nil
        }
        try? data.write(to: file, options: .atomic)
        return text
    }

    /// Whether Shiori's engine has what an Hx title needs: its scheme, built, with index keys and
    /// file names (GARbro's names list). Read from the cached scheme; false until it's built.
    static func hxPlayable(appID: UInt32) -> Bool {
        guard let title = title(appID: appID) else { return false }
        let safe = title.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("\(safe).shcx")),
              let summary = hxSummary(of: data) else { return false }
        return summary.keys > 0 && summary.fileNames > 0
    }

    /// The Hx section's archive-key and file-name counts in an SHCX v2 file; nil for any other.
    static func hxSummary(of scheme: Data) -> (keys: Int, fileNames: Int)? {
        let bytes = [UInt8](scheme)
        let start = 16 + 20 + 4096
        guard bytes.count >= start + 4 + 4 + 8 + 1 + 48 + 4, bytes.starts(with: Array("SHCX".utf8)), bytes[4] == 2,
              Array(bytes[start ..< start + 4]) == Array("HXv4".utf8)
        else { return nil }
        var at = start + 4 + 4 + 8 + 1 + 48
        func integer(_ size: Int) -> Int? {
            guard at + size <= bytes.count else { return nil }
            defer { at += size }
            return (0 ..< size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
        }
        guard let keys = integer(4) else { return nil }
        for _ in 0 ..< keys {
            guard let length = integer(2) else { return nil }
            at += length + 48
        }
        guard let directories = integer(4) else { return nil }
        for _ in 0 ..< directories {
            at += 8
            guard let length = integer(2) else { return nil }
            at += length
        }
        guard let fileNames = integer(4) else { return nil }
        return (keys, fileNames)
    }

    /// An SHCX file of version 2 (Hx), which only Shiori's own engine reads.
    static func isHxScheme(_ file: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return false }
        return head.starts(with: Array("SHCX".utf8)) && head[head.startIndex + 4] == 2
    }

    enum ExportError: Error { case badDatabase, noScheme, noControlBlock }

    /// The engine's scheme file for `title` (SHCX: magic, version 1, mask, offset, the three
    /// branch orders padded to 16 bytes, then the 1024-word control block). An Hx title is
    /// version 2, with the Hx section after that (layout: `HxScheme::parse` in shiori_hx.cpp);
    /// `names` fetches GARbro's names list by its file name.
    static func export(title: String, from database: Data,
                       names: (String) async -> String? = { _ in nil }) async throws -> Data
    {
        let objects = try NRBFReader.objects(in: database)
        guard let (className, scheme) = objects.scheme(named: title) else { throw ExportError.noScheme }
        guard let control = scheme["ControlBlock"]?.integers(in: objects), control.count == 1024 else {
            throw ExportError.noControlBlock
        }
        let hx = className.hasSuffix(".HxCrypt")
        var out = Data("SHCX".utf8)
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(hx ? 2 : 1)
        put(UInt32(truncatingIfNeeded: scheme["m_mask"]?.integer ?? 0))
        put(UInt32(truncatingIfNeeded: scheme["m_offset"]?.integer ?? 0))
        for order in ["PrologOrder", "OddBranchOrder", "EvenBranchOrder"] {
            out.append(contentsOf: (scheme[order]?.integers(in: objects) ?? []).map { (value: Int64) in UInt8(truncatingIfNeeded: value) })
        }
        out.append(contentsOf: [0, 0, 0])
        for word in control { put(UInt32(truncatingIfNeeded: word)) }
        guard hx else { return out }

        func key(_ first: NRBFValue?, _ second: NRBFValue?) -> [UInt8]? {
            guard let one = first?.integers(in: objects), one.count == 32,
                  let two = second?.integers(in: objects), two.count == 16 else { return nil }
            return (one + two).map { UInt8(truncatingIfNeeded: $0) }
        }
        func putName(_ name: String) {
            let utf8 = Array(name.utf8.prefix(0xFFFF))
            withUnsafeBytes(of: UInt16(utf8.count).littleEndian) { out.append(contentsOf: $0) }
            out.append(contentsOf: utf8)
        }
        out.append(contentsOf: Array("HXv4".utf8))
        put(UInt32(truncatingIfNeeded: scheme["RandomType"]?.integer ?? 0))
        withUnsafeBytes(of: UInt64(bitPattern: scheme["FilterKey"]?.integer ?? 0).littleEndian) { out.append(contentsOf: $0) }
        if let fallback = key(scheme["IndexKey1"], scheme["IndexKey2"]) {
            out.append(1)
            out.append(contentsOf: fallback)
        } else {
            out.append(0)
            out.append(contentsOf: [UInt8](repeating: 0, count: 48))
        }
        var archives: [(String, [UInt8])] = []
        if case let .object(_, dictionary)? = scheme["IndexKeyDict"]?.resolved(in: objects),
           case let .list(pairs)? = dictionary["KeyValuePairs"]?.resolved(in: objects)
        {
            for pair in pairs {
                guard case let .object(_, fields) = pair.resolved(in: objects),
                      case let .string(name)? = fields["key"]?.resolved(in: objects),
                      case let .object(_, value)? = fields["value"]?.resolved(in: objects),
                      let archiveKey = key(value["Key1"], value["Key2"]) else { continue }
                archives.append((name, archiveKey))
            }
        }
        put(UInt32(archives.count))
        for (name, archiveKey) in archives {
            putName(name)
            out.append(contentsOf: archiveKey)
        }
        // GARbro's names list: "hash:name", 16 hex digits for a directory, 64 for a file.
        var directories: [([UInt8], String)] = [], files: [([UInt8], String)] = []
        if case let .string(namesFile)? = scheme["NamesFile"]?.resolved(in: objects), let text = await names(namesFile) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let hash = hexBytes(parts[0]) else { continue }
                if hash.count == 8 { directories.append((hash, String(parts[1]))) }
                if hash.count == 32 { files.append((hash, String(parts[1]))) }
            }
        }
        for table in [directories, files] {
            put(UInt32(table.count))
            for (hash, name) in table {
                out.append(contentsOf: hash)
                putName(name)
            }
        }
        return out
    }

    private static func hexBytes(_ text: Substring) -> [UInt8]? {
        let digits = Array(text.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index ..< index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            out.append(byte)
        }
        return out
    }

    /// Titles with a CxDec scheme (for tools and tests).
    static func titles(in database: Data) throws -> [String] {
        try NRBFReader.objects(in: database).schemes().map(\.title).sorted()
    }
}

// MARK: - MS-NRBF (.NET BinaryFormatter) reader, enough for GARbro's database

private indirect enum NRBFValue {
    case null
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case string(String)
    case bytes([UInt8])
    case list([NRBFValue])
    case object(String, [String: NRBFValue])
    case reference(Int32)
    case end

    var integer: Int64? {
        switch self {
        case let .integer(value): value
        case let .bool(value): value ? 1 : 0
        default: nil
        }
    }

    func resolved(in objects: NRBFObjects) -> NRBFValue {
        if case let .reference(id) = self { return objects.table[id] ?? .null }
        return self
    }

    func integers(in objects: NRBFObjects) -> [Int64]? {
        switch resolved(in: objects) {
        case let .bytes(bytes): bytes.map(Int64.init)
        case let .list(values): values.compactMap { $0.resolved(in: objects).integer }
        default: nil
        }
    }
}

private struct NRBFObjects {
    var table: [Int32: NRBFValue] = [:]

    func schemes() -> [(title: String, className: String, fields: [String: NRBFValue])] {
        table.values.compactMap { value in
            guard case let .object(_, members) = value,
                  let key = members["key"], let entry = members["value"],
                  case let .string(title) = key.resolved(in: self),
                  case let .object(className, fields) = entry.resolved(in: self),
                  className.hasSuffix("CxEncryption") || className.hasSuffix(".HxCrypt")
            else { return nil }
            return (title, className, fields)
        }
    }

    func scheme(named title: String) -> (className: String, fields: [String: NRBFValue])? {
        schemes().first { $0.title == title }.map { ($0.className, $0.fields) }
    }
}

private struct NRBFReader {
    private let data: [UInt8]
    private var position = 0
    private var objects = NRBFObjects()
    private var classes: [Int32: (name: String, members: [String], types: [UInt8], info: [Any?])] = [:]

    init(database: Data) throws {
        // A 12-byte header, then a zlib stream (a 2-byte header and raw deflate).
        guard database.count > 14,
              let inflated = try? (database.subdata(in: 14 ..< database.count) as NSData).decompressed(using: .zlib)
        else { throw GARbroDatabase.ExportError.badDatabase }
        data = [UInt8](inflated as Data)
    }

    static func objects(in database: Data) throws -> NRBFObjects {
        var reader = try NRBFReader(database: database)
        return try reader.read()
    }

    private mutating func read() throws -> NRBFObjects {
        while position < data.count {
            if case .end = try record() { break }
        }
        return objects
    }

    private mutating func u8() throws -> UInt8 {
        guard position < data.count else { throw GARbroDatabase.ExportError.badDatabase }
        defer { position += 1 }
        return data[position]
    }

    private mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= data.count else { throw GARbroDatabase.ExportError.badDatabase }
        defer { position += count }
        return Array(data[position ..< position + count])
    }

    private mutating func i32() throws -> Int32 {
        let b = try bytes(4)
        return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    private mutating func little(_ count: Int) throws -> UInt64 {
        try bytes(count).enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
    }

    /// A length-prefixed (7-bit varint) UTF-8 string.
    private mutating func string() throws -> String {
        var length = 0, shift = 0
        while true {
            let b = try u8()
            length |= Int(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { break }
        }
        return String(decoding: try bytes(length), as: UTF8.self)
    }

    private mutating func primitive(_ type: UInt8) throws -> NRBFValue {
        switch type {
        case 1: return .bool(try u8() != 0)
        case 2: return .integer(Int64(try u8()))
        case 3: return .string(String(UnicodeScalar(try u8())))
        case 5, 18: return .string(try string())
        case 6: return .double(Double(bitPattern: try little(8)))
        case 7: return .integer(Int64(Int16(truncatingIfNeeded: try little(2))))
        case 8: return .integer(Int64(try i32()))
        case 9, 12, 13: return .integer(Int64(bitPattern: try little(8)))
        case 10: return .integer(Int64(Int8(bitPattern: try u8())))
        case 11: return .double(Double(Float(bitPattern: UInt32(try little(4)))))
        case 14: return .integer(Int64(try little(2)))
        case 15: return .integer(Int64(try little(4)))
        case 16: return .integer(Int64(bitPattern: try little(8)))
        default: throw GARbroDatabase.ExportError.badDatabase
        }
    }

    private mutating func typeInfo(count: Int) throws -> ([UInt8], [Any?]) {
        var types: [UInt8] = []
        for _ in 0 ..< count { types.append(try u8()) }
        var info: [Any?] = []
        for type in types {
            switch type {
            case 0, 7: info.append(try u8())
            case 3: info.append(try string())
            case 4: info.append((try string(), try i32()))
            default: info.append(nil)
            }
        }
        return (types, info)
    }

    private mutating func values(for cls: (name: String, members: [String], types: [UInt8], info: [Any?])) throws -> [String: NRBFValue] {
        var out: [String: NRBFValue] = [:]
        for (index, member) in cls.members.enumerated() {
            if cls.types[index] == 0, let primitiveType = cls.info[index] as? UInt8 {
                out[member] = try primitive(primitiveType)
            } else {
                out[member] = try record()
            }
        }
        return out
    }

    /// Flattens null-run records into the list being filled.
    private mutating func append(_ value: NRBFValue, to list: inout [NRBFValue]) {
        if case let .list(nulls) = value, nulls.allSatisfy({ if case .null = $0 { true } else { false } }) {
            list.append(contentsOf: nulls)
        } else {
            list.append(value)
        }
    }

    private mutating func record() throws -> NRBFValue {
        let type = try u8()
        switch type {
        case 0: // SerializationHeader
            _ = try bytes(16)
            return .null
        case 12: // BinaryLibrary
            _ = try i32()
            _ = try string()
            return try record()
        case 4, 5: // SystemClassWithMembersAndTypes, ClassWithMembersAndTypes
            let id = try i32(), name = try string(), count = Int(try i32())
            var members: [String] = []
            for _ in 0 ..< count { members.append(try string()) }
            let (types, info) = try typeInfo(count: count)
            if type == 5 { _ = try i32() }
            let cls = (name, members, types, info)
            classes[id] = cls
            objects.table[id] = .object(name, [:])
            objects.table[id] = .object(name, try values(for: cls))
            return .reference(id)
        case 2, 3: // SystemClassWithMembers, ClassWithMembers
            let id = try i32(), name = try string(), count = Int(try i32())
            var members: [String] = []
            for _ in 0 ..< count { members.append(try string()) }
            if type == 3 { _ = try i32() }
            classes[id] = (name, members, Array(repeating: 2, count: count), Array(repeating: nil, count: count))
            var fields: [String: NRBFValue] = [:]
            for member in members { fields[member] = try record() }
            objects.table[id] = .object(name, fields)
            return .reference(id)
        case 1: // ClassWithId
            let id = try i32(), metadata = try i32()
            guard let cls = classes[metadata] else { throw GARbroDatabase.ExportError.badDatabase }
            classes[id] = cls
            objects.table[id] = .object(cls.name, try values(for: cls))
            return .reference(id)
        case 6: // BinaryObjectString
            let id = try i32()
            objects.table[id] = .string(try string())
            return .reference(id)
        case 8: // MemberPrimitiveTyped
            return try primitive(try u8())
        case 9: // MemberReference
            return .reference(try i32())
        case 10: // ObjectNull
            return .null
        case 13: // ObjectNullMultiple256
            return .list(Array(repeating: .null, count: Int(try u8())))
        case 14: // ObjectNullMultiple
            return .list(Array(repeating: .null, count: Int(try i32())))
        case 15: // ArraySinglePrimitive
            let id = try i32(), count = Int(try i32()), primitiveType = try u8()
            if primitiveType == 2 {
                objects.table[id] = .bytes(try bytes(count))
            } else {
                var list: [NRBFValue] = []
                for _ in 0 ..< count { list.append(try primitive(primitiveType)) }
                objects.table[id] = .list(list)
            }
            return .reference(id)
        case 16, 17: // ArraySingleObject, ArraySingleString
            let id = try i32(), count = Int(try i32())
            var list: [NRBFValue] = []
            while list.count < count { append(try record(), to: &list) }
            objects.table[id] = .list(list)
            return .reference(id)
        case 7: // BinaryArray
            let id = try i32(), arrayType = try u8(), rank = Int(try i32())
            var total = 1
            for _ in 0 ..< rank { total *= Int(try i32()) }
            if (3 ... 5).contains(arrayType) { for _ in 0 ..< rank { _ = try i32() } }
            let elementType = try u8()
            var info: Any?
            switch elementType {
            case 0, 7: info = try u8()
            case 3: info = try string()
            case 4: info = (try string(), try i32())
            default: info = nil
            }
            var list: [NRBFValue] = []
            while list.count < total {
                if elementType == 0, let primitiveType = info as? UInt8 {
                    list.append(try primitive(primitiveType))
                } else {
                    append(try record(), to: &list)
                }
            }
            objects.table[id] = .list(list)
            return .reference(id)
        case 11: // MessageEnd
            return .end
        default:
            throw GARbroDatabase.ExportError.badDatabase
        }
    }
}
