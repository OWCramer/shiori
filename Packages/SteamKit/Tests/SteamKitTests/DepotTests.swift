import CryptoKit
import Foundation
import Testing
@testable import SteamKit

private func chunkFixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/chunks"))
    return try Data(contentsOf: url)
}

private struct ChunkMeta: Decodable {
    var key: String
    var size: Int
    var adler: UInt32
    var sha1: String
    var encryptedFilename: String
    var filename: String

    static func load() throws -> ChunkMeta {
        try JSONDecoder().decode(ChunkMeta.self, from: chunkFixture("meta.json"))
    }

    var keyData: Data { Data(hex: key) }
}

extension Data {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}

struct DepotChunkTests {
    @Test(arguments: ["vzip.bin", "vzstd.bin", "pkzip.bin"])
    func decryptsAndDecompresses(name: String) throws {
        let meta = try ChunkMeta.load()
        let output = try DepotChunk.process(
            try chunkFixture(name), key: meta.keyData, uncompressedLength: meta.size, checksum: meta.adler
        )
        #expect(output == (try chunkFixture("plain.bin")))
        #expect(DepotChunk.sha1(output) == Data(hex: meta.sha1))
    }

    @Test func rejectsWrongChecksum() throws {
        let meta = try ChunkMeta.load()
        #expect(throws: DepotChunk.Error.checksumMismatch) {
            try DepotChunk.process(try chunkFixture("vzip.bin"), key: meta.keyData, uncompressedLength: meta.size, checksum: meta.adler ^ 1)
        }
    }

    @Test func rejectsWrongKey() throws {
        let meta = try ChunkMeta.load()
        var key = meta.keyData
        key[0] ^= 0xFF
        #expect(throws: (any Error).self) {
            try DepotChunk.process(try chunkFixture("vzstd.bin"), key: key, uncompressedLength: meta.size, checksum: meta.adler)
        }
    }

    @Test func adlerStartsFromZero() {
        // zlib.adler32(b"Wikipedia", 0); the textbook value with seed 1 is 0x11E60398.
        #expect(DepotChunk.adler32(Data("Wikipedia".utf8)) == 0x11DD_0397)
        #expect(DepotChunk.adler32(Data()) == 0)
    }

    @Test func decryptsManifestFilename() throws {
        let meta = try ChunkMeta.load()
        var manifest = DepotManifest.sample(names: [meta.encryptedFilename], encrypted: true)
        try manifest.decryptFilenames(key: meta.keyData)
        #expect(manifest.files.map(\.name) == [meta.filename])
        #expect(!manifest.filenamesEncrypted)
    }
}

extension DepotManifest {
    static func sample(names: [String], encrypted: Bool = false, contents: [Data]? = nil) -> DepotManifest {
        let files = names.enumerated().map { index, name in
            let data = contents?[index] ?? Data()
            // Two chunks per file so offsets matter.
            let half = data.count / 2
            let pieces = data.isEmpty ? [] : [data.prefix(half), data.dropFirst(half)]
            var offset: UInt64 = 0
            let chunks = pieces.map { piece -> Chunk in
                defer { offset += UInt64(piece.count) }
                return Chunk(id: DepotChunk.sha1(Data(piece)), checksum: DepotChunk.adler32(Data(piece)), offset: offset,
                             compressedLength: UInt32(piece.count), uncompressedLength: UInt32(piece.count))
            }
            return File(name: name, size: UInt64(data.count), flags: 0, sha: DepotChunk.sha1(data), chunks: chunks, linkTarget: nil)
        }
        return DepotManifest(
            depotID: 451_768, manifestID: 2_770_349_537_028_795_075,
            creationTime: Date(timeIntervalSince1970: 1_700_000_000), filenamesEncrypted: encrypted,
            totalUncompressedSize: files.reduce(0) { $0 + $1.size }, totalCompressedSize: 0, files: files
        )
    }
}

struct DepotManifestTests {
    @Test func roundTripsThroughSections() throws {
        let manifest = DepotManifest.sample(names: ["game/script.rpyc", "renpy/__init__.py"], contents: [Data("abcdef".utf8), Data("xyz".utf8)])
        let parsed = try DepotManifest(sections: try manifest.serialized())
        #expect(parsed == manifest)
    }

    /// Captured from a real download of Highway Blossoms' DLC depot (names already decrypted).
    @Test func parsesCapturedManifest() throws {
        let manifest = try DepotManifest(sections: try fixture("manifest_451769.sections"))
        #expect(manifest.depotID == 451_769)
        #expect(manifest.manifestID == 7_692_950_089_410_827_452)
        #expect(!manifest.filenamesEncrypted)
        let rpa = try #require(manifest.files.first { $0.name == "game/adult.rpa" })
        #expect(rpa.chunks.reduce(0) { $0 + UInt64($1.uncompressedLength) } == rpa.size)
        #expect(manifest.files.contains { $0.name == "game" && $0.isDirectory })
        #expect(try DepotManifest(sections: try manifest.serialized()) == manifest)
    }

    @Test func rejectsUnknownSection() {
        var data = Data()
        data.appendLE(0xDEAD_BEEF)
        data.appendLE(0)
        #expect(throws: DepotManifest.ParseError.unknownSection(0xDEAD_BEEF)) { try DepotManifest(sections: data) }
    }

