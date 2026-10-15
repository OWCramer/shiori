// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
/// How a game on one engine plays, by input: one entry of `ControlsTable`.
struct EngineControls {
    /// The engine id (`renpy`, `artemis`, …), as in `EngineMatch.engine`.
    let engine: String
    /// A line under the title, for what's particular to the engine (optional).
    var note: String?
    let touch: [ControlRow]
    let pointer: [ControlRow]
    let keyboard: [ControlRow]
    /// Empty when the engine doesn't take a controller.
    let controller: [ControlRow]
    /// Said in place of the controller's rows when it has none.
    var noController = "This game doesn't support controllers."

    func rows(for input: ControlsInput) -> [ControlRow] {
        switch input {
        case .touch: touch
        case .pointer: pointer
        case .keyboard: keyboard
        case .controller: controller
        }
    }
}
#endif
