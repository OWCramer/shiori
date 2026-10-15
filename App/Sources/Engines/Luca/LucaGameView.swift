import GameController
import LucaKit
import Metal
import SwiftUI
import UIKit

/// Plays a Luca System game (Summer Pockets REFLECTION BLUE) with LucaKit. The scripts tell
/// the stage what to show; the screens the PC game draws in its executable (title, menu,
/// save and load, backlog) are Shiori's own, dressed in the game's art where it has some.
final class LucaGameViewController: UIViewController, UIGestureRecognizerDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var onFirstFrame: (() -> Void)?
    private var game: LucaGame?
    private var player: LucaPlayer?
    private let audio = LucaAudio()
    private var displayLink: CADisplayLink?
    private var leaving = false

    // Stage: 1920×1080 game space, letterboxed.
    private let stageSize = CGSize(width: 1920, height: 1080)
    private var renderer: LucaRenderer?
    private var windowMask: MTLTexture?
    /// Chapters, event pictures and music reached, for the title's Chapter and Extras.
    private var extras = LucaExtrasRecord()
    private var extrasLayerKey = ""
    /// The narration box (profile.narration), when the game has one.
    private var narrationMask: MTLTexture?
    /// Whether the line on screen is narration shown in the narration box.
    private var narrating: Bool { profile.narration != nil && narrationMask != nil && (player?.message?.narration ?? false) }
    /// Pictures on screen now (texture ids), kept when the texture cache trims.
    private var onScreen = Set<Int>()
    /// Pictures being decoded and uploaded off the main thread.
    private let prefetchQueue = DispatchQueue(label: "luca.prefetch", qos: .userInitiated)
    private var prefetching = Set<Int>()
    private let prefetched = LucaPrefetched()
    private var framesSincePrefetch = 0
    private var lastDraw = -1
    private var transitionRunning = false

    // Text window
    /// MWIN0's shape starts 100 px down, so the window's top edge shows at y 791, as in the
    /// PC game; stretched to the bottom of the screen.
    private var windowRect: CGRect { profile.window.rect }
    /// The window's teal, measured from the PC game.
    private var windowTint: SIMD4<Float> {
        let c = profile.window.colour
        return SIMD4<Float>(c.x, c.y, c.z, settings.windowAlpha(base: profile.window.opacity))
    }
    /// The speaker's name plate (mwin1920_0, white, tinted) and the flapping butterfly that
    /// says a tap reads on (__SYS_MW01_KEY00, 24 frames).
    private let namePlate = UIImageView()
    private let pageMarker = UIImageView()
    private let overlay = UIView()
    /// The speaker's name and the line, drawn in the game's own bitmap font (LucaTypeset);
    /// the line is revealed as it types through a mask.
    private let nameView = UIImageView()
    private let textView = UIImageView()
    private let textMask = CAShapeLayer()
    private var typeset: LucaTypeset?
    private var composedKey: String?
    /// Loaded font sizes by "FACE size" (nil: the game has no such size).
    private var loadedFonts: [String: (main: LucaFont, patch: LucaFont?)?] = [:]
    private var shownMessage: LucaMessage?
    private var lastHadFace = false
    private var faceRects: [Int: CGRect] = [:]
    private var revealed = 0
    private var revealTarget = 0
    private var choiceStack: UIStackView?
    /// The island map behind the day's map choice.
    private var mapBackdrop: UIImageView?
    private var shownChoices: [String]?
    private var choiceImages: [CGImage] = []
    private var titleView: UIView?
    private var bootShown = false
    private var systemMenu: LucaSystemMenu?
    private var saveScreen: LucaSaveScreen?
    private var textHidden = false
    /// What this game's executable draws for itself (LucaProfile).
    private var profile = LucaProfile.plain
    private var optionsScreen: LucaOptionsScreen?
    private var messageLog: LucaMessageLog?
    private var settings = LucaSettings()
    private var readLog: LucaReadLog?
    /// Whether the line on screen had been read before (on any playthrough).
    private var lineWasRead = false
    private var lineHasVoice = false
    /// Lines passed since Skip was turned on.
    private var linesSkipped = 0
    private var revealCarry = 0.0
    private var windowBar: LucaWindowBar?
    /// Auto reads on a moment after each line (and its voice) finishes; Skip races to the
    /// next choice. A tap stops either.
    private enum ReadMode { case normal, auto, skip }
    private var readMode = ReadMode.normal
    private var lineDoneAt: CFTimeInterval?
    #if DEBUG
    /// `-ShioriLucaAuto N`: reads on through N lines by itself (first choice picked), and
    /// `-ShioriLucaNewGame YES` starts a new game from the title, for unattended runs;
    /// `-ShioriLucaAutoStopAtChoice YES` stops at the first choice instead.
    private var autoLines = UserDefaults.standard.integer(forKey: "ShioriLucaAuto")
    #endif

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void = {}, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onFirstFrame = onFirstFrame
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    #if os(tvOS)
    @objc private func playPausePressed() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil,
              optionsScreen == nil, messageLog == nil, player?.choices == nil else { return }
        windowBarPicked(.auto)
    }

    @objc private func playPauseHeld(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        showBacklog()
    }
    #else
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    #endif

    private var saves: URL { gameFolder.appendingPathComponent("saves", isDirectory: true) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // The stage draws with Metal (LucaRenderer); text, choices and menus sit over it.
        renderer = LucaRenderer()
        if let renderer { view.layer.addSublayer(renderer.layer) }

        overlay.isUserInteractionEnabled = true
        view.addSubview(overlay)
        namePlate.tintColor = UIColor(red: 0, green: 0.55, blue: 0.62, alpha: 0.75)
        overlay.addSubview(namePlate)
        for view in [nameView, textView] {
            view.isUserInteractionEnabled = false
            view.layer.minificationFilter = .trilinear
            overlay.addSubview(view)
        }
        textMask.fillColor = UIColor.white.cgColor
        textView.layer.mask = textMask
        overlay.addSubview(pageMarker)

        // Tap reads on; two-finger tap opens the menu; swipe down shows the backlog; a
        // two-finger hold leaves.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        #if os(tvOS)
        // The Siri Remote: the game's screens are buttons the focus engine moves between, a
        // click reads on; Menu opens the system menu (held, it leaves the game); Play/Pause
        // toggles Auto (held, the Message Log).
        let menuHold = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        menuHold.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuHold.minimumPressDuration = 0.8
        view.addGestureRecognizer(menuHold)
        let menuPress = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        menuPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        menuPress.require(toFail: menuHold)
        view.addGestureRecognizer(menuPress)
        let playHold = UILongPressGestureRecognizer(target: self, action: #selector(playPauseHeld(_:)))
        playHold.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        playHold.minimumPressDuration = 0.8
        view.addGestureRecognizer(playHold)
        let playPress = UITapGestureRecognizer(target: self, action: #selector(playPausePressed))
        playPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.playPause.rawValue)]
        playPress.require(toFail: playHold)
        view.addGestureRecognizer(playPress)
        #else
        let menu = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        menu.numberOfTouchesRequired = 2
        view.addGestureRecognizer(menu)
        tap.require(toFail: menu)
        // The PC game's touch controls (manual page 2): flick up for the system menu.
        let flick = UISwipeGestureRecognizer(target: self, action: #selector(showMenu))
        flick.direction = .up
        view.addGestureRecognizer(flick)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(showBacklog))
        history.direction = .down
        view.addGestureRecognizer(history)
        let skip = UISwipeGestureRecognizer(target: self, action: #selector(flickedRight))
        skip.direction = .right
        view.addGestureRecognizer(skip)
        let back = UISwipeGestureRecognizer(target: self, action: #selector(flickedLeft))
        back.direction = .left
        view.addGestureRecognizer(back)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldOnWindow(_:)))
        hold.minimumPressDuration = 0.6
        hold.delegate = self
        view.addGestureRecognizer(hold)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)
        // A trackpad or mouse: flicks and holds are a finger's, a secondary click opens the
        // system menu (the PC's right button), scrolling up opens the Message Log (the wheel).
        for gesture in [flick, history, skip, back, hold] as [UIGestureRecognizer] { gesture.fingersOnly() }
        view.addSecondaryClick(target: self, action: #selector(showMenu))
        view.addScroll(target: self, action: #selector(scrolled(_:)))
        // The shared two-finger swipes (spec, Touch): right skips, up toggles auto, down the
        // Message Log, as in every engine.
        view.addSwipe(.right, fingers: 2, target: self, action: #selector(flickedRight))
        view.addSwipe(.up, fingers: 2, target: self, action: #selector(swipedAuto))
        view.addSwipe(.down, fingers: 2, target: self, action: #selector(showBacklog))
        // The pointer lights up the button under it (on every screen) and draws the game's
        // cursor; the pad and the keys move a focus between them.
        view.addHover(target: self, action: #selector(hovered(_:)))
        let pointer = UIPointerInteraction(delegate: self)
        view.addInteraction(pointer)
        pointerInteraction = pointer
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000
        cursorLayer.contentsGravity = .resize
        view.layer.addSublayer(cursorLayer)
        loadCursor()
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
        #if DEBUG
        scheduleDebugInput()
        #endif
        #endif

        do {
            let game = try LucaGame(root: gameFolder.appendingPathComponent("base", isDirectory: true),
                                    patch: gameFolder.appendingPathComponent("patch", isDirectory: true))
            self.game = game
            profile = LucaProfile.detect(game)
            NSLog("Luca: %@ (%@)", profile.name, game.entryScript)
            // MWIN0 is the window's shape in white; the engine tints it.
            if let id = game.imageID(named: "MWIN0") { windowMask = renderer?.textures.texture(id, game: game) }
            if let box = profile.narration?.box, let id = game.imageID(named: box) {
                narrationMask = renderer?.textures.texture(id, game: game)
            }
            if let plate = picture("mwin1920_0") {
                namePlate.image = UIImage(cgImage: plate).withRenderingMode(.alwaysTemplate)
            }
            if let marker = profile.pageMarker, let sheet = picture(marker.name) {
                if let size = marker.frame {
                    pageMarker.animationImages = (0..<(sheet.width / size)).compactMap {
                        sheet.cropping(to: CGRect(x: $0 * size, y: 0, width: size, height: size)).map { UIImage(cgImage: $0) }
                    }
                    pageMarker.animationDuration = 0.8
                } else {
                    pageMarker.animationImages = [UIImage(cgImage: sheet)]
                }
            }
            if let buttons = profile.choiceSheet.flatMap(picture) {
                // Four states, 225 px each: blue, gold (highlighted), gold (pressed), grey.
                choiceImages = (0..<4).compactMap { buttons.cropping(to: CGRect(x: 0, y: $0 * 225, width: buttons.width, height: 225)) }
            }
            try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
            settings = LucaSettings.load(from: saves)
            readLog = LucaReadLog(saves: saves)
            extras = LucaExtrasRecord.load(from: saves)
            backfillChapters(game)
            if let sheet = profile.shortcutSheet.flatMap(picture) {
                let bar = LucaWindowBar(sheet: sheet)
                bar.onPick = { [weak self] item in self?.windowBarPicked(item) }
                bar.isHidden = true
                overlay.addSubview(bar)
                windowBar = bar
            }
            applySettings()
            showTitle()
        } catch {
            NSLog("Luca: couldn't open the game: %@", String(describing: error))
            let alert = UIAlertController(title: "This game can't start", message: String(describing: error), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Leave", style: .default) { [weak self] _ in self?.leave() })
            DispatchQueue.main.async { self.present(alert, animated: true) }
        }
        // While still in front (the thumbnail needs the GPU), the place is kept in a slot the
        // game's Load screen lists.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.leaving else { return }
                self.savePlace(reason: "leaving the screen")
            }
        }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    #if os(iOS)
    override var canBecomeFirstResponder: Bool { true }

    /// The PC's keys: Enter and Space read on (or press the button the arrows picked), the
    /// arrows move between a screen's buttons and choices (left and right turn a slider, up
    /// and down scroll the Message Log), Ctrl held skips, Escape backs out of a screen or
    /// opens the menu, Page Up the Message Log.
    private static let gameKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardEscape, .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar,
        .keyboardUpArrow, .keyboardDownArrow, .keyboardLeftArrow, .keyboardRightArrow,
        .keyboardLeftControl, .keyboardRightControl, .keyboardPageUp, .keyboardPageDown,
    ]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { Self.gameKeys.contains($0) }
        for key in keys { keyDown(key) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { Self.gameKeys.contains($0) }
        for key in keys where key == .keyboardLeftControl || key == .keyboardRightControl { holdSkip(false) }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    private func keyDown(_ key: UIKeyboardHIDUsage) {
        guard !alertShown else { return }
        switch key {
        case .keyboardEscape: back()
        case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar: confirm()
        case .keyboardUpArrow: arrow(dx: 0, dy: -1)
        case .keyboardDownArrow: arrow(dx: 0, dy: 1)
        case .keyboardLeftArrow: arrow(dx: -1, dy: 0)
        case .keyboardRightArrow: arrow(dx: 1, dy: 0)
        case .keyboardLeftControl, .keyboardRightControl: holdSkip(true)
        case .keyboardPageUp: if messageLog == nil { showBacklog() }
        case .keyboardPageDown: messageLog?.close()
        default: break
        }
    }

    // MARK: Focus (keys and pad)

    private let controlFocus = ControlFocus()

    /// The page over the game (Chapter, Extras, the Manual, a picture), not an alert.
    private var topPage: UIViewController? {
        var page = presentedViewController
        while let next = page?.presentedViewController { page = next }
        return page is UIAlertController ? nil : page
    }

    private var alertShown: Bool {
        var page = presentedViewController
        while let next = page?.presentedViewController { page = next }
        return page is UIAlertController
    }

    /// Where the keys and the d-pad move: the screen on top, else the choices, else the
    /// window's shortcut column.
    private var focusRoot: UIView? {
        if let page = topPage { return page.view }
        if let screen = messageLog ?? optionsScreen ?? saveScreen ?? systemMenu ?? titleView { return screen }
        if let choiceStack { return choiceStack }
        if let windowBar, !windowBar.isHidden, windowBar.alpha > 0.01 { return windowBar }
        return nil
    }

    /// Enter, Space or A: the focused button, else what a tap does.
    private func confirm() {
        if controlFocus.activate() { return }
        switch topPage {
        case let viewer as LucaPictureViewer: viewer.showNext()
        case let manual as LucaManualViewController: manual.nextPage()
        case .some: break
        case nil: tapped()
        }
    }

    /// Escape or B: backs out of the screen on top; in the story, the menu.
    private func back() {
        controlFocus.clear()
        if let page = topPage {
            if let extras = page as? LucaExtrasPage { extras.closePage() } else if let manual = page as? LucaManualViewController {
                manual.closeManual()
            } else {
                page.dismiss(animated: true)
            }
        } else if let messageLog {
            messageLog.close()
        } else if let optionsScreen {
            optionsScreen.close()
        } else if let saveScreen {
            saveScreen.closeScreen()
        } else if let systemMenu {
            systemMenu.close()
        } else if titleView == nil {
            showMenu()
        }
    }

    private func arrow(dx: Int, dy: Int) {
        if let messageLog, dy != 0 {
            messageLog.scroll(lines: dy * 2)
            return
        }
        if let slider = controlFocus.focused as? LucaOptionSlider, dx != 0, slider.window != nil {
            slider.value = min(1, max(0, slider.value + Double(dx) * 0.05))
            slider.sendActions(for: .valueChanged)
            return
        }
        if let root = focusRoot, controlFocus.move(dx: dx, dy: dy, in: root) { return }
        // Past the last slot, the next page of saves.
        if let saveScreen, dx != 0 {
            if dx > 0 { saveScreen.nextPage() } else { saveScreen.previousPage() }
            controlFocus.clear()
        } else if let manual = topPage as? LucaManualViewController, dx != 0 {
            if dx > 0 { manual.nextPage() } else { manual.previousPage() }
        }
    }

    /// Ctrl, RB or RT held: Skip (as the CONFIG sets it) until let go.
    private func holdSkip(_ on: Bool) {
        if on {
            guard inStory, readMode != .skip else { return }
            readMode = .skip
            linesSkipped = 0
            heldSkip = true
        } else if heldSkip {
            heldSkip = false
            if readMode == .skip { readMode = .normal }
        }
    }

    private var heldSkip = false

    /// Reading the story, with no screen over it.
    private var inStory: Bool {
        titleView == nil && presentedViewController == nil && systemMenu == nil && saveScreen == nil
            && optionsScreen == nil && messageLog == nil && player != nil
    }

    // MARK: Controller

    private var padReader = GamePadReader()
    private weak var leaveAlert: UIAlertController?

    /// A: read on or press, B: back out (in the story, the menu), d-pad: move between buttons
    /// and choices, Y or LB: the Message Log, RB or RT held: skip, X: auto, Menu: OPTIONS,
    /// Options: leave (on that question A leaves, B stays).
    private func pad(_ pad: GCExtendedGamepad) {
        if let alert = leaveAlert, presentedViewController === alert {
            for (button, down) in padReader.read(pad) where down {
                if button == .a { alert.dismiss(animated: true) { [weak self] in self?.leave() } }
                if button == .b { alert.dismiss(animated: true) }
            }
            return
        }
        guard !alertShown, !leaving else {
            padReader.absorb(pad)
            return
        }
        for (button, down) in padReader.read(pad) { padButton(button, down: down) }
    }

    private func padButton(_ button: GamePadReader.Button, down: Bool) {
        if button == .rb { holdSkip(down) }
        guard down else { return }
        pointerHovering = false
        switch button {
        case .up: arrow(dx: 0, dy: -1)
        case .down: arrow(dx: 0, dy: 1)
        case .left: arrow(dx: -1, dy: 0)
        case .right: arrow(dx: 1, dy: 0)
        case .a: confirm()
        case .b: back()
        case .x: if inStory, player?.choices == nil { windowBarPicked(.auto) }
        case .y, .lb: if let messageLog { messageLog.close() } else { showBacklog() }
        case .menu: if topPage == nil { presentOptions() }
        case .options: presentLeaveQuestion()
        case .rb: break
        }
    }

    // MARK: Pointer

    /// A trackpad or mouse is in use (since the last finger): the game's cursor
    /// (`SummerPockets.cur` in REFLECTION BLUE's `files/`) draws at it in place of the
    /// iPad's, and the button under it lights up.
    private var pointerHovering = false {
        didSet {
            guard pointerHovering != oldValue else { return }
            pointerInteraction?.invalidate()
            if !pointerHovering { cursorLayer.isHidden = true }
        }
    }
    private var pointerInteraction: UIPointerInteraction?
    private let cursorLayer = CALayer()
    private var gameCursor: CatSystemCursor?

    /// The game's own cursor, a Windows `.cur` beside its archives (patch first).
    private func loadCursor() {
        let fm = FileManager.default
        for root in ["patch", "base"] {
            let files = gameFolder.appendingPathComponent(root).appendingPathComponent("files", isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: files.path) else { continue }
            for name in names.sorted() where name.lowercased().hasSuffix(".cur") {
                if let cursor = CatSystemCursor(url: files.appendingPathComponent(name)) {
                    gameCursor = cursor
                    cursorLayer.contents = cursor.image
                    NSLog("Luca: the game's cursor %@", name)
                    return
                }
            }
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let point = recognizer.location(in: view)
        let over = recognizer.state == .began || recognizer.state == .changed
        if over { pointerHovering = true }
        let root = focusRoot
        controlFocus.hover(at: over && root != nil ? view.convert(point, to: root) : nil, in: root)
        guard over, let cursor = gameCursor, topPage == nil else {
            cursorLayer.isHidden = true
            return
        }
        // At the game's scale (the art is drawn for its 1920-wide screen).
        let scale = max(0.5, stageScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = CGRect(x: point.x - cursor.hotspot.x * scale, y: point.y - cursor.hotspot.y * scale,
                                   width: cursor.size.width * scale, height: cursor.size.height * scale)
        cursorLayer.isHidden = false
        view.layer.addSublayer(cursorLayer)
        CATransaction.commit()
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if os(iOS)
        // Keys from a hardware keyboard come here, not to UIKit (Escape would close the cover).
        becomeFirstResponder()
        #endif
        #if os(iOS)
        OrientationLock.set(.landscape, in: view.window?.windowScene)
        #endif
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        let scale = min(size.width / stageSize.width, size.height / stageSize.height)
        let frame = CGRect(x: (size.width - stageSize.width * scale) / 2, y: (size.height - stageSize.height * scale) / 2,
                           width: stageSize.width * scale, height: stageSize.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let renderer {
            renderer.layer.frame = frame
            let screen = view.window?.screen.scale ?? UIScreen.main.scale
            renderer.layer.contentsScale = screen
            renderer.layer.drawableSize = CGSize(width: frame.width * screen, height: frame.height * screen)
        }
        CATransaction.commit()
        overlay.frame = frame
        titleView?.frame = view.bounds
        layoutText()
        layoutChoices()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
    }

    // MARK: Frames

    @objc private func frame() {
        defer {
            if let lift = onFirstFrame {
                onFirstFrame = nil
                lift()
            }
        }
        audio.tick()
        guard let player, let game, titleView == nil else { return }
        prefetch(player)
        player.tick()
        audio.nextVoiceLevel = Float(settings.voiceLevel(for: player.message?.speaker))
        for sound in player.sounds { audio.handle(sound, game: game) }
        recordExtras(player, game: game)
        player.sounds.removeAll()
        for notice in player.notices { show(notice) }
        player.notices.removeAll()
        if let name = player.movie, movie == nil, !movieLoading { play(movie: name, player: player) }
        if stepMovie() { return }
        if player.finished {
            if let failure = player.failure { NSLog("Luca: stopped: %@", failure) }
            autosave()
            showTitle()
            return
        }
        if player.drawGeneration != lastDraw {
            lastDraw = player.drawGeneration
            if let transition = player.transition, transition.frames > 0 {
                renderer?.beginFade(frames: transition.frames)
                transitionRunning = true
            }
        } else if transitionRunning, player.transition == nil {
            // Finished, or a tap cut it short.
            renderer?.endFade()
            transitionRunning = false
        }
        drawStage(player)
        syncText(player)
        syncChoices(player)
        advanceByMode(player)
        #if DEBUG
        if autoLines > 0, player.transition == nil {
            if player.choices != nil, UserDefaults.standard.bool(forKey: "ShioriLucaAutoStopAtChoice") {
                autoLines = 0
            } else if player.choices != nil {
                player.choose(0)
            } else if player.isWaitingForClick {
                autoLines -= 1
                revealed = revealTarget
                renderText()
                player.click()
                if autoLines == 0 { NSLog("Luca: auto run done at %@@%d", player.currentScript, player.currentPosition) }
            }
        }
        #endif
    }

    private func drawStage(_ player: LucaPlayer) {
        guard let renderer else { return }
        var items: [LucaRenderer.Item] = []
        var shown = Set<Int>()
        /// Pictures on the stage, so effects that left it stop decoding.
        var effectsShown = Set<Int>()
        for layer in player.sortedLayers {
            effectsShown.insert(layer.imageID)
            if let effect = effectFrame(layer.imageID) {
                // An animated effect (MVT), scaled to the size it covers.
                let w = Double(effect.header.shownWidth) * layer.scale, h = Double(effect.header.shownHeight) * layer.scale
                let (x, y) = layer.origin(width: w, height: h, offsetX: 0, offsetY: 0)
                let packing = effect.header.alphaBelow ? 1 : effect.header.alphaRight ? 2 : 0
                items.append(.init(layer: layer, source: .video(effect.frame, packing: packing), rect: CGRect(x: x, y: y, width: w, height: h)))
                continue
            }
            guard let image = player.game.image(layer.imageID), let picture = texture(layer.imageID) else { continue }
            shown.insert(layer.imageID)
            if let baseID = layer.baseImageID, let base = player.game.image(baseID), let baseTexture = texture(baseID) {
                // The layer's whole picture, then the smaller one over it at its own offset.
                shown.insert(baseID)
                let bw = Double(base.width) * layer.scale, bh = Double(base.height) * layer.scale
                let (bx, by) = layer.origin(width: bw, height: bh, offsetX: 0, offsetY: 0)
                items.append(.init(layer: layer, source: .picture(baseTexture), rect: CGRect(x: bx, y: by, width: bw, height: bh)))
                items.append(.init(layer: layer, source: .picture(picture),
                                   rect: CGRect(x: bx + Double(image.offsetX) * layer.scale, y: by + Double(image.offsetY) * layer.scale,
                                                width: Double(image.width) * layer.scale, height: Double(image.height) * layer.scale)))
                continue
            }
            let w = Double(image.width) * layer.scale, h = Double(image.height) * layer.scale
            var (x, y) = layer.origin(width: w, height: h, offsetX: Double(image.offsetX), offsetY: Double(image.offsetY))
            if layer.centred, let anchor = player.game.overlayAnchor(layer.imageID) {
                // Where these pixels sit on the whole sprite, centred like the sprite.
                x = layer.x - Double(anchor.width) * layer.scale / 2 + Double(image.offsetX - anchor.x) * layer.scale
            }
            items.append(.init(layer: layer, source: .picture(picture), rect: CGRect(x: x, y: y, width: w, height: h)))
        }
        // Effects no longer on the stage stop decoding.
        for id in effects.keys where !effectsShown.contains(id) && !effectsLoading.contains(id) { effects[id] = nil }
        var face: (texture: MTLTexture, rect: CGRect)?
        if let layer = player.windowFace, let image = player.game.image(layer.imageID), let texture = texture(layer.imageID) {
            shown.insert(layer.imageID)
            // The face (its expression patch's rectangle) centred in the window's left end.
            let w = Double(image.width), h = Double(image.height)
            if faceRects[layer.imageID] == nil {
                faceRects[layer.imageID] = player.game.faceRect(layer.imageID).map {
                    CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
                } ?? CGRect(x: w / 2 - 90, y: h * 0.12, width: 180, height: 150)
            }
            let r = faceRects[layer.imageID]!
            face = (texture, CGRect(x: 215 - r.midX, y: windowRect.minY + 215 - r.midY, width: w, height: h))
        }
        onScreen = shown
        let windowShown = player.windowVisible && !textHidden && titleView == nil && systemMenu == nil && saveScreen == nil && optionsScreen == nil && messageLog == nil
        let window: LucaRenderer.Window
        if narrating, let narration = profile.narration {
            window = LucaRenderer.Window(visible: windowShown, mask: narrationMask,
                                         tint: SIMD4<Float>(0, 0, 0, settings.windowAlpha(base: narration.opacity)),
                                         rect: CGRect(x: 0, y: 0, width: 1920, height: 1080), face: nil)
        } else {
            window = LucaRenderer.Window(visible: windowShown, mask: windowMask,
                                         tint: windowTint, rect: windowRect,
                                         face: windowShown && player.message != nil ? face : nil)
        }
        renderer.draw(layers: items, shake: player.shake, window: window, effects: LucaEffects(sepia: player.effects.sepia))
    }

    // MARK: Animated effects

    /// MVT effects on the stage (sun flares, light lines, sparkles), decoding and looping from
    /// when they first appeared.
    private var effects: [Int: (decoder: LucaVideoDecoder, header: WebM.MVTHeader, start: CFTimeInterval)] = [:]
    private var effectsLoading = Set<Int>()
    private var notEffects = Set<Int>()

    /// The frame to show now for effect `id`, starting its decoder the first time (nil while it
    /// loads, or when `id` is a picture).
    private func effectFrame(_ id: Int) -> (frame: LucaVideoDecoder.Frame, header: WebM.MVTHeader)? {
        if let effect = effects[id] {
            guard let frame = effect.decoder.frame(at: CACurrentMediaTime() - effect.start) else { return nil }
            return (frame, effect.header)
        }
        guard !notEffects.contains(id), !effectsLoading.contains(id), let game, let device = renderer?.metalDevice else { return nil }
        guard game.isMVT(id) else { notEffects.insert(id); return nil }
        effectsLoading.insert(id)
        DispatchQueue.global(qos: .userInitiated).async {
            let mvt = game.mvt(id)
            let decoder = mvt.flatMap { LucaVideoDecoder(webm: $0.webm, device: device, loops: true) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.effectsLoading.remove(id)
                guard let mvt, let decoder else {
                    NSLog("Luca: couldn't play effect %d", id)
                    self.notEffects.insert(id)
                    return
                }
                self.effects[id] = (decoder, mvt.header, CACurrentMediaTime())
            }
        }
        return nil
    }

    /// Every quarter second, decodes and uploads what the script will show next.
    private func prefetch(_ player: LucaPlayer) {
        framesSincePrefetch += 1
        guard framesSincePrefetch >= 15, let game, let cache = renderer?.textures else { return }
        framesSincePrefetch = 0
        prefetching.subtract(prefetched.drainDone())
        for id in player.upcomingImages() where cache.cached(id) == nil && !prefetching.contains(id) && prefetching.count < 4 {
            prefetching.insert(id)
            let store = prefetched
            let keep = onScreen
            prefetchQueue.async {
                if let image = game.image(id), let texture = cache.make(image) { cache.store(id, texture, keep: keep) }
                store.finished(id)
            }
        }
    }

    private func texture(_ id: Int) -> MTLTexture? {
        guard let game, let cache = renderer?.textures else { return nil }
        return cache.texture(id, game: game, keep: onScreen)
    }

    nonisolated static func cgImage(_ image: CZImage) -> CGImage? {
        // Premultiply for Core Animation.
        var pixels = image.rgba
        pixels.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < p.count {
                let a = UInt16(p[i + 3])
                if a < 255 {
                    p[i] = UInt8(UInt16(p[i]) * a / 255)
                    p[i + 1] = UInt8(UInt16(p[i + 1]) * a / 255)
                    p[i + 2] = UInt8(UInt16(p[i + 2]) * a / 255)
                }
                i += 4
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Text

    private var stageScale: CGFloat { overlay.bounds.width / stageSize.width }

    private func syncText(_ player: LucaPlayer) {
        let visible = player.windowVisible && !textHidden && player.message != nil && systemMenu == nil && saveScreen == nil && optionsScreen == nil && messageLog == nil
        // The PC game shows the name without a plate.
        namePlate.isHidden = true
        let waiting = visible && player.isWaitingForClick && !typing
        if waiting != !pageMarker.isHidden {
            pageMarker.isHidden = !waiting
            if waiting { pageMarker.startAnimating() } else { pageMarker.stopAnimating() }
        }
        nameView.isHidden = !visible
        textView.isHidden = !visible
        if let windowBar {
            windowBar.isHidden = !(visible && settings.shortcutMenu && player.choices == nil)
            windowBar.update(skip: readMode == .skip, auto: readMode == .auto, voice: lineHasVoice)
        }
        if (player.windowFace != nil) != lastHadFace {
            lastHadFace = player.windowFace != nil
            layoutText()
        }
        if player.message != shownMessage {
            shownMessage = player.message
            revealed = 0
            revealCarry = 0
            lineHasVoice = shownMessage.map { player.game.hasVoice($0.voice) } ?? false
            revealTarget = shownMessage?.text.count ?? 0
            if let key = player.messageKey, let readLog {
                lineWasRead = readLog.contains(key)
                readLog.insert(key)
            } else {
                lineWasRead = false
            }
            layoutText()
        }
        if revealed < revealTarget {
            if let speed = settings.lettersPerSecond {
                revealCarry += speed / 60
                let step = Int(revealCarry)
                revealCarry -= Double(step)
                if step > 0 {
                    revealed = min(revealTarget, revealed + step)
                    renderText()
                }
            } else {
                revealed = revealTarget
                renderText()
            }
        }
    }

    /// The window's text is the game's size-37 font; where it sits is the profile's window.
    private static let textSize = 37
    private static let outline: (UInt8, UInt8, UInt8) = (20, 50, 60)
    private var textLeft: CGFloat { player?.windowFace != nil ? profile.window.textLeftWithFace : profile.window.textLeft }

    private func loadFont(_ face: String, _ size: Int) -> (main: LucaFont, patch: LucaFont?)? {
        let key = "\(face) \(size)"
        if let loaded = loadedFonts[key] { return loaded }
        let loaded = game?.font(face: face, size: size)
        loadedFonts[key] = loaded
        return loaded
    }

    /// The fonts for `text` in the chosen face at `size`: that size and its patch, and size 40
    /// (which has every character) when the text has one that size lacks.
    private func fonts(for text: String, size: Int = textSize) -> [LucaFont] {
        let face = settings.font
        guard let loaded = loadFont(face, size) ?? loadFont("GOTHIC1", size) else { return [] }
        var fonts = [loaded.main] + (loaded.patch.map { [$0] } ?? [])
        let missing = text.unicodeScalars.contains { scalar in
            scalar.value > 32 && scalar.value != 0x3000 && !fonts.contains { $0.glyph(scalar) != nil }
        }
        if missing, size != 40, let fallback = loadFont(face, 40)?.main { fonts.append(fallback) }
        return fonts
    }

    /// `text` in the game's font, wrapped at `width` stage pixels: the picture (in stage pixels)
    /// and its typeset.
    func gameText(_ text: String, size: Int = textSize, width: Int, fill: UIColor = .white) -> (image: UIImage, set: LucaTypeset)? {
        let set = LucaTypeset(text, fonts: fonts(for: text, size: size), width: width, lineHeight: size * 3 / 2)
        guard !set.placed.isEmpty, let image = textImage(set, fill: fill) else { return nil }
        return (image, set)
    }

    private func textImage(_ set: LucaTypeset, fill: UIColor) -> UIImage? {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        fill.getRed(&r, green: &g, blue: &b, alpha: &a)
        let pixels = set.render(fill: (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255)), outline: Self.outline, outlineWidth: profile.window.outline)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: set.usedWidth, height: set.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: set.usedWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Draws the line (and name) when they or their look changed, then reveals as much of the
    /// line as has typed.
    private func renderText() {
        let s = stageScale
        guard s > 0, let message = shownMessage else {
            textView.image = nil
            nameView.image = nil
            typeset = nil
            composedKey = nil
            return
        }
        let colour = lineWasRead && settings.colourReadText
            ? LucaSettings.readTextColours[min(settings.readTextColour, LucaSettings.readTextColours.count - 1)].color : UIColor.white
        let left = textLeft
        let narration = narrating ? profile.narration : nil
        let key = "\(message.speaker ?? "")\u{1}\(message.text)\u{1}\(settings.font)\u{1}\(colour)\u{1}\(left)\u{1}\(s)\u{1}\(narration != nil)"
        if key != composedKey, let narration {
            // Narration: centred on the narration box, both ways.
            composedKey = key
            let set = LucaTypeset(message.text, fonts: fonts(for: message.text), width: narration.textWidth, lineHeight: narration.lineHeight)
            typeset = set
            textView.image = textImage(set, fill: colour)
            let x = (1920 - CGFloat(set.usedWidth)) / 2, y = (1080 - CGFloat(set.height)) / 2
            textView.frame = CGRect(x: x * s, y: y * s, width: CGFloat(set.usedWidth) * s, height: CGFloat(set.height) * s)
            textMask.frame = textView.bounds
            nameView.image = nil
        } else if key != composedKey {
            composedKey = key
            let w = profile.window
            let width = w.textWidth - Int(left - w.textLeft)
            let set = LucaTypeset(message.text, fonts: fonts(for: message.text), width: width, lineHeight: w.lineHeight)
            typeset = set
            textView.image = textImage(set, fill: colour)
            let top = w.textTop - CGFloat((w.lineHeight - Self.textSize - 1) / 2)
            textView.frame = CGRect(x: left * s, y: top * s, width: CGFloat(set.usedWidth) * s, height: CGFloat(set.height) * s)
            textMask.frame = textView.bounds
            if let speaker = message.speaker, !speaker.isEmpty {
                let name = LucaTypeset(speaker, fonts: fonts(for: speaker), width: 900, lineHeight: w.lineHeight)
                nameView.image = textImage(name, fill: .white)
                nameView.frame = CGRect(x: left * s, y: (top - (w.textTop - w.nameTop)) * s, width: CGFloat(name.usedWidth) * s, height: CGFloat(name.height) * s)
            } else {
                nameView.image = nil
            }
        }
        guard let typeset else { return }
        let path = CGMutablePath()
        for rect in typeset.revealed(revealed) {
            path.addRect(CGRect(x: CGFloat(rect.x) * s, y: CGFloat(rect.y) * s, width: CGFloat(rect.width) * s, height: CGFloat(rect.height) * s))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMask.path = path
        CATransaction.commit()
    }

    private func layoutText() {
        let s = stageScale
        guard s > 0 else { return }
        namePlate.frame = CGRect(x: (textLeft - 150) * s, y: 712 * s, width: 496 * s, height: 110 * s)
        let marker = profile.window.pageMarker
        pageMarker.frame = CGRect(x: marker.minX * s, y: marker.minY * s, width: marker.width * s, height: marker.height * s)
        let bar = LucaWindowBar.frameInStage
        windowBar?.frame = CGRect(x: bar.minX * s, y: bar.minY * s, width: bar.width * s, height: bar.height * s)
        renderText()
    }

    private var typing: Bool { revealed < revealTarget }

    private func advanceByMode(_ player: LucaPlayer) {
        switch readMode {
        case .normal:
            return
        case .skip:
            if player.choices != nil {
                readMode = .normal
            } else if player.isWaitingForClick, settings.skipReadOnly, !lineWasRead {
                // Skip stops at the first line not read before; said so when it couldn't
                // skip anything at all.
                readMode = .normal
                if linesSkipped == 0 {
                    show(.acquired("Skip stops at unread lines. Change it in OPTIONS › Basic › Skip."))
                }
            } else if player.isWaitingForClick {
                linesSkipped += 1
                revealed = revealTarget
                renderText()
                player.finishAnimations()
                player.click()
            } else {
                player.finishAnimations()
            }
        case .auto:
            guard player.isWaitingForClick, !typing, player.transition == nil, !audio.isVoicePlaying else {
                lineDoneAt = nil
                return
            }
            let now = CACurrentMediaTime()
            if let done = lineDoneAt {
                if now - done > settings.autoWait(letters: shownMessage?.text.count ?? 0) {
                    lineDoneAt = nil
                    player.click()
                }
            } else {
                lineDoneAt = now
            }
        }
    }

    // MARK: Movies

    /// A movie playing in place of the stage: VP9 through libvpx, its Vorbis soundtrack as the
    /// clock. A tap skips.
    private var movie: (decoder: LucaVideoDecoder, start: CFTimeInterval)?
    private var movieLoading = false

    /// Plays `files/movie/<name>.webm` (the English cut, `<name>_en`, when there is one).
    private func play(movie name: String, player: LucaPlayer) {
        let folder = gameFolder.appendingPathComponent("base/files/movie", isDirectory: true)
        let candidates = ["\(name)_en.webm", "\(name).webm"]
        guard let file = candidates.map({ folder.appendingPathComponent($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let device = renderer?.metalDevice else {
            NSLog("Luca: no movie %@", name)
            player.movieFinished()
            return
        }
        audio.handle(.stopMusic(fadeFrames: 0), game: player.game)
        movieLoading = true
        // Parsing and the soundtrack's decode take a moment; the screen stays black meanwhile.
        DispatchQueue.global(qos: .userInitiated).async {
            let webm = try? WebM(data: Data(contentsOf: file, options: .alwaysMapped))
            let decoder = webm.flatMap { LucaVideoDecoder(webm: $0, device: device) }
            let sound = webm?.vorbisAsOgg().flatMap(LucaAudio.movieBuffer)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.movieLoading else { return }
                self.movieLoading = false
                guard let decoder else {
                    NSLog("Luca: couldn't play %@", file.lastPathComponent)
                    self.player?.movieFinished()
                    return
                }
                if let sound { self.audio.playMovie(sound) }
                self.movie = (decoder, CACurrentMediaTime())
            }
        }
    }

    /// Draws the movie's frame for now; true while a movie owns the screen.
    private func stepMovie() -> Bool {
        if movieLoading {
            renderer?.drawMovie(nil)
            return true
        }
        guard let movie else { return false }
        let time = audio.movieTime ?? (CACurrentMediaTime() - movie.start)
        let frame = movie.decoder.frame(at: time)
        renderer?.drawMovie(frame)
        if movie.decoder.finished || time > movie.decoder.duration + 0.5 { endMovie() }
        return true
    }

    private func endMovie() {
        movieLoading = false
        movie = nil
        audio.stopMovie()
        player?.movieFinished()
    }

    // MARK: Notices

    /// The day's date large in the middle, or an "Acquired" card at the top, fading out.
    private func show(_ notice: LucaNotice) {
        let label = PaddedLabel()
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 4
        label.layer.shadowOffset = .zero
        switch notice {
        case .date(let day):
            label.text = day
            label.font = UIFont.systemFont(ofSize: 44, weight: .light).withDesign(.serif)
            label.sizeToFit()
            label.center = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.height * 0.4)
        case .acquired(let text):
            label.text = text
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            label.backgroundColor = UIColor(red: 0.05, green: 0.16, blue: 0.34, alpha: 0.85)
            label.layer.cornerRadius = 14
            label.clipsToBounds = true
            label.numberOfLines = 2
            let size = label.sizeThatFits(CGSize(width: overlay.bounds.width * 0.7, height: 100))
            label.bounds = CGRect(origin: .zero, size: size)
            label.center = CGPoint(x: overlay.bounds.midX, y: 20 + size.height / 2)
        }
        label.alpha = 0
        overlay.addSubview(label)
        UIView.animate(withDuration: 0.4) { label.alpha = 1 }
        UIView.animate(withDuration: 0.6, delay: 2.4, options: []) { label.alpha = 0 } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: Choices

    private func syncChoices(_ player: LucaPlayer) {
        guard player.choices != shownChoices else { return }
        shownChoices = player.choices
        choiceStack?.removeFromSuperview()
        choiceStack = nil
        mapBackdrop?.removeFromSuperview()
        mapBackdrop = nil
        guard let choices = player.choices else { return }
        if player.choicePrompt != nil, let map = profile.mapImage.flatMap(picture) {
            let backdrop = UIImageView(image: UIImage(cgImage: map))
            backdrop.contentMode = .scaleAspectFill
            backdrop.clipsToBounds = true
            backdrop.alpha = 0.85
            backdrop.frame = overlay.bounds
            backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.insertSubview(backdrop, at: 0)
            mapBackdrop = backdrop
        }
        let stack = UIStackView()
        stack.axis = .vertical
        // Long lists (the map can offer nine places) sit tighter to fit a phone in landscape.
        let compact = choices.count > 5
        stack.spacing = compact ? 0 : 6 * stageScale
        if let prompt = player.choicePrompt {
            let label = UILabel()
            label.text = prompt
            label.font = .systemFont(ofSize: 22, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.9
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
            stack.addArrangedSubview(label)
        }
        for (index, choice) in choices.enumerated() {
            let detail = player.choiceDetails.indices.contains(index) ? player.choiceDetails[index] : nil
            // The choice in the game's font; a map place's first line smaller below it.
            let lines = [gameText(choice, width: 1100)?.image,
                         detail.flatMap { $0.isEmpty ? nil : gameText($0, size: 28, width: 1100, fill: UIColor(white: 1, alpha: 0.92))?.image }]
            let banner = LucaChoiceBanner(images: choiceImages, title: choice, detail: detail, rendered: lines.compactMap { $0 },
                                          scale: stageScale, compact: compact) { [weak self] in self?.player?.choose(index) }
            stack.addArrangedSubview(banner)
        }
        overlay.addSubview(stack)
        choiceStack = stack
        layoutChoices()
    }

    private func layoutChoices() {
        guard let stack = choiceStack else { return }
        // The banners are 1680 game px wide, glow included.
        let width = choiceImages.isEmpty ? min(overlay.bounds.width * 0.7, 640) : 1680 * stageScale
        let size = stack.systemLayoutSizeFitting(CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
                                                 verticalFittingPriority: .fittingSizeLevel)
        let y = min(max(10, overlay.bounds.height * 0.42 - size.height / 2), overlay.bounds.height - size.height - 10)
        stack.frame = CGRect(x: (overlay.bounds.width - width) / 2, y: max(10, y), width: width, height: size.height)
        mapBackdrop?.frame = overlay.bounds
    }

    // MARK: Input

    /// Taps on the choice banners (and other controls) go to them, not to reading on.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        #if os(iOS)
        if !touch.isPointer { pointerHovering = false }
        #endif
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }

    @objc private func tapped() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil, let player else { return }
        if movieLoading { return }
        if let movie {
            if CACurrentMediaTime() - movie.start > 1 { endMovie() }
            return
        }
        if readMode != .normal {
            readMode = .normal
            return
        }
        if textHidden {
            textHidden = false
            return
        }
        guard player.choices == nil else { return }
        if typing {
            revealed = revealTarget
            renderText()
            return
        }
        player.click()
    }

    @objc private func showMenu() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil, let player, let game else { return }
        audio.playSystem("TOGGLE", game: game)
        // The game's own menu art, or the shared icon strip when the profile names none.
        let style = profile.systemMenu ?? .icons(sheet: "system_icon_1920_en", background: "system_BG")
        let layout: LucaSystemMenu.Layout
        switch style {
        case .grid(let name): layout = .grid(picture(name))
        case .icons(let sheet, let background): layout = .icons(picture(sheet), background: background.flatMap(picture))
        }
        let menu = LucaSystemMenu(layout: layout) { [weak self] item in
            guard let self else { return }
            self.systemMenu?.removeFromSuperview()
            self.systemMenu = nil
            guard let item else { return }
            switch item {
            case .save: self.presentSlots(saving: true)
            case .load: self.presentSlots(saving: false)
            case .record: self.showBacklog()
            case .options: self.presentOptions()
            case .title:
                self.autosave()
                self.showTitle()
            case .quickSave:
                try? LucaSaves.write(player.saveState(), slot: LucaSaves.quickSlot, thumbnail: self.thumbnail(), in: self.saves)
                self.show(.acquired("Quick saved"))
            case .quickLoad:
                if let save = LucaSaves.read(slot: LucaSaves.quickSlot, in: self.saves) { self.start(state: save.state) }
            case .manual: self.presentManual()
            case .exit: self.leave()
            }
        }
        menu.frame = view.bounds
        menu.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(menu)
        systemMenu = menu
    }

    #if os(iOS)
    private var scrolledBack = false

    /// Scrolling up (the wheel turned back) opens the Message Log once per gesture.
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began: scrolledBack = false
        case .changed:
            if !scrolledBack, recognizer.translation(in: view).y > 40 {
                scrolledBack = true
                showBacklog()
            }
        default: break
        }
    }
    #endif

    @objc private func showBacklog() {
        guard titleView == nil, presentedViewController == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil,
              systemMenu == nil, let player, let game else { return }
        readMode = .normal
        audio.playSystem("TOGGLE", game: game)
        let log = LucaMessageLog(game: game, lines: player.backlog, typeset: { [weak self] text, width, fill in
            guard let self else { return nil }
            let set = LucaTypeset(text, fonts: self.fonts(for: text), width: width, lineHeight: self.profile.window.lineHeight)
            guard !set.placed.isEmpty else { return nil }
            return (CGSize(width: set.usedWidth, height: set.height), { [weak self] in self?.textImage(set, fill: fill) })
        }, onVoice: { [weak self] line in
            guard let self, let game = self.game else { return }
            self.audio.replayVoice(line.voice, level: Float(self.settings.voiceLevel(for: line.speaker)), game: game)
        }, onClose: { [weak self] in
            guard let self else { return }
            if let game = self.game { self.audio.playSystem("TOGGLE", game: game) }
            self.messageLog?.removeFromSuperview()
            self.messageLog = nil
        })
        log.onReturn = { [weak self] index in
            guard let self, let player = self.player else { return }
            let serial = player.serial(ofBacklogLine: index)
            guard player.canReturn(to: serial) else {
                self.show(.acquired("That line is too far back to return to."))
                return
            }
            let alert = UIAlertController(title: "Return to this line?", message: player.backlog[index].text, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Return", style: .default) { _ in
                self.messageLog?.removeFromSuperview()
                self.messageLog = nil
                self.returnTo(line: serial)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            self.present(alert, animated: true)
        }
        log.frame = view.bounds
        log.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(log)
        log.scrollToEnd()
        messageLog = log
    }

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        presentLeaveQuestion()
    }

    private func presentLeaveQuestion() {
        guard presentedViewController == nil else { return }
        let kept = player.map { !$0.finished } == true ? "Your place is saved to the Load screen." : "Progress since your last save is lost."
        let message = GCController.current?.extendedGamepad != nil ? kept + " Ⓐ Leave, Ⓑ Keep Playing." : kept
        let alert = UIAlertController(title: "Leave the game?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        #if os(iOS)
        leaveAlert = alert
        #endif
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        savePlace(reason: "leaving the game")
        leaving = true
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        #if os(iOS)
        ControllerInput.gameReceiver = nil
        OrientationLock.set(.all, in: view.window?.windowScene)
        #endif
        onExit()
    }

    // MARK: Title

    private func showTitle() {
        guard let game else { return }
        player = nil
        audio.handle(.stopVoice, game: game)
        audio.handle(.stopEffect(channel: -1, fadeFrames: 0), game: game)
        audio.handle(.stopMusic(fadeFrames: 30), game: game)
        titleView?.removeFromSuperview()
        // The boot sequence (warning and logos) plays once per launch; after that, the title.
        let onSound: (String) -> Void = { [weak self] sound in
            guard let self, let game = self.game else { return }
            if sound == "music" {
                if let music = self.profile.titleMusic { self.audio.handle(.music(id: music, fadeFrames: 60), game: game) }
            } else {
                self.audio.playSystem(sound, game: game)
            }
        }
        let onAction: (LucaTitleScreen.Action) -> Void = { [weak self] action in
            guard let self else { return }
            switch action {
            case .start: self.start(state: nil)
            case .load: self.presentSlots(saving: false)
            case .options: self.presentOptions()
            case .manual: self.presentManual()
            case .exit: self.leave()
            case .chapter: self.presentChapters()
            case .gallery: self.presentGallery()
            case .music: self.presentMusic()
            }
        }
        let title: UIView
        if case .reflectionBlue = profile.title {
            title = LucaTitleScreen(game: game, boot: !bootShown, onSound: onSound, onAction: onAction)
        } else {
            title = LucaColumnTitleScreen(game: game, profile: profile, boot: !bootShown, onSound: onSound, onAction: onAction)
        }
        bootShown = true
        title.frame = view.bounds
        title.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(title)
        titleView = title
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "ShioriLucaNewGame") {
            UserDefaults.standard.removeObject(forKey: "ShioriLucaNewGame")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.start(state: nil) }
        }
        #endif
        nameView.isHidden = true
        textView.isHidden = true
        choiceStack?.removeFromSuperview()
        choiceStack = nil
        shownChoices = nil
    }

    private func start(state: LucaPlayer.State?, script: String? = nil) {
        guard let game else { return }
        do {
            let player = try LucaPlayer(game: game, script: script)
            if let state { try player.restore(state) }
            player.stopsVoiceOnClick = settings.voiceStopsOnTap
            self.player = player
            readMode = .normal
            audio.handle(.stopMusic(fadeFrames: 30), game: game)
            lastDraw = -1
            shownMessage = nil
            textHidden = false
            if let titleView {
                titleView.removeFromSuperview()
                self.titleView = nil
            }
        } catch {
            NSLog("Luca: couldn't start: %@", String(describing: error))
        }
    }

    // MARK: Chapter and Extras

    /// Notes what the title's Chapter and Extras screens open: the chapter being read, event
    /// pictures on stage, music played.
    private func recordExtras(_ player: LucaPlayer, game: LucaGame) {
        var record = extras
        for case .music(let id, _) in player.sounds { record.tracks.insert(id) }
        if let chapter = LucaExtrasRecord.chapter(ofScript: player.currentScript) { record.chapters.insert(chapter) }
        let key = player.layers.values.map { "\($0.imageID)" }.sorted().joined(separator: ",")
        if key != extrasLayerKey {
            extrasLayerKey = key
            for layer in player.layers.values {
                if let name = game.imageName(layer.imageID), LucaExtrasRecord.isEventPicture(name) { record.pictures.insert(name) }
            }
        }
        if record != extras {
            extras = record
            record.save(to: saves)
        }
    }

    /// Chapters read before Shiori kept this record: any of their lines in the read log.
    private func backfillChapters(_ game: LucaGame) {
        guard let readLog else { return }
        var record = extras
        for name in game.scriptNames {
            guard let chapter = LucaExtrasRecord.chapter(ofScript: name), !record.chapters.contains(chapter),
                  let script = try? game.script(named: name) else { continue }
            if LucaPlayer.lineKeys(in: script).contains(where: readLog.contains) { record.chapters.insert(chapter) }
        }
        if record != extras {
            extras = record
            record.save(to: saves)
        }
    }

    private var titleSheet: CGImage? {
        guard case .column(_, _, let menu, _, _) = profile.title else { return nil }
        return picture(menu)
    }

    private func extrasSound(_ name: String) {
        guard let game else { return }
        audio.playSystem(name, game: game)
    }

    private func presentChapters() {
        guard let game else { return }
        let chapters = game.scriptNames.compactMap { name in LucaExtrasRecord.chapter(ofScript: name).map { ($0, name) } }
        let page = LucaChapterPage(game: game, chapters: chapters, reached: extras.chapters, sheet: titleSheet)
        page.onSound = { [weak self] in self?.extrasSound($0) }
        page.onChapter = { [weak self] script in self?.start(state: nil, script: script) }
        present(page, animated: true)
    }

    private func presentGallery() {
        guard let game else { return }
        let page = LucaGalleryPage(game: game, entries: profile.gallery, seen: extras.pictures, sheet: titleSheet)
        page.onSound = { [weak self] in self?.extrasSound($0) }
        present(page, animated: true)
    }

    private func presentMusic() {
        guard let game, let archive = game.music else { return }
        let tracks = archive.entries.map(\.id)
        let page = LucaMusicPage(game: game, tracks: tracks, heard: extras.tracks, sheet: titleSheet)
        page.onSound = { [weak self] in self?.extrasSound($0) }
        page.onPlay = { [weak self] track in
            guard let self, let game = self.game else { return }
            if let track { self.audio.handle(.music(id: track, fadeFrames: 30), game: game) } else { self.audio.handle(.stopMusic(fadeFrames: 30), game: game) }
        }
        page.onClose = { [weak self] in
            // Back to the title's own music.
            guard let self, let game = self.game, let music = self.profile.titleMusic else { return }
            self.audio.handle(.music(id: music, fadeFrames: 60), game: game)
        }
        present(page, animated: true)
    }

    // MARK: Manual and options

    /// The game's digital manual: its 16 English pages over manual_BG, swiped or tapped through.
    private func presentManual() {
        guard let game else { return }
        let pages = (1...16).compactMap { game.imageID(named: String(format: "en_manual%02d", $0)) }
        let pager = LucaManualViewController(game: game, pages: pages, background: game.imageID(named: "manual_BG"))
        pager.modalPresentationStyle = .overFullScreen
        present(pager, animated: true)
    }

    private func presentOptions() {
        guard let game, optionsScreen == nil, messageLog == nil else { return }
        audio.playSystem("TOGGLE", game: game)
        let screen = LucaOptionsScreen(game: game, settings: settings, voiceFaces: profile.voiceFaces, onSound: { [weak self] name in
            guard let self, let game = self.game else { return }
            self.audio.playSystem(name, game: game)
        }, onChange: { [weak self] settings in
            self?.settings = settings
            self?.applySettings()
        }, onClose: { [weak self] in
            guard let self else { return }
            self.settings.save(to: self.saves)
            self.optionsScreen?.removeFromSuperview()
            self.optionsScreen = nil
        })
        screen.onSample = { [weak self] name in
            // The character's most recent voiced line, at the level being set.
            guard let self, let game = self.game,
                  let line = self.player?.backlog.last(where: { $0.speaker == name && game.hasVoice($0.voice) }) else { return }
            self.audio.replayVoice(line.voice, level: Float(self.settings.voiceLevel(for: name)), game: game)
        }
        screen.frame = view.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen)
        optionsScreen = screen
    }

    private func applySettings() {
        audio.musicVolume = Float(settings.music)
        audio.effectVolume = Float(settings.effects)
        audio.voiceVolume = Float(settings.voice)
        audio.systemVolume = Float(settings.system)
        player?.stopsVoiceOnClick = settings.voiceStopsOnTap
        renderText()
    }

    // MARK: Shortcut menu

    private func windowBarPicked(_ item: LucaWindowBar.Item) {
        guard let game else { return }
        switch item {
        case .menu:
            showMenu()
        case .skip:
            readMode = readMode == .skip ? .normal : .skip
            linesSkipped = 0
            audio.playSystem("TOGGLE", game: game)
        case .auto:
            readMode = readMode == .auto ? .normal : .auto
            lineDoneAt = nil
            audio.playSystem("TOGGLE", game: game)
        case .voice:
            if lineHasVoice, let line = shownMessage {
                audio.replayVoice(line.voice, level: Float(settings.voiceLevel(for: line.speaker)), game: game)
            }
        }
    }

    /// Manual page 10: a flick right starts Skip; holding a finger on the window toggles Auto.
    @objc private func flickedRight() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil,
              player?.choices == nil else { return }
        windowBarPicked(.skip)
    }

    /// Two fingers swiped up: Auto on or off.
    @objc private func swipedAuto() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil, messageLog == nil,
              player?.choices == nil else { return }
        windowBarPicked(.auto)
    }

    /// Manual page 10: a flick left goes back a line.
    @objc private func flickedLeft() {
        guard titleView == nil, presentedViewController == nil, systemMenu == nil, saveScreen == nil, optionsScreen == nil,
              messageLog == nil, movie == nil, let serial = player?.previousLine else { return }
        returnTo(line: serial)
    }

    private func returnTo(line serial: Int) {
        guard let player else { return }
        do {
            try player.returnTo(line: serial)
        } catch {
            NSLog("Luca: couldn't go back: %@", String(describing: error))
            return
        }
        readMode = .normal
        lastDraw = -1
        renderer?.endFade()
        transitionRunning = false
    }

    @objc private func heldOnWindow(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, titleView == nil, presentedViewController == nil, systemMenu == nil,
              saveScreen == nil, optionsScreen == nil , messageLog == nil, player?.choices == nil else { return }
        let point = recognizer.location(in: overlay)
        guard point.y > windowRect.minY * stageScale else { return }
        windowBarPicked(.auto)
    }

    // MARK: Saves

    private func autosave() {
        readLog?.save()
        guard let player, !player.finished else { return }
        try? LucaSaves.write(player.saveState(), slot: 0, thumbnail: thumbnail(), in: saves)
    }

    /// On leaving the game or the screen: the place into a numbered slot of the game's Load
    /// screen (`LucaSaves.savePlace`), never loaded by itself (spec Saves, Keeping the place).
    private func savePlace(reason: String) {
        readLog?.save()
        guard let player, !player.finished else {
            NSLog("Luca: no place to keep, %@", reason)
            return
        }
        do {
            if let slot = try LucaSaves.savePlace(player.saveState(), thumbnail: thumbnail(), in: saves) {
                NSLog("Luca: kept the place in slot %d, %@", slot, reason)
            } else {
                NSLog("Luca: the place is already in Shiori's slot, %@", reason)
            }
        } catch {
            NSLog("Luca: couldn't keep the place: %@", String(describing: error))
        }
    }

    private func thumbnail() -> Data? {
        guard let image = renderer?.snapshot(width: 384, height: 216) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.7)
    }

    private func presentSlots(saving: Bool) {
        guard let game else { return }
        let thumbnail = saving ? thumbnail() : nil
        var screen: LucaSaveScreen?
        screen = LucaSaveScreen(game: game, folder: saves, saving: saving, blank: profile.saveBlank, cursor: profile.saveCursor) { [weak self] slot in
            guard let self else { return }
            screen?.removeFromSuperview()
            self.saveScreen = nil
            guard let slot else { return }
            if saving {
                if let player = self.player {
                    try? LucaSaves.write(player.saveState(), slot: slot, thumbnail: thumbnail, in: self.saves)
                    self.audio.playSystem("TOGGLE", game: game)
                }
            } else if let save = LucaSaves.read(slot: slot, in: self.saves) {
                self.start(state: save.state)
            }
        }
        guard let screen else { return }
        audio.playSystem("TOGGLE", game: game)
        screen.frame = view.bounds
        screen.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(screen)
        saveScreen = screen
    }

    /// The game's picture `name` (nil when it has none).
    private func picture(_ name: String) -> CGImage? {
        game?.imageID(named: name).flatMap { game?.image($0) }.flatMap(Self.cgImage)
    }
}

#if os(iOS)
extension LucaGameViewController: UIPointerInteractionDelegate {
    /// The iPad pointer hides while the game's own cursor draws in its place.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        guard pointerHovering, gameCursor != nil, topPage == nil else { return nil }
        return .hidden()
    }
}

#if DEBUG
extension LucaGameViewController {
    /// `-ShioriLucaInput "8:pad-down;9:key-enter;20:pad-rb"`: keys (`key-up`, `key-down`,
    /// `key-left`, `key-right`, `key-enter`, `key-escape`, `key-ctrl`, `key-pageup`) and pad
    /// buttons (`pad-a`, `pad-b`, `pad-x`, `pad-y`, `pad-menu`, `pad-options`, `pad-rb` held
    /// for two seconds, `pad-up` …), `leave` and `load-screen` at seconds from launch, to
    /// check them in the simulator.
    fileprivate func scheduleDebugInput() {
        let keys: [String: UIKeyboardHIDUsage] = [
            "key-up": .keyboardUpArrow, "key-down": .keyboardDownArrow, "key-left": .keyboardLeftArrow,
            "key-right": .keyboardRightArrow, "key-enter": .keyboardReturnOrEnter, "key-escape": .keyboardEscape,
            "key-ctrl": .keyboardLeftControl, "key-pageup": .keyboardPageUp,
        ]
        let pads: [String: GamePadReader.Button] = [
            "pad-up": .up, "pad-down": .down, "pad-left": .left, "pad-right": .right, "pad-a": .a, "pad-b": .b,
            "pad-x": .x, "pad-y": .y, "pad-lb": .lb, "pad-rb": .rb, "pad-menu": .menu, "pad-options": .options,
        ]
        for step in (UserDefaults.standard.string(forKey: "ShioriLucaInput") ?? "").split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let name = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                NSLog("Luca: debug input %@", name)
                if name == "leave" {
                    // The leave question's Leave.
                    self.leave()
                } else if name == "load-screen" {
                    self.presentSlots(saving: false)
                } else if let key = keys[name] {
                    self.keyDown(key)
                    if key == .keyboardLeftControl {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.holdSkip(false) }
                    }
                } else if let button = pads[name] {
                    self.padButton(button, down: true)
                    if button == .rb { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.padButton(.rb, down: false) } }
                }
            }
        }
    }
}
#endif
#endif

