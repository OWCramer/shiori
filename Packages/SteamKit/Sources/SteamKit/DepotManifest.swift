import Foundation
import SwiftProtobuf

/// A depot manifest: every file in one build of a depot and the chunks it's made of.
///
/// On the wire it's a zip holding one file of sections, each `u32le magic · u32le length ·
/// protobuf`: payload (file mappings), metadata, signature, then an end marker.
public struct DepotManifest: Sendable, Equatable {
    public struct Chunk: Hashable, Sendable {
        /// SHA-1 of the uncompressed chunk, also its name on the CDN.
        public var id: Data
        /// Adler-32 (seed 0) of the uncompressed chunk.
        public var checksum: UInt32
        public var offset: UInt64
        public var compressedLength: UInt32
        public var uncompressedLength: UInt32

        public var hexID: String { id.map { String(format: "%02x", $0) }.joined() }
    }

    public struct File: Sendable, Equatable {
        /// Path relative to the install root, with `/` separators.
        public var name: String
        public var size: UInt64
        public var flags: UInt32
        /// SHA-1 of the whole file.
        public var sha: Data
        public var chunks: [Chunk]
        public var linkTarget: String?

        public var isDirectory: Bool { flags & Flag.directory != 0 }
        public var isSymlink: Bool { flags & Flag.symlink != 0 }
    }

    /// `EDepotFileFlag`.
    public enum Flag {
        public static let directory: UInt32 = 64
        public static let symlink: UInt32 = 512
    }

    public var depotID: UInt32
    public var manifestID: UInt64
    public var creationTime: Date
    public var filenamesEncrypted: Bool
    public var totalUncompressedSize: UInt64
    public var totalCompressedSize: UInt64
    public var files: [File]

    public enum ParseError: Error, Equatable {
        case unknownSection(UInt32)
        case missingSection
        case filenameDecryptionFailed
    }

    private enum Magic {
        static let payload: UInt32 = 0x71F6_17D0
        static let metadata: UInt32 = 0x1F48_12BE
        static let signature: UInt32 = 0x1B81_B817
        static let end: UInt32 = 0x32C4_15AB
    }

    init(depotID: UInt32, manifestID: UInt64, creationTime: Date, filenamesEncrypted: Bool,
         totalUncompressedSize: UInt64, totalCompressedSize: UInt64, files: [File]) {
        self.depotID = depotID
        self.manifestID = manifestID
        self.creationTime = creationTime
        self.filenamesEncrypted = filenamesEncrypted
        self.totalUncompressedSize = totalUncompressedSize
        self.totalCompressedSize = totalCompressedSize
        self.files = files
    }

    /// Parses a manifest as downloaded from the CDN (zipped).
    public init(zipped: Data) throws {
        try self.init(sections: try Zip.firstEntry(zipped))
    }

    /// Parses the unzipped section stream (also the format `serialized()` writes).
    public init(sections data: Data) throws {
        var reader = ByteReader(data)
        var payload: ContentManifestPayload?
        var metadata: ContentManifestMetadata?
        while !reader.isAtEnd {
            let magic = try reader.readUInt32LE()
            if magic == Magic.end { break }
            let body = try reader.read(Int(try reader.readUInt32LE()))
            switch magic {
            case Magic.payload: payload = try ContentManifestPayload(serializedBytes: body)
            case Magic.metadata: metadata = try ContentManifestMetadata(serializedBytes: body)
            case Magic.signature: break
            default: throw ParseError.unknownSection(magic)
            }
        }
        guard let payload, let metadata else { throw ParseError.missingSection }

        depotID = metadata.depotID
        manifestID = metadata.gidManifest
        creationTime = Date(timeIntervalSince1970: TimeInterval(metadata.creationTime))
        filenamesEncrypted = metadata.filenamesEncrypted
        totalUncompressedSize = metadata.cbDiskOriginal
        totalCompressedSize = metadata.cbDiskCompressed
        files = payload.mappings.map { mapping in
            File(
                name: metadata.filenamesEncrypted ? mapping.filename : Self.normalize(mapping.filename),
                size: mapping.size,
                flags: mapping.flags,
                sha: mapping.shaContent,
                chunks: mapping.chunks.map {
                    Chunk(id: $0.sha, checksum: $0.crc, offset: $0.offset,
                          compressedLength: $0.cbCompressed, uncompressedLength: $0.cbOriginal)
                }.sorted { $0.offset < $1.offset },
                linkTarget: mapping.hasLinktarget && !mapping.linktarget.isEmpty ? mapping.linktarget : nil
            )
        }
    }

    /// Filenames in most manifests are base64 of the depot-key-encrypted name.
    public mutating func decryptFilenames(key: Data) throws {
        guard filenamesEncrypted else { return }
        func decrypt(_ name: String) throws -> String {
            guard let encrypted = Data(base64Encoded: name, options: .ignoreUnknownCharacters),
                  var plain = try? DepotChunk.decrypt(encrypted, key: key)
            else { throw ParseError.filenameDecryptionFailed }
            while plain.last == 0 { plain.removeLast() }
            return Self.normalize(String(decoding: plain, as: UTF8.self))
        }
        for index in files.indices {
            files[index].name = try decrypt(files[index].name)
            if let target = files[index].linkTarget { files[index].linkTarget = try decrypt(target) }
        }
        files.sort { $0.name.lowercased() < $1.name.lowercased() }
        filenamesEncrypted = false
    }

    private static func normalize(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "/")
    }

    /// Section stream with decrypted names, for keeping next to an install so it can be
    /// verified offline without the depot key.
    public func serialized() throws -> Data {
        var payload = ContentManifestPayload()
        payload.mappings = files.map { file in
            var mapping = ContentManifestPayload.FileMapping()
            mapping.filename = file.name
            mapping.size = file.size
            mapping.flags = file.flags
            mapping.shaContent = file.sha
            if let target = file.linkTarget { mapping.linktarget = target }
            mapping.chunks = file.chunks.map {
                var chunk = ContentManifestPayload.FileMapping.ChunkData()
                chunk.sha = $0.id
                chunk.crc = $0.checksum
                chunk.offset = $0.offset
                chunk.cbCompressed = $0.compressedLength
                chunk.cbOriginal = $0.uncompressedLength
                return chunk
            }
            return mapping
        }
        var metadata = ContentManifestMetadata()
        metadata.depotID = depotID
        metadata.gidManifest = manifestID
        metadata.creationTime = UInt32(creationTime.timeIntervalSince1970)
        metadata.filenamesEncrypted = filenamesEncrypted
        metadata.cbDiskOriginal = totalUncompressedSize
        metadata.cbDiskCompressed = totalCompressedSize

        var out = Data()
        for (magic, message) in [(Magic.payload, payload as any SwiftProtobuf.Message), (Magic.metadata, metadata)] {
            let body: Data = try message.serializedData()
            out.appendLE(magic)
            out.appendLE(UInt32(body.count))
            out.append(body)
        }
        out.appendLE(Magic.end)
        return out
    }
}
