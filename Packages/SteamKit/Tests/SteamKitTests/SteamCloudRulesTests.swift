import Foundation
import Testing
@testable import SteamKit

/// Real `ufs` sections from PICS (Mac Steam client's appinfo cache, 2026-10-11).
private enum UFS {
    /// Harmonia (421660), Siglus: one folder listed once per pattern.
    static let harmonia = """
    "appinfo"
    {
        "appid" "421660"
        "ufs"
        {
            "quota" "12000000"
            "maxnumfiles" "100"
            "savefiles"
            {
                "0" { "root" "gameinstall" "path" "savedata" "pattern" "*.sav" "platforms" { "1" "Windows" } }
                "1" { "root" "gameinstall" "path" "savedata" "pattern" "*.bmp" "platforms" { "1" "Windows" } }
                "2" { "root" "gameinstall" "path" "savedata" "pattern" "*.ini" "platforms" { "1" "Windows" } }
                "3" { "root" "gameinstall" "path" "savedata_zh" "pattern" "*.sav" "platforms" { "1" "Windows" } }
                "4" { "root" "gameinstall" "path" "savedata_zh" "pattern" "*.bmp" "platforms" { "1" "Windows" } }
                "5" { "root" "gameinstall" "path" "savedata_zh" "pattern" "*.ini" "platforms" { "1" "Windows" } }
            }
        }
    }
    """

    /// Summer Pockets (897220), Siglus: three folders, one pattern each.
    static let summerPockets = """
    "appinfo"
    {
        "appid" "897220"
        "ufs"
        {
            "quota" "500000000"
            "maxnumfiles" "450"
            "savefiles"
            {
                "0" { "root" "gameinstall" "path" "savedata_en" "pattern" "*.*" }
                "1" { "root" "gameinstall" "path" "savedata" "pattern" "*.*" }
                "2" { "root" "gameinstall" "path" "savedata_zh" "pattern" "*.*" }
            }
        }
    }
    """

    static func config(_ text: String, appID: UInt32) throws -> UFSConfig {
        UFSConfig(app: AppInfo(appID: appID, changeNumber: 0, keyValues: try KeyValue.parseText(text)))
    }
}

private func cloudFile(_ prefix: String, _ name: String, size: UInt32 = 1, deleted: Bool = false) -> CloudFile {
    CloudFile(prefix: prefix, name: name, sha: Data(), timestamp: .now, size: size, isDeleted: deleted)
}

struct SteamCloudRulesTests {
    @Test func groupsHarmoniaPatternsByFolder() throws {
        let ufs = try UFS.config(UFS.harmonia, appID: 421_660)
        #expect(ufs.quota == 12_000_000)
        #expect(ufs.maxFiles == 100)
        let folders = ufs.saveFolders
        #expect(folders.map(\.path) == ["savedata", "savedata_zh"])
        #expect(folders[0].patterns == ["*.sav", "*.bmp", "*.ini"])
        #expect(folders[0].rules.count == 3)
        #expect(folders[0].cloudPrefix == "%gameinstall%savedata/")
        #expect(folders[0].recursive == false)
    }

    @Test func harmoniaSaveFolderTakesEveryPattern() throws {
        let savedata = try #require(try UFS.config(UFS.harmonia, appID: 421_660).saveFolders.first)
        // Each of the three rules' files, whatever the case Windows wrote them in.
        for name in ["0000.sav", "config.sav", "global.sav", "read.sav", "0000.bmp", "SAVE.BMP", "Setup.ini"] {
            #expect(savedata.matches(name: name), "\(name)")
        }
        for name in ["0000.png", "notes.txt", "sav", "0000.sav.bak"] {
            #expect(!savedata.matches(name: name), "\(name)")
        }
        #expect(savedata.holds(cloudFile("%GameInstall%savedata/", "0001.bmp")))
        #expect(savedata.holds(cloudFile("%GameInstall%savedata/", "siglus.ini")))
        #expect(!savedata.holds(cloudFile("%GameInstall%savedata/", "0000.png")))
        // The Chinese build's folder is its own.
        #expect(!savedata.holds(cloudFile("%GameInstall%savedata_zh/", "0000.sav")))
    }

    @Test func summerPocketsKeepsItsFoldersApart() throws {
        let folders = try UFS.config(UFS.summerPockets, appID: 897_220).saveFolders
        #expect(folders.map(\.path) == ["savedata_en", "savedata", "savedata_zh"])
        #expect(folders.allSatisfy { $0.patterns == ["*.*"] })
        let savedata = folders[1]
        // What the user's cloud holds for it (PC).
        for name in ["0000.png", "0000.sav", "config.sav", "global.sav", "read.sav"] {
            #expect(savedata.holds(cloudFile("%GameInstall%savedata/", name)), "\(name)")
        }
        #expect(!savedata.holds(cloudFile("%GameInstall%savedata_en/", "0000.sav")))
        #expect(!folders[0].holds(cloudFile("%GameInstall%savedata/", "0000.sav")))
    }

