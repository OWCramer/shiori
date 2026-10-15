// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
/// How each engine plays, the one place the controls guide reads from (the first-launch
/// splash, the game page's Controls…, Settings › Controls). Keep it in step with the engines'
/// input code and spec.md's Touch decision and engine sections when gestures change.
enum ControlsTable {
    /// The engines with a guide, in the order Settings lists them.
    static let engines = ["renpy", "artemis", "kirikiri", "siglus", "luca", "catsystem2"]

    static func controls(for engine: String) -> EngineControls {
        switch engine {
        case "renpy": renPy
        case "artemis": artemis
        case "kirikiri": kiriKiri
        case "siglus": siglus
        case "luca": luca
        case "catsystem2": catSystem
        default: generic(engine)
        }
    }

    // MARK: - Rows several engines share

    private static let tap = ControlRow("hand.tap", "Tap", "Read on, or choose what you tap")
    private static let twoFingerHold = ControlRow("hand.raised", "Two-finger hold", "Leave the game")
    private static let twoFingerSwipeDownBacklog = ControlRow("arrow.down.to.line", "Two-finger swipe down", "Backlog")
    private static let twoFingerSwipeRightSkip = ControlRow("forward", "Two-finger swipe right", "Skip")
    private static let twoFingerSwipeUpAuto = ControlRow("arrow.up", "Two-finger swipe up", "Turn auto on or off")
    private static let click = ControlRow("cursorarrow.click", "Click", "Read on, or choose")
    private static let hover = ControlRow("cursorarrow.motionlines", "Hover", "Highlights the game's buttons")
    private static let escape = ControlRow("escape", "Escape", "Menu, or back out")
    private static let returnKey = ControlRow("return", "Return or Space", "Read on")
    private static let controlKey = ControlRow("control", "Hold Control", "Skip")
    private static let arrowKeys = ControlRow("arrow.up.arrow.down", "Arrow keys", "Move between buttons")
    private static let pageUp = ControlRow("arrow.up.to.line", "Page Up", "Backlog")

    /// The PC keyboard-and-mouse pad mapping KiriKiri, Siglus and CatSystem2 share.
    private static let pcPad = [
        ControlRow("a.circle", "A", "Read on, or press"),
        ControlRow("b.circle", "B", "Right click: menu, or back out"),
        ControlRow("dpad", "D-pad or left stick", "Move between buttons"),
        ControlRow("y.circle", "Y or LB", "Backlog"),
        ControlRow("rb.rectangle.roundedbottom", "Hold RB or RT", "Skip"),
        ControlRow("x.circle", "X", "Turn auto on or off"),
        ControlRow("line.3.horizontal.circle", "Menu", "The game's menu"),
        ControlRow("ellipsis.circle", "Options", "Leave the game"),
    ]

    // MARK: - Engines

