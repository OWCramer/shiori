// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import Foundation
import Observation

/// The controls guide shown over the hub: once per engine the first time a game on it is
/// played (before the engine takes the screen; Ren'Py takes the whole app), and whenever the
/// game page's Controls… asks. Presented by `RootView`.
@MainActor @Observable
final class ControlsGuide {
    static let shared = ControlsGuide()

    struct Request: Identifiable {
        let engine: String
        /// The game Play was tapped for: it starts once the guide is closed with Play.
        var playAfter: UInt32?
        var gameName: String?
        var id: String { "\(engine)-\(playAfter ?? 0)" }
    }

    var request: Request?

    private static let seenKey = "ControlsGuideSeenEngines"
    private static let offKey = "ControlsGuideOff"

    /// Before Play: shows the guide instead, if this engine's hasn't been seen. True when it
    /// did, so the caller waits for it to close.
    func interceptPlay(appID: UInt32, engine: String, gameName: String) -> Bool {
        guard Self.isDue(engine) else { return false }
        request = Request(engine: engine, playAfter: appID, gameName: gameName)
        return true
    }

    func show(engine: String, gameName: String? = nil) {
        request = Request(engine: engine, gameName: gameName)
    }

    /// Closed with Got It / Play: not shown again for this engine.
    func markSeen(_ engine: String) {
        var seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [])
        seen.insert(engine)
        UserDefaults.standard.set(Array(seen).sorted(), forKey: Self.seenKey)
    }

    /// "Don't Show Again": no guide before any game, whatever the engine.
    func turnOff() {
        UserDefaults.standard.set(true, forKey: Self.offKey)
    }

    /// Settings' "Show Before Playing Again": every engine's guide is due once more.
    func reset() {
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
        UserDefaults.standard.removeObject(forKey: Self.offKey)
    }

    private static func isDue(_ engine: String) -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: offKey) else { return false }
        #if DEBUG || SHIORI_AUTOMATION
        // Scripted runs (`-ShioriAutoPlay`) go straight into the game, unless
        // `-ShioriShowControls play` asks for the guide Play would show.
        if defaults.integer(forKey: "ShioriAutoPlay") != 0, defaults.string(forKey: "ShioriShowControls") != "play" { return false }
        #endif
        return !(defaults.stringArray(forKey: seenKey) ?? []).contains(engine)
    }

    #if DEBUG
    /// `-ShioriShowControls <engine>` (debug): the guide for that engine at launch, as if
    /// Play had been tapped, without starting anything. (`play`, with `-ShioriAutoPlay <appid>`:
    /// the real guide before that game, if it's due.)
    func showDebugRequest() {
        guard let engine = UserDefaults.standard.string(forKey: "ShioriShowControls"), !engine.isEmpty, engine != "play" else { return }
        request = Request(engine: engine, playAfter: 0, gameName: "Preview")
        // One sheet at a time: the guide wins over a pending What's New unless both were asked for.
        if !UserDefaults.standard.bool(forKey: "ShioriShowWhatsNew") { WhatsNew.shared.pending = nil }
    }
    #endif
}
#endif
