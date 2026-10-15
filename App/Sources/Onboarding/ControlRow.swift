// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
/// One line of the controls guide: what to do (with an SF Symbol) and what it does.
struct ControlRow: Hashable {
    let systemImage: String
    let input: String
    let action: String

    init(_ systemImage: String, _ input: String, _ action: String) {
        self.systemImage = systemImage
        self.input = input
        self.action = action
    }
}
#endif
