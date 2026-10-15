// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import UIKit

/// A hardware keyboard's keys as the PC games know them. Without these, Escape reached UIKit,
/// which took it as "dismiss" and closed the game's full-screen cover without leaving it
/// properly, so every game screen keeps the keys it handles for itself.
extension UIKeyboardHIDUsage {
    /// The Windows virtual-key code for the keys the engines read (Siglus, KiriKiri).
    var windowsVirtualKey: Int32? {
        switch self {
        case .keyboardEscape: 0x1B
        case .keyboardReturnOrEnter, .keypadEnter: 0x0D
        case .keyboardSpacebar: 0x20
        case .keyboardLeftArrow: 0x25
        case .keyboardUpArrow: 0x26
        case .keyboardRightArrow: 0x27
        case .keyboardDownArrow: 0x28
        case .keyboardLeftControl, .keyboardRightControl: 0x11
        case .keyboardLeftShift, .keyboardRightShift: 0x10
        case .keyboardDeleteOrBackspace: 0x08
        default: nil
        }
    }
}

extension Set where Element == UIPress {
    /// Splits presses into the keys a game handles and the rest, which go on up the chain.
    func splitKeys(_ handled: (UIKeyboardHIDUsage) -> Bool) -> (keys: [UIKeyboardHIDUsage], rest: Set<UIPress>) {
        var keys: [UIKeyboardHIDUsage] = []
        var rest = Set<UIPress>()
        for press in self {
            if let code = press.key?.keyCode, handled(code) { keys.append(code) } else { rest.insert(press) }
        }
        return (keys, rest)
    }
}
#endif
