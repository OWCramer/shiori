// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Games that live on their publisher's servers (gacha games with accounts, anti-cheat and
/// live updates). Their engine doesn't matter: Shiori can't play them, and each has its own
/// official iOS app. The library marks them as online games rather than "Unity".
/// Steam app id → name, for reading this list.
enum OnlineGames {
    static let all: [UInt32: String] = [
        1976440: "CounterSide",
        3347400: "GIRLS' FRONTLINE 2: EXILIUM",
        3224770: "Umamusume: Pretty Derby",
        1973710: "Heaven Burns Red",
        3061570: "Persona5: The Phantom X",
    ]

    static func contains(_ appID: UInt32) -> Bool { all[appID] != nil }

    static let badge = "Online game"
    static let explanation = "Runs on its publisher's servers, so Shiori can't play it. Get the official app on the App Store."
}
