import Foundation
import Testing
@testable import SteamKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

struct PacketTests {
    @Test func roundTripsProtobufPacket() throws {
        var header = CMsgProtoBufHeader()
        header.steamid = 76_561_197_960_265_728
        header.clientSessionid = 1234
        header.jobidSource = 42
        var hello = CMsgClientHello()
        hello.protocolVersion = currentProtocol

        let encoded = try Packet(emsg: .kEmsgClientHello, header: header, message: hello).encoded()
        // EMsg word carries the protobuf flag.
        #expect(encoded.prefix(4) == Data([0x4D, 0x26, 0x00, 0x80]))

        let decoded = try #require(try Packet.decode(encoded))
        #expect(decoded.knownEMsg == .kEmsgClientHello)
        #expect(decoded.header.steamid == header.steamid)
        #expect(decoded.header.clientSessionid == 1234)
        #expect(decoded.header.jobidSource == 42)
        #expect(try decoded.decode(CMsgClientHello.self).protocolVersion == currentProtocol)
    }

    @Test func skipsNonProtobufPackets() throws {
        var data = Data()
        data.appendLE(751) // no proto flag
        data.append(Data(repeating: 0, count: 32))
        #expect(try Packet.decode(data) == nil)
    }

    @Test func rejectsTruncatedPacket() throws {
        var data = Data()
        data.appendLE(703 | protoMask)
        data.appendLE(100) // header longer than the frame
        #expect(throws: ByteReader.Error.truncated) { try Packet.decode(data) }
    }

    @Test(arguments: ["multi_gzip.bin", "multi_plain.bin"])
    func unpacksMulti(fixtureName: String) throws {
        let outer = try #require(try Packet.decode(fixture(fixtureName)))
        #expect(outer.knownEMsg == .kEmsgMulti)

        let packets = try Packet.unpack(outer)
        #expect(packets.map(\.emsg) == [703, 780, 8906])

        let licenses = try packets[1].decode(CMsgClientLicenseList.self)
        #expect(licenses.eresult == 1)
        #expect(licenses.licenses.map(\.packageID) == [42, 313])

        #expect(packets[2].header.jobidTarget == 0x1122_3344_5566_7788)
    }

    @Test func jobIDsAreUniqueAndCarryStartTime() {
        var generator = JobIDGenerator(now: Date(timeIntervalSince1970: 1_104_537_600 + 1000))
        let first = generator.next()
        let second = generator.next()
        #expect(first != second)
        #expect(first >> 20 == 1000)
        #expect(second & 0xF_FFFF == 2)
    }

    @Test func eresultDefaultsToOKWithoutHeaderValue() throws {
        #expect(Packet(emsg: .kEmsgServiceMethodResponse).eresult == .ok)
        var header = CMsgProtoBufHeader()
        header.eresult = 27
        #expect(Packet(emsg: .kEmsgServiceMethodResponse, header: header).eresult == .expired)
    }

    @Test func individualSteamID() {
        #expect(SteamID.individual(accountID: 0).rawValue == 76_561_197_960_265_728)
        #expect(SteamID.individual(accountID: 22202).rawValue == 76_561_197_960_287_930)
    }
}

struct CMDirectoryTests {
    @Test func keepsWebSocketServersByLoad() throws {
        let servers = try CMDirectory.parse(fixture("cmlist.json"))
        #expect(!servers.isEmpty)
        #expect(servers == servers.sorted { $0.load < $1.load })
        #expect(servers.allSatisfy { $0.url.scheme == "wss" && $0.url.absoluteString.hasSuffix("/cmsocket/") })
    }

    @Test func rejectsUnsuccessfulResponse() {
        let json = Data(#"{"response":{"serverlist":[],"success":false}}"#.utf8)
        #expect(throws: SteamError.directoryUnavailable) { try CMDirectory.parse(json) }
    }
}
