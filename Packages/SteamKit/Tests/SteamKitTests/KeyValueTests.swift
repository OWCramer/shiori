import Foundation
import Testing
@testable import SteamKit

struct KeyValueTextTests {
    @Test func parsesNestedQuotedAndBareTokens() throws {
        let kv = try KeyValue.parseText("""
        "appinfo"
        {
            // comment
            "appid"     "451760"
            "common"
            {
                "name"  "Say \\"hi\\"\\tthere"
                type    Game
                "oslist" "windows" [$WIN32]
            }
            "config" { "installdir" "Highway Blossoms" }
        }
        """)
        #expect(kv.name == "appinfo")
        #expect(kv["appid"]?.uint32 == 451_760)
        #expect(kv[path: "common", "name"]?.value == "Say \"hi\"\tthere")
        #expect(kv[path: "COMMON", "Type"]?.value == "Game") // case-insensitive lookup
        #expect(kv[path: "common", "oslist"]?.value == "windows")
        #expect(kv[path: "config", "installdir"]?.value == "Highway Blossoms")
        #expect(kv["missing"] == nil)
    }

    @Test func dropsTrailingNulFromPICSBuffer() throws {
        let data = Data("\"appinfo\" { \"appid\" \"7\" }".utf8) + Data([0])
        #expect(try KeyValue.parseText(data)["appid"]?.value == "7")
    }

    @Test func rejectsUnterminatedDocument() {
        #expect(throws: KeyValue.ParseError.unexpectedEnd) { try KeyValue.parseText("\"a\" { \"b\" \"c\"") }
    }
}

struct KeyValueBinaryTests {
    @Test func roundTripsMachineIDShape() throws {
        let tree = KeyValue(name: "MessageObject", children: [
            KeyValue(name: "BB3", value: "aa"),
            KeyValue(name: "FF2", value: "bb"),
        ])
        let data = tree.binaryEncoded()
        // type None, name, two string children, end of node, end of document.
        var expected = Data([0]) + Data("MessageObject\0".utf8)
        expected += Data([1]) + Data("BB3\0aa\0".utf8)
        expected += Data([1]) + Data("FF2\0bb\0".utf8)
        expected += Data([8, 8])
        #expect(data == expected)

        var reader = ByteReader(data)
        #expect(try KeyValue.parseBinary(&reader) == tree)
    }

    @Test func readsNumericTypes() throws {
        var data = Data([0]) + Data("root\0".utf8)
        data += Data([2]) + Data("int\0".utf8) + Data([0xFE, 0xFF, 0xFF, 0xFF]) // -2
        data += Data([7]) + Data("u64\0".utf8) + Data([1, 0, 0, 0, 0, 0, 0, 0x80])
        data += Data([3]) + Data("float\0".utf8) + Data([0, 0, 0xC0, 0x3F]) // 1.5
        data += Data([0]) + Data("child\0".utf8) + Data([8])
        data += Data([8])

        var reader = ByteReader(data)
        let kv = try KeyValue.parseBinary(&reader)
        #expect(kv["int"]?.value == "-2")
        #expect(kv["u64"]?.uint64 == 0x8000_0000_0000_0001)
        #expect(kv["float"]?.value == "1.5")
        #expect(kv["child"]?.children == [])
    }

    @Test func machineIDIsStablePerSeed() {
        let a = SteamConfiguration(deviceName: "x", deviceSeed: "seed-1")
        let b = SteamConfiguration(deviceName: "y", deviceSeed: "seed-1")
        let c = SteamConfiguration(deviceName: "x", deviceSeed: "seed-2")
        #expect(a.machineID == b.machineID)
        #expect(a.loginID == b.loginID)
        #expect(a.machineID != c.machineID)
    }
}

/// Real PICS buffers captured with `steamkit-cli anon 451760 --fixtures Tests/SteamKitTests/Fixtures`.
struct PICSFixtureTests {
    @Test func parsesHighwayBlossomsAppInfo() throws {
        let kv = try KeyValue.parseText(fixture("app_451760.vdf"))
        let app = AppInfo(appID: 451_760, changeNumber: 0, keyValues: kv)
        #expect(app.name == "Highway Blossoms")
        #expect(app.isGame)
        #expect(kv["depots"] != nil)
        #expect(app.isVisualNovel)
        #expect(app.storeTags.first == 44868)
        let base = "https://shared.steamstatic.com/store_item_assets/steam/apps/451760/"
        #expect(app.capsuleURL()?.absoluteString == base + "library_600x900.jpg")
        #expect(app.capsuleURL(large: true)?.absoluteString == base + "library_600x900_2x.jpg")
        #expect(app.heroURL()?.absoluteString == base + "library_hero.jpg")
        #expect(app.logoURL()?.absoluteString == base + "logo.png")
        #expect(app.headerURL?.absoluteString == base + "header.jpg")
    }

    @Test func parsesAnonymousPackageInfo() throws {
        let kv = try KeyValue.parsePackageInfo(fixture("package_17906.bin"))
        let package = PackageInfo(packageID: 17906, keyValues: kv)
        #expect(kv["packageid"]?.uint32 == 17906)
        #expect(!package.appIDs.isEmpty)
    }
}
