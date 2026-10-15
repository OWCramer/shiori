// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(tvOS)
import ObjectiveC
import UIKit

/// Keeps UIKit press events (the Siri Remote's and controllers' buttons as UIPresses) from
/// a running Ren'Py game. SDL would turn them into keys on top of the pad events Shiori
/// forwards (one d-pad press moved twice), and a Menu press nothing handles sends the app
/// to the Home Screen (a controller's B is Menu). The game gets both through GameController
/// instead (ControllerInput). Presses still flow while a text field is editing, so the
/// system keyboard works (DDLC's name entry).
@MainActor
enum PressFilter {
    private static var installed = false
    private static var editing = 0
    /// A text field is editing (the system keyboard is up): the pad goes to the keyboard,
    /// not the game.
    static var isEditing: Bool { editing > 0 }

    static func install() {
        guard !installed else { return }
        installed = true
        let center = NotificationCenter.default
        center.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { editing += 1 }
        }
        center.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { editing = max(0, editing - 1) }
        }
        guard let original = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacement = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.shiori_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }

    static func drops(_ event: UIEvent) -> Bool {
        event.type == .presses && editing == 0 && shiori_renpy_is_running() != 0
    }
}

extension UIApplication {
    @objc func shiori_sendEvent(_ event: UIEvent) {
        if MainActor.assumeIsolated({ PressFilter.drops(event) }) { return }
        shiori_sendEvent(event) // The original, after the exchange.
    }
}
#endif
