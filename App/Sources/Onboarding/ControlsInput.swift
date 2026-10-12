#if os(iOS)
import GameController
import UIKit

/// The ways to play a game, each a section of the controls guide.
enum ControlsInput: String, CaseIterable, Identifiable {
    case touch, pointer, keyboard, controller

    var id: String { rawValue }

    var title: String {
        switch self {
        case .touch: "Touch"
        case .pointer: "Trackpad and Mouse"
        case .keyboard: "Keyboard"
        case .controller: "Controller"
        }
    }

    var systemImage: String {
        switch self {
        case .touch: "hand.tap"
        case .pointer: "cursorarrow"
        case .keyboard: "keyboard"
        case .controller: "gamecontroller"
        }
    }

    /// Whether one is connected now (touch always is). The first-launch splash shows only
    /// these; the guide in Settings and the game page shows every section.
    @MainActor var isConnected: Bool {
        switch self {
        case .touch: true
        case .pointer: GCMouse.current != nil
        case .keyboard: GCKeyboard.coalesced != nil
        case .controller: GCController.controllers().contains { $0.extendedGamepad != nil }
        }
    }
}
#endif