    private static let renPy = EngineControls(
        engine: "renpy",
        note: "Quit from the game's menu or hold two fingers. Shiori closes; reopen it for your library.",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "Game menu"),
            twoFingerSwipeDownBacklog,
            twoFingerSwipeRightSkip,
            twoFingerSwipeUpAuto,
            ControlRow("hand.point.up.left", "Touch and hold", "Hide the text box"),
            ControlRow("arrow.up.and.down", "Drag", "Scroll lists and the history"),
            ControlRow("hand.raised", "Two-finger hold", "Quit"),
        ],
        pointer: [
            click,
            ControlRow("cursorarrow.rays", "Secondary click", "Game menu"),
            ControlRow("arrow.up.to.line", "Scroll up", "Roll back"),
            hover,
        ],
        keyboard: [
            returnKey,
            ControlRow("escape", "Escape", "Game menu"),
            ControlRow("h.square", "H", "Hide the text box"),
            controlKey,
            ControlRow("arrow.right.to.line", "Tab", "Turn skip on or off"),
            ControlRow("arrow.up.to.line", "Page Up", "Roll back"),
        ],
        controller: [
            ControlRow("a.circle", "A", "Read on, or choose"),
            ControlRow("b.circle", "B or Start", "Game menu"),
            ControlRow("y.circle", "Y", "Hide the text box"),
            ControlRow("dpad", "D-pad", "Move between choices"),
        ]
    )

    private static let artemis = EngineControls(
        engine: "artemis",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "System menu"),
            ControlRow("arrow.right", "Swipe right (or two fingers)", "Skip"),
            ControlRow("arrow.left", "Swipe left", "Back out, or hide the text"),
            ControlRow("arrow.down", "Swipe down (or two fingers)", "Backlog"),
            ControlRow("hand.point.up.left", "Touch and hold", "Turn auto on or off"),
            twoFingerSwipeUpAuto,
            twoFingerHold,
        ],
        pointer: [
            click,
            ControlRow("cursorarrow.rays", "Secondary click", "System menu, or back out"),
            ControlRow("arrow.up.to.line", "Scroll up", "Backlog"),
            hover,
        ],
        keyboard: [
            returnKey,
            escape,
            ControlRow("arrow.up.arrow.down", "Arrow keys", "Move between buttons"),
            controlKey,
            pageUp,
        ],
        controller: [
            ControlRow("l.joystick", "Left stick", "Move the pointer"),
            ControlRow("dpad", "D-pad", "Jump between buttons"),
            ControlRow("a.circle", "A", "Click, or read on"),
            ControlRow("b.circle", "B or Menu", "Right click: menu, or back out"),
            ControlRow("y.circle", "Y or LB", "Backlog"),
            ControlRow("rb.rectangle.roundedbottom", "Hold RB or RT", "Skip"),
            ControlRow("x.circle", "X", "Turn auto on or off"),
            ControlRow("ellipsis.circle", "Options", "Leave the game"),
        ]
    )

    private static let kiriKiri = EngineControls(
        engine: "kirikiri",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "Right click: menu, or back out"),
            twoFingerSwipeDownBacklog,
            ControlRow("forward", "Two-finger swipe right", "Skip until you tap"),
            ControlRow("arrow.up", "Two-finger swipe up", "Turn auto on or off"),
            twoFingerHold,
        ],
        pointer: [
            click,
            ControlRow("cursorarrow.rays", "Secondary click", "Right click: menu, or back out"),
            ControlRow("arrow.up.to.line", "Scroll up", "Backlog"),
            hover,
        ],
        keyboard: [returnKey, escape, controlKey, arrowKeys, pageUp],
        controller: pcPad
    )

    private static let siglus = EngineControls(
        engine: "siglus",
        note: "Auto is the AUTO button on the message window.",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "Right click: menu, or back out"),
            twoFingerSwipeDownBacklog,
            ControlRow("forward", "Two-finger swipe right", "Skip until you tap"),
            twoFingerHold,
        ],
        pointer: kiriKiri.pointer,
        keyboard: kiriKiri.keyboard,
        controller: pcPad.filter { $0.input != "X" }
    )

    private static let luca = EngineControls(
        engine: "luca",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "Menu"),
            ControlRow("arrow.up", "Swipe up", "Menu"),
            ControlRow("arrow.right", "Swipe right (or two fingers)", "Skip"),
            ControlRow("arrow.left", "Swipe left", "Back a line"),
            ControlRow("arrow.down", "Swipe down (or two fingers)", "Backlog"),
            ControlRow("hand.point.up.left", "Touch and hold the text", "Turn auto on or off"),
            twoFingerSwipeUpAuto,
            twoFingerHold,
        ],
        pointer: [
            click,
            ControlRow("cursorarrow.rays", "Secondary click", "Menu"),
            ControlRow("arrow.up.to.line", "Scroll up", "Backlog"),
            hover,
        ],
        keyboard: [
            returnKey,
            ControlRow("escape", "Escape", "Back out, or the menu"),
            ControlRow("arrow.up.arrow.down", "Arrow keys", "Move between buttons and choices"),
            controlKey,
            pageUp,
        ],
        controller: [
            ControlRow("a.circle", "A", "Read on, or press"),
            ControlRow("b.circle", "B", "Back out, or the menu"),
            ControlRow("dpad", "D-pad or left stick", "Move between buttons and choices"),
            ControlRow("y.circle", "Y or LB", "Backlog"),
            ControlRow("rb.rectangle.roundedbottom", "Hold RB or RT", "Skip"),
            ControlRow("x.circle", "X", "Turn auto on or off"),
            ControlRow("line.3.horizontal.circle", "Menu", "Options"),
            ControlRow("ellipsis.circle", "Options", "Leave the game"),
        ]
    )

    private static let catSystem = EngineControls(
        engine: "catsystem2",
        touch: [
            tap,
            ControlRow("hand.tap.fill", "Two-finger tap", "Hide the window, or back out"),
            twoFingerSwipeDownBacklog,
            ControlRow("arrow.right", "Swipe right (or two fingers)", "Skip"),
            ControlRow("hand.point.up.left", "Touch and hold the window", "Turn auto on or off"),
            twoFingerSwipeUpAuto,
            twoFingerHold,
        ],
        pointer: [
            click,
            ControlRow("cursorarrow.rays", "Secondary click", "Hide the window, or back out"),
            ControlRow("arrow.up.to.line", "Scroll up", "Backlog"),
            ControlRow("arrow.down.to.line", "Scroll down", "Read on"),
            hover,
        ],
        keyboard: [
            returnKey,
            ControlRow("escape", "Escape", "Hide the window, or back out"),
            controlKey,
            ControlRow("arrow.up.arrow.down", "Arrow keys", "Move between buttons"),
            pageUp,
        ],
        controller: [
            ControlRow("a.circle", "A", "Read on, or press"),
            ControlRow("b.circle", "B", "Hide the window, or back out"),
            ControlRow("dpad", "D-pad or left stick", "Move between buttons"),
            ControlRow("y.circle", "Y or LB", "Backlog"),
            ControlRow("rb.rectangle.roundedbottom", "Hold RB or RT", "Skip"),
            ControlRow("x.circle", "X", "Turn auto on or off"),
            ControlRow("line.3.horizontal.circle", "Menu", "CONFIG"),
            ControlRow("ellipsis.circle", "Options", "Leave the game"),
        ]
    )

    /// An engine without its own entry: what every engine shares.
    private static func generic(_ engine: String) -> EngineControls {
        EngineControls(
            engine: engine,
            touch: [tap, ControlRow("hand.tap.fill", "Two-finger tap", "Menu"), twoFingerHold],
            pointer: [click, ControlRow("cursorarrow.rays", "Secondary click", "Menu")],
            keyboard: [returnKey, escape],
            controller: []
        )
    }
}
#endif