    @Test func readsDeflatedZipEntry() throws {
        let meta = try ChunkMeta.load()
        let zipped = try DepotChunk.decrypt(try chunkFixture("pkzip.bin"), key: meta.keyData)
        #expect(try Zip.firstEntry(zipped) == (try chunkFixture("plain.bin")))
        #expect(throws: Zip.Error.notZip) { try Zip.firstEntry(Data("not a zip".utf8)) }
    }
}

struct DepotSelectionTests {
    @Test func picksOwnedWindowsDepotsOfHighwayBlossoms() throws {
        let app = AppInfo(appID: 451_760, changeNumber: 0, keyValues: try KeyValue.parseText(fixture("app_451760.vdf")))
        // Base game depots; DLC depots (490278, 451769, ...) aren't owned here.
        let owned: Set<UInt32> = [451_760, 451_762, 451_763, 451_764, 451_768]
        let depots = DepotSelection.windowsDepots(of: app, owned: owned)
        #expect(depots.map(\.depotID) == [451_768, 451_764])
        #expect(depots.first?.manifestID == 2_770_349_537_028_795_075)
    }

    @Test func prefers64BitWhenSplitByArchitecture() throws {
        let app = AppInfo(appID: 1, changeNumber: 0, keyValues: try KeyValue.parseText("""
        "1" { "depots" {
          "11" { "config" { "oslist" "windows" "osarch" "32" } "manifests" { "public" { "gid" "1" } } }
          "12" { "config" { "oslist" "windows" "osarch" "64" } "manifests" { "public" { "gid" "2" } } }
          "13" { "config" { "oslist" "windows" "language" "japanese" } "manifests" { "public" { "gid" "3" } } }
          "14" { "manifests" { "public" "4" } }
          "15" { "depotfromapp" "228980" "sharedinstall" "1" }
        } }
        """))
        let depots = DepotSelection.windowsDepots(of: app, owned: [11, 12, 13, 14, 15])
        #expect(depots.map(\.depotID) == [12, 14])
        #expect(depots.last?.manifestID == 4)
    }
}

struct DepotInstallTests {
    private func temporaryInstall() throws -> DepotInstall {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("steamkit-\(UUID().uuidString)")
        return DepotInstall(root: base.appendingPathComponent("base"), stateDirectory: base.appendingPathComponent("state"))
    }

    @Test func refusesPathsOutsideRoot() throws {
        let install = try temporaryInstall()
        #expect(try install.fileURL(for: "game/a.rpa").path.hasSuffix("/base/game/a.rpa"))
        for bad in ["../evil", "/etc/passwd", "game/../../x", "", "./x"] {
            #expect(throws: SteamError.unsafePath(bad)) { try install.fileURL(for: bad) }
        }
    }

    @Test func journalIgnoresTornWrite() async throws {
        let install = try temporaryInstall()
        try FileManager.default.createDirectory(at: install.stateDirectory, withIntermediateDirectories: true)
        let depot = InstalledDepot(depotID: 1, manifestID: 2)
        let id = Data(repeating: 7, count: 20)
        try (id + Data(repeating: 9, count: 5)).write(to: install.journalURL(depot))
        let journal = try Journal(url: install.journalURL(depot))
        #expect(journal.loadedIDs == [id])
        try await journal.append(Data(repeating: 8, count: 20))
        await journal.close()
        #expect(try Data(contentsOf: install.journalURL(depot)).count == 40)
    }

    @Test func verifyReportsMissingResizedModifiedAndExtraFiles() async throws {
        let install = try temporaryInstall()
        let contents = ["game/script.rpyc", "game/images.rpa", "renpy/__init__.py", "lib/run.exe"]
        let data = contents.map { Data(repeating: UInt8($0.count), count: 1000 + $0.count) }
        let manifest = DepotManifest.sample(names: contents, contents: data)
        let depot = InstalledDepot(depotID: manifest.depotID, manifestID: manifest.manifestID)
        try install.save(DepotInstall.Record(appID: 451_760, depots: [depot], isComplete: true))
        try manifest.serialized().write(to: install.manifestURL(depot))
        for (name, bytes) in zip(contents, data) {
            let url = try install.fileURL(for: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
        }

        let clean = try await install.verify()
        #expect(clean.isClean && clean.checkedFiles == 4 && clean.extraFiles.isEmpty)

        try FileManager.default.removeItem(at: install.fileURL(for: "lib/run.exe"))
        try Data(repeating: 0, count: 10).write(to: install.fileURL(for: "renpy/__init__.py"))
        var patched = data[0]
        patched[patched.count - 1] ^= 1
        try patched.write(to: install.fileURL(for: "game/script.rpyc"))
        try Data("patch".utf8).write(to: install.fileURL(for: "game/patch.rpa"))

        let report = try await install.verify()
        #expect(report.problems == [
            "lib/run.exe": .missing,
            "renpy/__init__.py": .wrongSize(expected: UInt64(data[2].count), actual: 10),
            "game/script.rpyc": .modified,
        ])
        #expect(report.extraFiles == ["game/patch.rpa"])
    }

    @Test func verifyNeedsAFinishedInstall() async throws {
        let install = try temporaryInstall()
        await #expect(throws: DepotInstall.VerifyError.notInstalled) { try await install.verify() }
    }
}