    @Test func subfoldersOnlyCountWhenAskedFor() throws {
        let text = """
        "appinfo"
        {
            "ufs"
            {
                "savefiles"
                {
                    "0" { "root" "gameinstall" "path" "savedata" "pattern" "*" "recursive" "1" }
                }
            }
        }
        """
        let folder = try #require(try UFS.config(text, appID: 1).saveFolders.first)
        let nested = cloudFile("%GameInstall%savedata/backup/", "data0.ksd")
        #expect(folder.recursive)
        #expect(!folder.holds(nested))
        #expect(folder.holds(nested, includingSubfolders: true))
        #expect(folder.holds(cloudFile("%GameInstall%savedata/", "data0.ksd")))
    }

    // MARK: - Quota

    @Test func harmoniaUploadWithinLimits() throws {
        let ufs = try UFS.config(UFS.harmonia, appID: 421_660)
        let remote = [
            cloudFile("%GameInstall%savedata/", "0000.sav", size: 40_000),
            cloudFile("%GameInstall%savedata/", "config.sav", size: 2_000),
            cloudFile("%GameInstall%savedata/", "global.sav", size: 3_000),
            cloudFile("%GameInstall%savedata/", "read.sav", size: 60_000),
        ]
        let check = ufs.checkUpload(remote: remote, uploads: [
            ("%GameInstall%savedata/0000.sav", 41_000), // replaces
            ("%GameInstall%savedata/0000.bmp", 200_000), // adds
        ])
        #expect(check.filesBefore == 4)
        #expect(check.filesAfter == 5)
        #expect(check.bytesBefore == 105_000)
        #expect(check.bytesAfter == 306_000)
        #expect(check.isAllowed)
    }

    @Test func refusesUploadOverHarmoniasFileCount() throws {
        let ufs = try UFS.config(UFS.harmonia, appID: 421_660)
        // 98 slots in the cloud already (any folder counts: the limit is per app).
        let remote = (0 ..< 97).map { cloudFile("%GameInstall%savedata/", String(format: "%04d.sav", $0), size: 100) }
            + [cloudFile("%GameInstall%savedata_zh/", "0000.sav", size: 100),
               cloudFile("%GameInstall%savedata/", "old.sav", size: 100, deleted: true)]
        // Two new files (a slot and its thumbnail) would make 100: allowed.
        var check = ufs.checkUpload(remote: remote, uploads: [
            ("%GameInstall%savedata/0097.sav", 100), ("%GameInstall%savedata/0097.bmp", 100),
        ])
        #expect(check.filesBefore == 98)
        #expect(check.filesAfter == 100)
        #expect(check.isAllowed)
        // Three would make 101: refused whole, not two of the three.
        check = ufs.checkUpload(remote: remote, uploads: [
            ("%GameInstall%savedata/0097.sav", 100), ("%GameInstall%savedata/0097.bmp", 100),
            ("%GameInstall%savedata/siglus.ini", 10),
        ])
        #expect(check.filesAfter == 101)
        #expect(check.exceedsFileCount)
        #expect(!check.exceedsQuota)
        #expect(!check.isAllowed)
    }

    @Test func replacingFilesMatchesPathsCaseInsensitively() throws {
        let ufs = try UFS.config(UFS.harmonia, appID: 421_660)
        let remote = (0 ..< 100).map { cloudFile("%GameInstall%savedata/", String(format: "%04d.sav", $0), size: 100) }
        // Full cloud; replacing one (root spelled differently) adds nothing.
        let check = ufs.checkUpload(remote: remote, uploads: [("%gameinstall%savedata/0005.sav", 120)])
        #expect(check.filesAfter == 100)
        #expect(check.bytesAfter == 10_020)
        #expect(check.isAllowed)
    }

    @Test func refusesUploadOverByteQuota() throws {
        let ufs = try UFS.config(UFS.summerPockets, appID: 897_220)
        let remote = [cloudFile("%GameInstall%savedata/", "read.sav", size: 499_000_000)]
        let over = ufs.checkUpload(remote: remote, uploads: [("%GameInstall%savedata/0001.sav", 2_000_000)])
        #expect(over.exceedsQuota)
        #expect(!over.exceedsFileCount)
        #expect(!over.isAllowed)
        let shrinking = ufs.checkUpload(remote: remote, uploads: [("%GameInstall%savedata/read.sav", 400_000_000)])
        #expect(shrinking.isAllowed)
    }

    @Test func cloudAlreadyOverItsLimitsCanStillReplace() throws {
        let ufs = try UFS.config(UFS.harmonia, appID: 421_660)
        let remote = (0 ..< 105).map { cloudFile("%GameInstall%savedata/", String(format: "%04d.sav", $0), size: 100) }
        #expect(ufs.checkUpload(remote: remote, uploads: [("%GameInstall%savedata/0001.sav", 100)]).isAllowed)
        #expect(!ufs.checkUpload(remote: remote, uploads: [("%GameInstall%savedata/0200.sav", 100)]).isAllowed)
    }

    @Test func noLimitsNoRefusal() throws {
        let ufs = try UFS.config("\"appinfo\" { \"ufs\" { } }", appID: 1)
        #expect(ufs.quota == nil && ufs.maxFiles == nil)
        let check = ufs.checkUpload(remote: [], uploads: (0 ..< 1000).map { ("%GameInstall%savedata/\($0).sav", 1 << 20) })
        #expect(check.isAllowed)
    }
}
