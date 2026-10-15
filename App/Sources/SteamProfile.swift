// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Observation

/// The signed-in player's Steam persona name and avatar, for Settings. Read from the public
/// Steam Community profile (`steamcommunity.com/profiles/<SteamID>?xml=1`, which carries
/// both even for private profiles), once per launch and kept on the device, so it shows at
/// once and offline. Read only.
@MainActor @Observable
final class SteamProfile {
    struct Info: Codable, Equatable {
        var steamID: UInt64
        var personaName: String
        var avatar: URL?
    }

    private(set) var info: Info?
    @ObservationIgnored private var loadedThisLaunch: UInt64?

    private static let key = "steamProfile"

    init() {
        #if DEBUG
        // The screenshot library's placeholder: a name and its initial, no Steam avatar.
        if ScreenshotLibrary.isOn {
            info = Info(steamID: 0, personaName: ScreenshotLibrary.accountName, avatar: nil)
            return
        }
        #endif
        if let data = UserDefaults.standard.data(forKey: Self.key) {
            info = try? JSONDecoder().decode(Info.self, from: data)
        }
    }

    /// The profile of this account, from the cache, refreshed once per launch.
    func load(steamID: UInt64) async {
        if info?.steamID != steamID { info = nil }
        guard loadedThisLaunch != steamID, steamID != 0 else { return }
        loadedThisLaunch = steamID
        guard let url = URL(string: "https://steamcommunity.com/profiles/\(steamID)?xml=1"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let fields = ProfileXML.parse(data)
        guard let name = fields["steamID"], !name.isEmpty else { return }
        let avatar = (fields["avatarFull"] ?? fields["avatarMedium"]).flatMap(URL.init(string:))
        let fresh = Info(steamID: steamID, personaName: name, avatar: avatar)
        if fresh != info {
            info = fresh
            UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: Self.key)
        }
    }

    func forget() {
        info = nil
        loadedThisLaunch = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

/// The top-level text fields of a Steam Community profile's XML.
private final class ProfileXML: NSObject, XMLParserDelegate {
    private var fields: [String: String] = [:]
    private var depth = 0
    private var current: String?
    private var text = ""

    static func parse(_ data: Data) -> [String: String] {
        let reader = ProfileXML()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.fields
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        depth += 1
        // <profile> is depth 1; its fields are depth 2.
        if depth == 2 { current = name; text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        if current != nil, let string = String(data: block, encoding: .utf8) { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if depth == 2, let current {
            fields[current] = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.current = nil
        }
        depth -= 1
    }
}
