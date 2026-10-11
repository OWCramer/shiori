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
enum GARbroDatabase {
    static let source = URL(string: "https://raw.githubusercontent.com/crskycode/GARbro/master/ArcFormats/Resources/Formats.dat")!

    /// The GARbro title for a Steam game: the compatibility list's `garbro` field, else the
    /// titles mapped before the list carried it.
    static func title(appID: UInt32) -> String? {
        if let title = CompatibilityStore.cachedEntry(appID: appID, engine: "kirikiri")?.garbro { return title }
        return [1094930: "KARAKARA 2", 487430: "KARAKARA 2", 745850: "KARAKARA 2",
                555640: "Japanese School Life",
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
           schemeDate >= databaseDate
        {
            return file
        }
        guard let data = try? Data(contentsOf: databaseFile),
              let scheme = try? export(title: title, from: data)
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

    enum ExportError: Error { case badDatabase, noScheme, noControlBlock }

    /// The engine's scheme file for `title` (SHCX: magic, version 1, mask, offset, the three
    /// branch orders padded to 16 bytes, then the 1024-word control block).
    static func export(title: String, from database: Data) throws -> Data {
        let objects = try NRBFReader.objects(in: database)
        guard let scheme = objects.scheme(named: title) else { throw ExportError.noScheme }
        guard let control = scheme["ControlBlock"]?.integers(in: objects), control.count == 1024 else {
            throw ExportError.noControlBlock
        }
        var out = Data("SHCX".utf8)
        func put(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) } }
        put(1)
        put(UInt32(truncatingIfNeeded: scheme["m_mask"]?.integer ?? 0))
        put(UInt32(truncatingIfNeeded: scheme["m_offset"]?.integer ?? 0))
        for order in ["PrologOrder", "OddBranchOrder", "EvenBranchOrder"] {
            out.append(contentsOf: (scheme[order]?.integers(in: objects) ?? []).map { (value: Int64) in UInt8(truncatingIfNeeded: value) })
        }
        out.append(contentsOf: [0, 0, 0])
        for word in control { put(UInt32(truncatingIfNeeded: word)) }
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

    func schemes() -> [(title: String, fields: [String: NRBFValue])] {
        table.values.compactMap { value in
            guard case let .object(_, members) = value,
                  let key = members["key"], let entry = members["value"],
                  case let .string(title) = key.resolved(in: self),
                  case let .object(className, fields) = entry.resolved(in: self),
                  className.hasSuffix("CxEncryption")
            else { return nil }
            return (title, fields)
        }
    }

    func scheme(named title: String) -> [String: NRBFValue]? {
        schemes().first { $0.title == title }?.fields
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