/// A choice drawn as the game's banner: blue, gold while pressed, the text centred on it.
private final class LucaChoiceBanner: UIControl {
    private let background = UIImageView()
    private let images: [CGImage]
    private let action: () -> Void

    /// `rendered`: the title (and detail) already drawn in the game's font, in stage pixels;
    /// without them the system font draws `title` and `detail`.
    init(images: [CGImage], title: String, detail: String?, rendered: [UIImage] = [], scale: CGFloat, compact: Bool,
         action: @escaping () -> Void) {
        self.images = images
        self.action = action
        super.init(frame: .zero)
        #if os(iOS)
        highlightsOnHover()
        #endif
        background.contentMode = .scaleToFill
        background.image = images.first.map { UIImage(cgImage: $0) }
        if images.isEmpty {
            background.backgroundColor = UIColor(red: 0.05, green: 0.45, blue: 0.7, alpha: 0.85)
            background.layer.cornerRadius = 8
        }
        addSubview(background)
        background.translatesAutoresizingMaskIntoConstraints = false
        let height = (compact ? 112 : 148) * scale
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.centerYAnchor.constraint(equalTo: centerYAnchor),
            background.heightAnchor.constraint(equalToConstant: 225 * scale),
        ])
        addAction(UIAction { [weak self] _ in self?.action() }, for: .touchUpInside)
        if !rendered.isEmpty {
            let column = UIStackView(arrangedSubviews: rendered.map { image in
                let view = UIImageView(image: image)
                view.layer.minificationFilter = .trilinear
                view.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    view.widthAnchor.constraint(equalToConstant: image.size.width * scale),
                    view.heightAnchor.constraint(equalToConstant: image.size.height * scale),
                ])
                return view
            })
            column.axis = .vertical
            column.alignment = .center
            column.spacing = -8 * scale
            column.isUserInteractionEnabled = false
            column.translatesAutoresizingMaskIntoConstraints = false
            addSubview(column)
            NSLayoutConstraint.activate([
                column.centerXAnchor.constraint(equalTo: centerXAnchor),
                column.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return
        }
        let label = UILabel()
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: max(13, 46 * scale), weight: .medium), .foregroundColor: UIColor.white,
        ])
        label.layer.shadowColor = UIColor(red: 0, green: 0.12, blue: 0.3, alpha: 1).cgColor
        label.layer.shadowOpacity = 1
        label.layer.shadowRadius = 2.5
        label.layer.shadowOffset = .zero
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "\n" + detail, attributes: [
                .font: UIFont.systemFont(ofSize: max(10, 30 * scale)), .foregroundColor: UIColor(white: 1, alpha: 0.9),
            ]))
        }
        label.attributedText = text
        label.numberOfLines = 2
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        // A banner row is 225 px with its glow; compact lists overlap the glows.
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.7),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            guard images.count > 2 else { return }
            background.image = UIImage(cgImage: isHighlighted ? images[2] : images[0])
        }
    }
}

private final class PaddedLabel: UILabel {
    override func drawText(in rect: CGRect) {
        super.drawText(in: backgroundColor == nil ? rect : rect.insetBy(dx: 16, dy: 8))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = super.sizeThatFits(size)
        return backgroundColor == nil ? fit : CGSize(width: fit.width + 32, height: fit.height + 16)
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

/// Which prefetched pictures have finished (uploaded or failed).
final class LucaPrefetched: @unchecked Sendable {
    private let lock = NSLock()
    private var done = Set<Int>()

    func finished(_ id: Int) {
        lock.lock()
        done.insert(id)
        lock.unlock()
    }

    /// Ids finished since last asked (decoded or not).
    func drainDone() -> Set<Int> {
        lock.lock()
        defer { done.removeAll(); lock.unlock() }
        return done
    }
}

struct LucaGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> LucaGameViewController {
        LucaGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: LucaGameViewController, context: Context) {}
}
