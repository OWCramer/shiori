// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CatSystemKit
import CoreText
import GameController
import SwiftUI
import UIKit

/// Plays a CatSystem2 game (NEKOPARA Vol. 3) with CatSystemKit, through the game's own
/// screens. The title, the save and load screens, CONFIG, the backlog and the confirmation
/// dialogs are the game's FES scripts run by `FESPlayer` (`CatSystemScreens` answers what
/// they ask of the engine: settings, saves, the backlog). GAME START runs the kcScripts to
/// the first scene, and `ScenePlayer` plays the story. The story's screen is drawn with Metal
/// every frame (`CatSystemStageRenderer`): each plane a texture, and the E-mote characters on
/// the GPU at the screen's resolution, posed for the moment by `EmoteStage`; `fmpl` faces are
/// drawn in the message window. Movies (WMV) play through `CatSystemMovie`. The message
/// window is the game's art (`meswnd.fes`'s band, name pictures and button row, each button
/// lighting up under the pointer and doing its job) with the text set in the game's font.
///
/// Input as on the PC: a tap or click reads on or presses what is under it; a right click,
/// a two-finger tap or Escape hides the window (or backs out of a screen); the wheel (or a
/// two-finger swipe down) opens the backlog; Ctrl held skips; Enter and Space read on. The
/// arrow keys move a highlight between the buttons of the game's screens (as the pointer
/// lights them; Enter presses) and, in the story, along the window's buttons (left and
/// right). A controller plays the same way: the d-pad moves, A reads on or presses, B is
/// the right click, Y (or LB) the backlog, RB or RT held skips, Menu opens CONFIG, Options
/// asks to leave. A two-finger hold leaves the game. On iPad, the game's cursor is drawn at
/// the pointer.
final class CatSystemGameViewController: UIViewController, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var onFirstFrame: (() -> Void)?
    private var game: CatSystemGame?
    private var emote: EmoteCast?
    /// The characters over time, and the Metal screen that draws the story every frame
    /// (nil without Metal: then the story is composited on the CPU, characters still).
    private var emoteStage: EmoteStage?
    /// The faces in the message window (`fmpl`), timed the same way.
    private var faceStage: EmoteStage?
    /// Made once the game opens (its shaders are compiled off the main thread).
    private var stageRenderer: CatSystemStageRenderer?
    /// The planes' motions (`pl N amove1`, `ascale1`, `fade`, `quake`).
    private let planeStage = PlaneStage()
    /// Plane pictures and colours on the GPU, by file name or colour (the last 24).
    private var planeTextures: [String: MTLTexture] = [:]
    private var planeTextureOrder: [String] = []
    /// Rule pictures (`wipe04a`) for wipes, kept once made.
    private var ruleTextures: [String: MTLTexture] = [:]
    /// The next transition's rule picture (`rwipe wipe04a 40`), if it is a wipe.
    private var transitionRule: String?
    /// The next transition's largest mosaic block (`rwmos 60 60 1`), if it is a mosaic.
    private var transitionMosaic: Int?
    /// Emotion marks by the characters' heads (`particle3 … em_note …`).
    private let particles = ParticleStage()
    private let audio = CatSystemAudio()
    private var displayLink: CADisplayLink?
    private var leaving = false

    // The 1280×720 stage, scaled to fit; everything in it is in game pixels.
    private let stageSize = CGSize(width: 1280, height: 720)
    private let stage = UIView()
    private let picture = CALayer()
    /// The game's system screens over the story (save, load, CONFIG, backlog, dialogs).
    private let screenLayer = CALayer()
    private let window = UIView()
    private let windowBand = UIImageView()
    private let nameImage = UIImageView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let keyWait = UIImageView()
    private let helpBalloon = UIImageView()
    private var windowButtons: [WindowButton] = []
    private var textFont = UIFont.systemFont(ofSize: 25, weight: .semibold)
    private var nameFont = UIFont.systemFont(ofSize: 25, weight: .heavy)
    /// The game's fonts by file name (`genjyuugothicx-bold`), for its screens' text.
    private var fontNames: [String: String] = [:]
    /// Speakers (as the scenes name them) to their name pictures.
    private var speakerTable: [String: Int] = [:]
    private var namePictures: [String: HGImage] = [:]

    // Title (FES)
    private var fes: FESPlayer?
    private var fesDrawn: Int?
    private var startingStory = false

    // System screens over the story.
    private var screen: FESPlayer?
    private var screenKind = Screen.saveLoad
    private var screenDrawn: Int?
    private var screenHost: CatSystemScreens?
    /// The story's screen as a save's thumbnail, taken when the save screen opens.
    private var pendingThumbnail: CGImage?

    private enum Screen { case saveLoad, config, backlog }

    // Story
    private var story: ScenePlayer?
    private var shownPlanes: [Int: ScenePlayer.Plane]?
    private var shownCast: [Int: ScenePlayer.Character]?
    /// The next crossfade's length in frames (`rwipe`, `pl N fade`), else the game's default.
    private var transitionFrames: Int?
    private var transitionEnds: CFTimeInterval = 0
    private var waitUntil: CFTimeInterval = 0
    private var line: CatSystemLine?
    /// The story waits for a click (the line's click wait). A line ending `\@` shows at
    /// once and the scene goes on while it is read (its voice, expressions and marks) up to
    /// its click wait.
    private var atInput = false
    /// A click came before the line's click wait: what is left of it runs at once, and the
    /// story reads on when it gets there.
    private var hurrying = false
    private var lineScene = ""
    private var lineIndex = 0
    private var revealed = 0.0
    /// The story's state while the line on screen shows (what a save keeps).
    private var lineSnapshot: ScenePlayer.Snapshot?
    /// The lines read, each with the place to go back to (the backlog's jump back): the
    /// last 200, as Luca keeps.
    private var backlog: [CatSystemLine] = []
    private static let backlogLimit = 200
    private var musicName: String?
    private var images: [String: HGImage] = [:]
    private var imageOrder: [String] = []
    private(set) var settings = CatSystemSettings()
    private var readLines = CatSystemReadLines()
    /// A movie playing (`movie nekopara3op`): the story waits until it ends or a tap skips it.
    private var movie: CatSystemMovie?
    /// Auto mode (the window's AUTO button): lines read on by themselves once shown and voiced.
    private var autoMode = false
    /// Skip (the window's SKIP button, or Ctrl held): read lines fly by.
    private var skipMode = false
    private var controlHeld = false
    /// When the line on screen was fully shown with its voice ended (for Auto's wait).
    private var lineDoneAt: CFTimeInterval?
    private var lineVoiced = false
    /// The window hidden by a right click (or its button); any click brings it back.
    private var windowHiddenByPlayer = false
    /// The scene has the window up (`frameon`/`frameoff`).
    private var windowWanted = false

    // Pointer
    private var pointerInteraction: UIPointerInteraction?
    private let cursorLayer = CALayer()
    private var cursors: (normal: CatSystemCursor?, over: CatSystemCursor?) = (nil, nil)
    private var pointerHovering = false {
        didSet { if pointerHovering != oldValue { pointerInteraction?.invalidate(); if !pointerHovering { cursorLayer.isHidden = true } } }
    }
    private var pointerLocation: CGPoint?
    private var lastTouchWasPointer = false
    private var hoveredButton: Int?

    init(gameFolder: URL, onFirstFrame: @escaping () -> Void = {}, onExit: @escaping () -> Void) {
        self.gameFolder = gameFolder
        self.onFirstFrame = onFirstFrame
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var canBecomeFirstResponder: Bool { true }

    private var base: URL { gameFolder.appendingPathComponent("base", isDirectory: true) }
    private var saves: URL { gameFolder.appendingPathComponent("saves", isDirectory: true) }
    private var slots: CatSystemSlots { CatSystemSlots(folder: saves) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        stage.bounds = CGRect(origin: .zero, size: stageSize)
        stage.clipsToBounds = true
        stage.backgroundColor = .black
        view.addSubview(stage)
        picture.frame = stage.bounds
        picture.contentsGravity = .resize
        picture.minificationFilter = .trilinear
        stage.layer.addSublayer(picture)
        // The message window: sys_meswnd_n under the window's buttons (sys_meswnd), at y 460.
        window.frame = CGRect(x: 0, y: 460, width: 1280, height: 260)
        window.isUserInteractionEnabled = false
        window.alpha = 0
        stage.addSubview(window)
        windowBand.frame = window.bounds
        window.addSubview(windowBand)
        nameImage.contentMode = .topLeft
        window.addSubview(nameImage)
        nameLabel.frame = CGRect(x: 264, y: 66, width: 600, height: 44)
        textLabel.frame = CGRect(x: 245, y: 112, width: 802, height: 140)
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        // Text sits at the top of its box.
        textLabel.contentMode = .topLeft
        for label in [nameLabel, textLabel] { window.addSubview(label) }
        keyWait.frame = CGRect(x: 1039, y: 196, width: 34, height: 33)
        keyWait.animationDuration = 0.6
        window.addSubview(keyWait)
        helpBalloon.alpha = 0
        window.addSubview(helpBalloon)
        screenLayer.frame = stage.bounds
        screenLayer.contentsGravity = .resize
        screenLayer.isHidden = true
        stage.layer.addSublayer(screenLayer)
        screenLayer.zPosition = 10
        window.layer.zPosition = 5

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(secondaryAction))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.fingersOnly()
        view.addGestureRecognizer(twoFingerTap)
        tap.require(toFail: twoFingerTap)
        let secondary = view.addSecondaryClick(target: self, action: #selector(secondaryAction))
        tap.require(toFail: secondary)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(openBacklog))
        history.direction = .down
        history.numberOfTouchesRequired = 2
        history.fingersOnly()
        view.addGestureRecognizer(history)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        leave.fingersOnly()
        view.addGestureRecognizer(leave)
        twoFingerTap.require(toFail: leave)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.maximumNumberOfTouches = 1
        drag.delegate = self
        view.addGestureRecognizer(drag)
        // The shared gestures (spec, Touch): a swipe right (one finger, or two) is the window's
        // SKIP, a two-finger swipe up or holding a finger on the message window its AUTO.
        // A slider's drag goes first.
        for fingers in [1, 2] {
            view.addSwipe(.right, fingers: fingers, target: self, action: #selector(swipedSkip)).require(toFail: drag)
        }
        view.addSwipe(.up, fingers: 2, target: self, action: #selector(swipedAuto))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(heldOnWindow(_:)))
        hold.minimumPressDuration = 0.6
        hold.fingersOnly()
        view.addGestureRecognizer(hold)
        tap.require(toFail: hold)
        view.addHover(target: self, action: #selector(hovered(_:)))
        view.addScroll(target: self, action: #selector(scrolled(_:)))
        LaptopPad.shared.game = self
        let pointer = UIPointerInteraction(delegate: self)
        view.addInteraction(pointer)
        pointerInteraction = pointer
        cursorLayer.isHidden = true
        cursorLayer.zPosition = 1000
        cursorLayer.contentsGravity = .resize
        view.layer.addSublayer(cursorLayer)

        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        settings = CatSystemSettings.load(from: saves)
        readLines = CatSystemReadLines.load(from: saves)
        audio.voiceLevel = { [weak self] name in Float(self?.settings.voiceLevel(name) ?? 1) }
        applySettings()
        open()

        // While still in front (the thumbnail needs the GPU), the place is kept in a slot the
        // game's Load screen lists.
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.leaving else { return }
                self.savePlace(reason: "leaving the screen")
                self.readLines.save(to: self.saves)
                self.settings.save(to: self.saves)
            }
        }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
        // The controller drives the game (see `pad(_:)`); the launcher behind gets nothing.
        ControllerInput.gameReceiver = { [weak self] pad in self?.pad(pad) }
        #if DEBUG
        scheduleDebugInput()
        #endif
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        OrientationLock.set(.landscape, in: view.window?.windowScene)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        let scale = min(size.width / stageSize.width, size.height / stageSize.height)
        stage.transform = CGAffineTransform(scaleX: scale, y: scale)
        stage.center = CGPoint(x: size.width / 2, y: size.height / 2)
        // Text drawn sharp at the scaled size.
        let screen = view.window?.screen.scale ?? 3
        for label in [nameLabel, textLabel] { label.layer.contentsScale = max(1, screen * scale) }
        // Characters drawn at the screen's resolution.
        if let metal = stageRenderer?.layer {
            metal.contentsScale = max(1, screen * scale)
            metal.drawableSize = CGSize(width: (stageSize.width * scale * screen).rounded(), height: (stageSize.height * scale * screen).rounded())
        }
        if let faces = stageRenderer?.faceLayer {
            let box = CatSystemStageRenderer.faceBox
            faces.contentsScale = max(1, screen * scale)
            faces.drawableSize = CGSize(width: (box.width * scale * screen).rounded(), height: (box.height * scale * screen).rounded())
        }
        layoutCursor()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        stopMovie()
    }

    // MARK: Opening the game

    /// What opening the game prepares off the main thread, so the first frames don't wait.
    private struct Opened: @unchecked Sendable {
        let game: CatSystemGame
        let cast: EmoteCast
        let stage: CatSystemStageResources?
        let fonts: [String: String]
        let window: Window
        let title: FESPlayer?
        let titleError: Error?
        let speakers: [String: Int]
        let cursors: (normal: CatSystemCursor?, over: CatSystemCursor?)
    }

    /// The message window's art: the band, each button's three looks (`meswnd.fes`'s `btn`
    /// table: as drawn, under the pointer or disabled, pressed or on), the help balloons, the
    /// key-wait paw's frames and its place.
    private struct Window {
        var band: UIImage?
        var bandFrame = CGRect(x: 0, y: 0, width: 1280, height: 260)
        var buttons: [(ids: [Int], images: [UIImage], frame: CGRect)] = []
        var help: [Int: (image: UIImage, frame: CGRect)] = [:]
        /// The quick save's panel (`sys_meswnd_spanel`: 0 after saving, 1 to load), placed at
        /// sys_meswnd frame 2000.
        var quickPanel: [UIImage] = []
        var quickPanelFrame = CGRect(x: 649, y: 112, width: 434, height: 120)
        var wait: [UIImage] = []
        var waitFrame: CGRect?
    }

    /// Opens the archives (their name key is recovered once, about a second, and kept in
    /// Caches), then everything the first screens need, all off the main thread: the game's
    /// fonts, the E-mote profiles, the Metal shaders, the message window's art and the boot
    /// flow's script with its first pictures. The title's pictures keep decoding in the
    /// background while the logo shows.
    private func open() {
        let base = base
        // patch/ shadows base/: loose files first, then replacement or extra .int archives.
        let patchFolder = gameFolder.appendingPathComponent("patch", isDirectory: true)
        let patch = FileManager.default.fileExists(atPath: patchFolder.path) ? patchFolder : nil
        let cache = URL.cachesDirectory.appendingPathComponent("CatSystem/\(gameFolder.lastPathComponent)", isDirectory: true)
        let keyFile = cache.appendingPathComponent("namekey")
        let settings = settings
        Task.detached(priority: .userInitiated) {
            let started = CACurrentMediaTime()
            let known = (try? String(contentsOf: keyFile, encoding: .utf8)).flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) }
            let result = Result { try CatSystemGame(root: base, patch: patch, nameKey: known) }
            guard case .success(let game) = result else {
                await MainActor.run { [weak self] in
                    if case .failure(let error) = result { self?.fail("This game can't start", error) }
                }
                return
            }
            if known == nil, let key = game.nameKey {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? String(key, radix: 16).write(to: keyFile, atomically: true, encoding: .utf8)
            }
            let archives = CACurrentMediaTime()
            let fonts = Self.registerFonts(in: base.appendingPathComponent("font", isDirectory: true))
            let cast = EmoteCast(game: game)
            let stage = CatSystemStageResources.make()
            let window = Self.windowArt(game)
            let title = Self.makePlayer(game: game, fonts: fonts, settings: settings)
            var titleError: Error?
            do { try title.start("flow") } catch { titleError = error }
            title.preload(scripts: ["flow", "brandlogo"])
            let cursorFolder = base.appendingPathComponent("cursor", isDirectory: true)
            let cursors = (CatSystemCursor(url: cursorFolder.appendingPathComponent("cursor.cur")),
                           CatSystemCursor(url: cursorFolder.appendingPathComponent("cur_over.cur")))
            NSLog("CatSystem: opened in %.2f s (archives %.2f s), all off the main thread",
                  CACurrentMediaTime() - started, archives - started)
            let opened = Opened(game: game, cast: cast, stage: stage, fonts: fonts, window: window,
                                title: titleError == nil ? title : nil, titleError: titleError,
                                speakers: game.speakerTable(), cursors: cursors)
            await MainActor.run { [weak self] in self?.opened(opened) }
            // The language picker's and the title's pictures, while the logo shows; then the
            // save, CONFIG and backlog screens'.
            let preloading = CACurrentMediaTime()
            title.preload(scripts: ["langselect", "title", "ttlflow", "confirm", "confirm2", "saveload", "config", "hist_b"])
            NSLog("CatSystem: title and system screen pictures decoded in %.2f s", CACurrentMediaTime() - preloading)
        }
    }

    /// A FES player as the game's screens need it: the window's and log's art names
    /// (`meswnd01.xml`), the fonts, the language, and the scripts' lasting variables (a
    /// first run's from `flow.fes`'s `INIT_GLOBAL`).
    nonisolated private static func makePlayer(game: CatSystemGame, fonts: [String: String], settings: CatSystemSettings) -> FESPlayer {
        let player = FESPlayer(game: game)
        player.fonts = fonts
        player.language = ["en", "jp", "cn"][max(0, min(2, settings.value("lang_ui")))]
        for (n, v) in [(900, "sys_meswnd_n"), (901, "sys_meswnd"), (902, "sys_meswnd_fmask"), (910, "sys_log"), (911, "sys_log_cursor")] {
            player.setString(n, v)
        }
        let globals = settings.globals.isEmpty ? player.assignments(script: "flow", block: "INIT_GLOBAL") : settings.globals
        for (n, v) in globals { player.setVariable(n, v) }
        // `$897` says the language picker was answered; the flow goes straight to the title.
        if settings.languageChosen { player.setVariable(897, 1) }
        return player
    }

    private func opened(_ opened: Opened) {
        let game = opened.game
        self.game = game
        emote = opened.cast
        emoteStage = EmoteStage(cast: opened.cast)
        faceStage = EmoteStage(cast: opened.cast)
        fontNames = opened.fonts
        speakerTable = opened.speakers
        cursors = opened.cursors
        if let name = opened.fonts["genjyuugothicx-bold"], let font = UIFont(name: name, size: 25) { textFont = font }
        if let name = opened.fonts["genjyuugothicx-heavy"] ?? opened.fonts["genjyuugothicx-bold"], let font = UIFont(name: name, size: 27) { nameFont = font }
        windowBand.image = opened.window.band
        windowBand.frame = opened.window.bandFrame
        #if DEBUG
        NSLog("CatSystem: window band %@, %d buttons, %d help balloons", opened.window.band.map { "\($0.size)" } ?? "missing",
              opened.window.buttons.count, opened.window.help.count)
        #endif
        for (i, b) in opened.window.buttons.enumerated() {
            let button = WindowButton(index: i, images: b.images, frame: b.frame)
            window.insertSubview(button.view, belowSubview: helpBalloon)
            windowButtons.append(button)
        }
        windowHelp = opened.window.help
        quickPanel.setUp(images: opened.window.quickPanel, frame: opened.window.quickPanelFrame, fonts: opened.fonts)
        window.addSubview(quickPanel.view)
        keyWait.animationImages = opened.window.wait
        if let frame = opened.window.waitFrame { keyWait.frame = frame }
        if let resources = opened.stage, let renderer = CatSystemStageRenderer(resources: resources) {
            stageRenderer = renderer
            renderer.layer.frame = stage.bounds
            renderer.layer.isHidden = true
            stage.layer.insertSublayer(renderer.layer, above: picture)
            renderer.faceLayer.frame = CatSystemStageRenderer.faceBox
            window.layer.insertSublayer(renderer.faceLayer, above: windowBand.layer)
            view.setNeedsLayout()
        }
        applySettings()
        #if DEBUG
        // `-ShioriCatSystemLoad latest`: loads the newest save straight away (unattended runs).
        if UserDefaults.standard.string(forKey: "ShioriCatSystemLoad") == "latest", let save = CatSystemSave.list(in: saves).first {
            load(save)
            return
        }
        #endif
        if let error = opened.titleError {
            fail("This game can't start", error)
            return
        }
        startTitle(skipLogo: false, prepared: opened.title)
    }

    private var windowHelp: [Int: (image: UIImage, frame: CGRect)] = [:]
    private let quickPanel = QuickPanel()

    /// The window's quick save panel: the game's panel art, the thumbnail and the save's
    /// title, date and line, in the game's brown with a white edge.
    @MainActor private final class QuickPanel {
        let view = UIView()
        private let art = UIImageView()
        private let thumbnail = UIImageView()
        private let title = UILabel(), date = UILabel(), comment = UILabel()
        private var images: [UIImage] = []
        private var fonts: [String: String] = [:]
        private var origin = CGPoint.zero
        private var hideWork: DispatchWorkItem?

        func setUp(images: [UIImage], frame: CGRect, fonts: [String: String]) {
            self.images = images
            self.fonts = fonts
            origin = frame.origin
            view.frame = frame
            view.alpha = 0
            view.isUserInteractionEnabled = false
            art.frame = view.bounds
            thumbnail.frame = CGRect(x: 8, y: 8, width: 185, height: 104)
            thumbnail.contentMode = .scaleAspectFill
            thumbnail.clipsToBounds = true
            // sys_meswnd frames 2012, 2013, 2015 less the panel's place.
            title.frame = CGRect(x: 850 - frame.minX, y: 122 - frame.minY, width: 223, height: 23)
            date.frame = CGRect(x: 850 - frame.minX, y: 150 - frame.minY, width: 223, height: 20)
            comment.frame = CGRect(x: 867 - frame.minX, y: 179 - frame.minY, width: 204, height: 20)
            for v in [art, thumbnail, title, date, comment] { view.addSubview(v) }
        }

        private func text(_ string: String, size: CGFloat) -> NSAttributedString {
            let font = UIFont(name: fonts["genjyuugothicx-bold"] ?? "", size: size) ?? .boldSystemFont(ofSize: size)
            return NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: UIColor(red: 67 / 255, green: 33 / 255, blue: 0, alpha: 1),
                .strokeColor: UIColor.white, .strokeWidth: -3,
            ])
        }

        func show(_ save: CatSystemSave, thumbnail rgba: (rgba: [UInt8], width: Int, height: Int)?, loading: Bool) {
            hideWork?.cancel()
            art.image = images.indices.contains(loading ? 1 : 0) ? images[loading ? 1 : 0] : nil
            thumbnail.image = rgba.flatMap { t in
                CatSystemGameViewController.cgImage(t.rgba, width: t.width, height: t.height, opaque: true).map { UIImage(cgImage: $0) }
            }
            title.attributedText = text("Quick Save", size: 20)
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: save.date)
            let stamp = String(format: "%04d/%02d/%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
            date.attributedText = text("Quick : " + stamp, size: 16)
            comment.attributedText = text((save.speaker.map { "\($0): " } ?? "") + save.text, size: 14)
            comment.lineBreakMode = .byTruncatingTail
            guard view.alpha < 1 else { return }
            view.frame.origin = CGPoint(x: origin.x + 8, y: origin.y)
            UIView.animate(withDuration: 8.0 / 60) {
                self.view.alpha = 1
                self.view.frame.origin = self.origin
            }
        }

        func hide(after delay: Double = 0) {
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 8.0 / 60) { self.view.alpha = 0 }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func fail(_ title: String, _ error: Error) {
        NSLog("CatSystem: %@: %@", title, String(describing: error))
        let alert = UIAlertController(title: title, message: String(describing: error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    /// Registers the game's fonts (`font/`, GenJyuu Gothic X and Noto Sans CJK) for this
    /// process: file names (lower-cased, without extension) to the names they registered as.
    nonisolated private static func registerFonts(in folder: URL) -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var names: [String: String] = [:]
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let name = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }) {
                names[url.deletingPathExtension().lastPathComponent.lowercased()] = name
            }
        }
        return names
    }

    /// The window's art, from `meswnd.fes`: the band (`sys_meswnd_n`), the buttons' frames
    /// (`btn[i]` ids from its table: 0 skip, 1 auto, 2 log, 3 config, 4 save, 5 load, 6 quick
    /// save, 7 quick load, 8 hide the window, 9 replay the voice), the help balloons
    /// (`sys_meswnd_help`, `help[i]`) and the key-wait paw.
    nonisolated private static func windowArt(_ game: CatSystemGame) -> Window {
        func picture(_ name: String) -> HGImage? {
            ((try? game.file(named: name + ".hg3")) ?? nil).flatMap { try? HGImage($0) }
        }
        func image(_ frame: HGImage.Frame) -> UIImage? { layerImage(frame).map { UIImage(cgImage: $0) } }
        var window = Window()
        if let band = picture("sys_meswnd_n")?.frames.first {
            window.band = image(band)
            window.bandFrame = CGRect(x: band.offsetX, y: band.offsetY, width: band.width, height: band.height)
        }
        var buttonIDs: [Int: [Int]] = [:]
        var helpIDs: [Int: Int] = [:]
        if let bytes = (try? game.file(named: "meswnd.fes")) ?? nil, let text = try? FESScript.text(bytes) {
            for table in FESProgram(text: text).tables {
                for (name, values) in table.rows {
                    guard name.hasPrefix("btn["), let i = Int(name.dropFirst(4).dropLast()) else {
                        if name.hasPrefix("help["), let i = Int(name.dropFirst(5).dropLast()), table.columns == ["ID.0"], let id = values.first.flatMap({ Int($0) }) {
                            helpIDs[i] = id
                        }
                        continue
                    }
                    if table.columns.starts(with: ["ID.0", "ID.1", "ID.2"]) { buttonIDs[i] = values.prefix(3).compactMap { Int($0) } }
                }
            }
        }
        let parts = picture("sys_meswnd")
        for i in buttonIDs.keys.sorted() {
            guard let ids = buttonIDs[i], ids.count == 3 else { continue }
            let frames = ids.compactMap { parts?.frame(id: $0) }
            guard frames.count == 3 else { continue }
            let f = frames[0]
            window.buttons.append((ids, frames.compactMap(image), CGRect(x: f.offsetX, y: f.offsetY, width: f.width, height: f.height)))
        }
        // The balloons sit at sys_meswnd frame 3 (`imgpos[1]`), each frame placed by its offset.
        let balloonAt = parts?.frame(id: 3).map { CGPoint(x: $0.offsetX, y: $0.offsetY) } ?? CGPoint(x: 1081, y: 224)
        if let help = picture("sys_meswnd_help") {
            for (i, id) in helpIDs {
                guard let f = help.frame(id: id), let img = image(f) else { continue }
                window.help[i] = (img, CGRect(x: balloonAt.x + CGFloat(f.offsetX), y: balloonAt.y + CGFloat(f.offsetY), width: CGFloat(f.width), height: CGFloat(f.height)))
            }
        }
        if let panel = picture("sys_meswnd_spanel") {
            window.quickPanel = [0, 1].compactMap { panel.frame(id: $0).flatMap(image) }
        }
        if let at = parts?.frame(id: 2000) {
            window.quickPanelFrame = CGRect(x: at.offsetX, y: at.offsetY, width: at.width, height: at.height)
        }
        if let wait = picture("sys_meswnd_wait") {
            window.wait = (11...19).compactMap { wait.frame(id: $0).flatMap(layerImage).map { UIImage(cgImage: $0) } }
        }
        if let marker = parts?.frame(id: 50) {
            window.waitFrame = CGRect(x: marker.offsetX, y: marker.offsetY + 4, width: 34, height: 33)
        }
        return window
    }

    // MARK: Frames

    /// When the last frame began, to log the main thread stalling (a frame late by 0.1 s).
    private var lastFrame: CFTimeInterval = 0

    @objc private func frame() {
        let now = CACurrentMediaTime()
        if lastFrame > 0, now - lastFrame > 0.1 {
            NSLog("CatSystem: the main thread was busy for %.0f ms (%@)", (now - lastFrame) * 1000,
                  movie != nil ? "movie" : screen != nil ? "screen" : fes != nil ? "title" : "story")
        }
        lastFrame = now
        audio.tick()
        if settingsDirty, now - settingsSaved > 1 {
            settingsDirty = false
            settingsSaved = now
            settings.save(to: saves)
        }
        if let movie {
            movie.draw()
            if movie.finished { endMovie() }
        } else if let screen {
            screenFrame(screen)
            drawStage()
        } else if let fes {
            titleFrame(fes)
        } else if story != nil {
            storyFrame()
        }
        #if DEBUG
        if let p = debugPointer, frameCounter % 30 == 0 { pointerMoved(to: p) }
        frameCounter += 1
        #endif
        updateCursor()
    }

    private var frameCounter = 0

    private func liftCover() {
        if let lift = onFirstFrame {
            onFirstFrame = nil
            lift()
        }
    }

    // MARK: Title

    /// The boot flow (`flow.fes`): the logo and language picker on the first opening, else
    /// (`$513`, coming back from the story) the title straight away.
    private func startTitle(skipLogo: Bool, prepared: FESPlayer? = nil) {
        guard let game else { return }
        stopMovie()
        closeScreen()
        readLines.save(to: saves)
        story = nil
        line = nil
        lineSnapshot = nil
        shownPlanes = nil
        shownCast = nil
        autoMode = false
        skipMode = false
        stageRenderer?.layer.isHidden = true
        emoteStage?.reset([:], time: 0)
        faceStage?.reset([:], time: 0)
        particles.reset()
        atInput = false
        hurrying = false
        stageRenderer?.renderFaces([])
        audio.stopAll()
        musicName = nil
        windowWanted = false
        windowHiddenByPlayer = false
        setWindow(visible: false, frames: 0)
        let player: FESPlayer
        if let prepared {
            player = prepared
        } else {
            player = Self.makePlayer(game: game, fonts: fontNames, settings: settings)
            if skipLogo { player.setVariable(513, 1) }
            do {
                try player.start("flow")
            } catch {
                fail("This game can't start", error)
                return
            }
        }
        let host = CatSystemScreens(controller: self)
        screenHost = host
        player.host = host
        fes = player
        fesDrawn = nil
        startingStory = false
    }

    private func titleFrame(_ fes: FESPlayer) {
        guard game != nil else { return }
        fes.step()
        playSounds(fes)
        keepGlobals(fes)
        if !settings.languageChosen, fes.stack.contains(where: { $0.hasPrefix("title#") }) {
            settings.languageChosen = true
            settings.save(to: saves)
        }
        draw(fes, into: picture, drawn: &fesDrawn, opaque: true)
        // GAME START or a save picked in DATA LOAD: flow.fes asks for sscript, with `$512`
        // -3 for a new game or the slot to load.
        if !startingStory, fes.requestedKCS == "sscript" {
            startingStory = true
            let slot = fes.variables[512] ?? -3
            if slot >= 0, let save = save(forSlot: slot) {
                load(save)
            } else {
                startStory(after: fes)
            }
        } else if fes.rootExitCode != nil {
            // EXIT: the title's own way out.
            leave()
        }
    }

    /// Draws a FES player's screen into a layer when it changes (with the crossfade the
    /// scripts ask for, `rdraw`).
    private func draw(_ player: FESPlayer, into layer: CALayer, drawn: inout Int?, opaque: Bool) {
        let state = player.drawState
        let fade = player.takeTransition()
        guard state != drawn || fade != nil else { return }
        drawn = state
        let started = CACurrentMediaTime()
        let rgba = player.render()
        let took = CACurrentMediaTime() - started
        if took > 0.03 { NSLog("CatSystem: a FES screen took %.0f ms to draw", took * 1000) }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let fade, fade > 0 {
            let t = CATransition()
            t.type = .fade
            t.duration = Double(fade) / 60
            layer.add(t, forKey: "fade")
        }
        layer.contents = opaque ? Self.cgImage(rgba, width: player.width, height: player.height, opaque: true)
            : Self.cgImage(premultiplied: rgba, width: player.width, height: player.height)
        CATransaction.commit()
        liftCover()
    }

    /// Plays what a FES screen started: music tables, voices (the title's, CONFIG's voice
    /// tests), and the system sounds.
    private func playSounds(_ player: FESPlayer) {
        guard let game else { return }
        for sound in player.takeSounds() {
            let channel = sound.channel.lowercased()
            let isVoice = sound.group == "voice" || channel.hasPrefix("voice") || channel.hasPrefix("sound_testpcm")
            if let file = sound.file {
                if sound.table {
                    audio.playMusic(file, game: game, fadeFrames: 30)
                } else if isVoice {
                    audio.playVoice(file, game: game)
                } else {
                    audio.playEffect(file, channel: "sys-" + channel, game: game)
                }
            } else if sound.table {
                audio.stopMusic(fadeFrames: 30)
            } else if isVoice {
                audio.stopVoice()
            } else {
                audio.stopEffect("sys-" + channel, fadeFrames: 0)
            }
        }
    }

    /// Keeps the scripts' lasting variables (`$900`–`$999`: help balloons, confirmations,
    /// system sounds; `$660`, `$661`, `$670`) for later screens and launches.
    private func keepGlobals(_ player: FESPlayer) {
        var kept = settings.globals
        for (n, v) in player.variables where (900...999).contains(n) || [660, 661, 670].contains(n) { kept[n] = v }
        if kept != settings.globals { settings.globals = kept }
    }

    /// Runs main.kcs and sscript.kcs to the first scene (well under a second), then plays it.
    private func startStory(after fes: FESPlayer) {
        guard let game else { return }
        let variables = fes.variables, strings = fes.stringVariables
        Task.detached(priority: .userInitiated) {
            let result = Result { try KCSBoot.firstScene(game: game, variables: variables, strings: strings) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let boot):
                    NSLog("CatSystem: story starts at scene %@", boot.scene)
                    self.beginStory(scene: boot.scene, variables: boot.variables)
                case .failure(let error):
                    self.fail("The story couldn't start", error)
                }
            }
        }
    }

    private func beginStory(scene: String, variables: [Int: Int]) {
        guard let game else { return }
        let player = ScenePlayer(game: game, variables: variables)
        player.language = storyLanguage
        player.emote = emote
        do { try player.start(scene) } catch {
            fail("The story couldn't start", error)
            return
        }
        fes = nil
        audio.stopAll()
        story = player
        shownPlanes = nil
        shownCast = nil
        transitionFrames = nil
        transitionRule = nil
        transitionMosaic = nil
        planeStage.reset([:])
        particles.reset()
        waitUntil = 0
        backlog = []
        line = nil
        atInput = false
        hurrying = false
        windowHiddenByPlayer = false
        refreshButtons()
    }

    /// The CONFIG's main text language for the story (`lang_text_main`: 0 English, 1
    /// Japanese, 2 Chinese).
    private var storyLanguage: String { ["en", "jp", "cn"][max(0, min(2, settings.value("lang_text_main")))] }

    // MARK: Story

    private func storyFrame() {
        if movie != nil { return }
        if let line {
            revealLine()
            if skipping {
                skipLine(line)
            } else {
                autoAdvance(line)
            }
        }
        if !atInput, movie == nil, CACurrentMediaTime() >= waitUntil || skipping || hurrying {
            if skipping || hurrying { waitUntil = 0; stageRenderer?.endCrossfade(); planeStage.finishMotions() }
            pump()
        }
        drawStage()
    }

    /// Skip mode (its button) or Ctrl held.
    private var skipping: Bool { skipMode || controlHeld }

    /// Skips the line on screen if Skip may (read before, or the CONFIG says all text), else
    /// stops skipping there.
    private func skipLine(_ line: CatSystemLine) {
        let all = controlHeld && !skipMode ? settings.value("ctrlmode") == 0 : settings.value("fullskip") == 1
        if all || readBefore {
            readOn()
        } else if skipMode {
            // New text: Skip stops here, and the line is voiced as usual.
            skipMode = false
            refreshButtons()
            if let voice = line.voice, let game { audio.playVoice(voice, game: game) }
        }
    }

    /// Whether the line on screen was read in an earlier pass.
    private var readBefore = false

    /// The story's screen this frame: characters posed for now (idle, blinks, the voice's
    /// lip sync, motions under way), drawn with Metal.
    private func drawStage() {
        guard story != nil, let stageRenderer, let emoteStage, !stageRenderer.layer.isHidden else { return }
        let now = CACurrentMediaTime()
        emoteStage.setVoice(audio.isVoicePlaying ? audio.voiceName : nil, startedAt: audio.voiceStarted, envelope: audio.voiceEnvelope)
        stageRenderer.render(layers: stageLayers(stageRenderer, at: now), emoteStage.drawings(at: now),
                             marks: markDrawings(stageRenderer, at: now))
        if let faceStage {
            faceStage.setVoice(audio.isVoicePlaying ? audio.voiceName : nil, startedAt: audio.voiceStarted, envelope: audio.voiceEnvelope)
            stageRenderer.renderFaces(faceStage.drawings(at: now))
        }
    }

    /// Runs the story until it shows a line or waits.
    private func pump() {
        var budget = 4000
        while budget > 0, let story, !atInput, movie == nil, screen == nil, CACurrentMediaTime() >= waitUntil || skipping || hurrying {
            budget -= 1
            let event: ScenePlayer.Event?
            do { event = try story.next() } catch {
                fail("The story stopped", error)
                self.story = nil
                return
            }
            guard let event else { storyEnded(); return }
            switch event {
            case .command(let text): command(text)
            case .message(let message): show(message)
            case .end: storyEnded(); return
            case .scene(let name): NSLog("CatSystem: scene %@", name)
            case .missingScene: break
            case .input: reachedInput()
            }
        }
    }

    private func storyEnded() {
        autosave()
        startTitle(skipLogo: true)
    }

    private func command(_ text: String) {
        guard let game, let story else { return }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = words.first else { return }
        let now = CACurrentMediaTime()
        switch verb {
        case "wait":
            present()
            if skipping || hurrying { break }
            if words.count >= 2, let frames = Int(words[1]) {
                waitUntil = now + Double(frames) / 60
            } else if words.count == 1 {
                waitUntil = max(waitUntil, transitionEnds)
            }
        case "rwipe":
            // `rwipe wipe04a 40`: a wipe through the rule picture (`wipedef`, 40 frames).
            transitionFrames = words.count >= 3 ? Int(words[2]) ?? 40 : 40
            transitionRule = words.count >= 2 ? words[1] : nil
            transitionMosaic = nil
        case "rdraw":
            // `rdraw 60`: the next drawing crossfades over its frames (`drawdef`, 15).
            transitionFrames = words.count >= 2 ? Int(words[1]) ?? 15 : 15
            transitionRule = nil
            transitionMosaic = nil
        case "rwmos":
            // `rwmos 60 60 1`: the next drawing comes through a mosaic over 60 frames, its
            // blocks growing to 60 pixels at the middle (into and out of daydreams).
            transitionFrames = words.count >= 2 ? Int(words[1]) ?? 60 : 60
            transitionMosaic = words.count >= 3 ? Int(words[2]) ?? 60 : 60
            transitionRule = nil
        case "particle", "particle2", "particle3":
            particles.command(text, time: now) { [weak self] bank in self?.emoteStage?.place(bank: bank, at: now) }
        case "pl":
            planeMotion(words, text: text, story: story, time: now)
        case "bgm":
            if let name = story.bgm {
                if name != musicName { audio.playMusic(name, game: game) }
            } else if musicName != nil {
                let fade = words.count >= 4 && words[2] == "end" ? Int(words[3]) ?? 60 : 60
                audio.stopMusic(fadeFrames: fade)
            }
            musicName = story.bgm
        case "se":
            if skipping, words.count >= 3, !["end", "stop", "vol", "fade"].contains(words[2]), !words[2].hasPrefix("bgs") { break }
            soundEffect(Array(words.dropFirst()), game: game)
        case "frameoff":
            windowWanted = false
            setWindow(visible: false, frames: words.count >= 3 ? Int(words[2]) ?? 15 : 15)
        case "frameon":
            windowWanted = true
            setWindow(visible: true, frames: words.count >= 3 ? Int(words[2]) ?? 15 : 15)
        case "movie" where words.count >= 2:
            playMovie(words[1], game: game)
        case "mpl":
            emoteStage?.command(text, cast: story.cast, time: now)
        case "fmpl":
            faceStage?.command(text, cast: story.faces, time: now)
        default:
            break
        }
    }

    // MARK: Movies

    /// Plays a movie over everything; the story goes on when it ends or a tap skips it.
    private func playMovie(_ name: String, game: CatSystemGame) {
        present()
        guard let player = CatSystemMovie(name: name, game: game, volume: audio.musicVolume * Float(settings.master)) else {
            NSLog("CatSystem: movie %@ doesn't play here; skipped", name)
            return
        }
        player.layer.frame = stage.bounds
        let scale = stage.transform.a, screen = view.window?.screen.scale ?? 3
        player.layer.contentsScale = max(1, screen * scale)
        player.layer.drawableSize = CGSize(width: (stageSize.width * scale * screen).rounded(),
                                           height: (stageSize.height * scale * screen).rounded())
        player.layer.zPosition = 20
        stage.layer.addSublayer(player.layer)
        movie = player
        player.start()
    }

    private func endMovie() {
        guard movie != nil else { return }
        stopMovie()
        NSLog("CatSystem: movie ended")
        pump()
    }

    private func stopMovie() {
        movie?.stop()
        movie?.layer.removeFromSuperlayer()
        movie = nil
    }

    /// `se`, `se N`, `se N file`, `se N end frames`, `se N vol v`.
    private func soundEffect(_ args: [String], game: CatSystemGame) {
        guard let channel = args.first, Int(channel) != nil else {
            audio.stopEffect(nil, fadeFrames: 0)
            return
        }
        guard args.count >= 2 else {
            audio.stopEffect(channel, fadeFrames: 0)
            return
        }
        switch args[1] {
        case "end", "stop": audio.stopEffect(channel, fadeFrames: args.count >= 3 ? Int(args[2]) ?? 0 : 0)
        case "vol" where args.count >= 3:
            audio.fadeEffect(channel, frames: 0, from: nil, to: Float(args[2].replacingOccurrences(of: "%", with: "")).map { $0 / 100 } ?? 1)
        case "fade" where args.count >= 5:
            // `se N fade frames from to`: the channel's volume, in percent.
            audio.fadeEffect(channel, frames: Int(args[2]) ?? 0, from: Float(args[3]).map { $0 / 100 }, to: (Float(args[4]) ?? 100) / 100)
        case "vol", "fade": break
        default: audio.playEffect(args[1], channel: channel, loop: args.dropFirst(2).contains("loop") || args[1].hasPrefix("bgs"), game: game)
        }
    }

    /// Shows the planes as they are now, crossfading from what was shown.
    private func present(force: Bool = false) {
        if let stageRenderer {
            presentPlanes(stageRenderer, force: force)
            return
        }
        guard let story, force || story.planes != shownPlanes || story.cast != shownCast else { return }
        shownPlanes = story.planes
        shownCast = story.cast
        let rgba = story.render(width: Int(stageSize.width), height: Int(stageSize.height), emote: emote) { [weak self] name in
            self?.image(name)
        }
        let frames = force || skipping ? 0 : transitionFrames ?? 15
        transitionFrames = nil
        let image = Self.cgImage(rgba, width: Int(stageSize.width), height: Int(stageSize.height), opaque: true)
        picture.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frames > 0 {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Double(frames) / 60
            picture.add(fade, forKey: "fade")
        }
        picture.contents = image
        CATransaction.commit()
        transitionEnds = CACurrentMediaTime() + Double(frames) / 60
        liftCover()
    }

    /// With Metal: each plane is drawn every frame from its picture's texture, placed,
    /// scaled, faded and shaken by `PlaneStage`. What the planes show changes here, at a
    /// drawing point (`wait`, a line): a change of pictures or places, an explicit transition
    /// (`rdraw`, `rwipe` with its rule picture) or a character coming, going or changing body
    /// crossfades or wipes the whole screen from the last frame (the game's `drawdef`, 15
    /// frames; a character's profile fade, 20, for the last). Motions (`pl N amove1`, `fade`,
    /// `quake`) play out on their own; expressions and character motions in `EmoteStage`.
    private func presentPlanes(_ renderer: CatSystemStageRenderer, force: Bool) {
        guard let story else { return }
        let planesChanged = force || story.planes != shownPlanes
        func bodies(_ cast: [Int: ScenePlayer.Character]?) -> [Int: String] {
            (cast ?? [:]).compactMapValues { c in
                guard c.visible, let model = c.model else { return nil }
                return model.split(separator: ",").prefix(2).joined(separator: ",")
            }
        }
        let castChanged = bodies(story.cast) != bodies(shownCast)
        guard planesChanged || castChanged || transitionFrames != nil else { return }
        shownPlanes = story.planes
        shownCast = story.cast
        planeStage.sync(story.planes)
        let frames = force || skipping ? 0 : transitionFrames ?? (planesChanged ? 15 : 20)
        let transitionRuleName = transitionRule
        let rule = force ? nil : transitionRule.flatMap { ruleTexture($0, renderer) }
        let mosaic = force ? nil : transitionMosaic.map(Double.init)
        transitionFrames = nil
        transitionRule = nil
        transitionMosaic = nil
        if renderer.layer.isHidden {
            renderer.layer.isHidden = false
        } else if frames > 0 {
            var seconds = Double(frames) / 60
            #if DEBUG
            // `-ShioriCatSystemSlowTransitions 8`: transitions eight times as long (to look at wipes).
            let slow = UserDefaults.standard.double(forKey: "ShioriCatSystemSlowTransitions")
            if slow > 0 { seconds *= slow }
            #endif
            renderer.transition(seconds: seconds, rule: rule, mosaic: mosaic)
            if rule != nil { NSLog("CatSystem: wipe %@ over %.2f s", transitionRuleName ?? "?", seconds) }
            if let mosaic { NSLog("CatSystem: mosaic to %.0f px over %.2f s", mosaic, seconds) }
        }
        transitionEnds = CACurrentMediaTime() + Double(frames) / 60
        liftCover()
    }

    /// `pl N amove1/2/3`, `move`, `ascale1/2/3`, `fade`, `quake`, `stop` (and `pl quake`
    /// for every plane) start at once on what is shown, without a transition.
    private func planeMotion(_ words: [String], text: String, story: ScenePlayer, time: Double) {
        guard words.count >= 3 else { return }
        let motions: Set<String> = ["amove1", "amove2", "amove3", "move", "ascale1", "ascale2", "ascale3",
                                    "fade", "m2fade", "quake", "stop", "m2move", "m2amove1", "m2amove1p", "m2scale", "m2ascale1p"]
        let target = words[1]
        let numbered = Int(target) != nil || target.hasPrefix("[")
        guard motions.contains(numbered ? words[2] : target) else { return }
        if numbered, var shown = shownPlanes {
            for n in ScenePlayer.planeNumbers(target) {
                guard let now = story.planes[n], var old = shown[n] else { continue }
                old.x = now.x; old.y = now.y
                old.scaleX = now.scaleX; old.scaleY = now.scaleY
                old.alpha = now.alpha
                shown[n] = old
            }
            shownPlanes = shown
        }
        planeStage.command(text, planes: shownPlanes ?? [:], time: time)
        if skipping { planeStage.finishMotions() }
    }

    /// The screen at `time`, back to front: the planes' pictures as `PlaneStage` has them now
    /// and the characters among them, by priority (`StageLayout`).
    private func stageLayers(_ renderer: CatSystemStageRenderer, at time: Double) -> [CatSystemStageRenderer.Layer] {
        guard let planes = shownPlanes else { return [] }
        let items = StageLayout.items(planes: planes, cast: story?.cast ?? shownCast ?? [:],
                                      width: Int(stageSize.width), height: Int(stageSize.height),
                                      state: { planeStage.state($0, $1, at: time) },
                                      frame: { [weak self] in self?.image($0)?.frames.first })
        func texture(_ name: String, _ effect: PictureEffect = PictureEffect()) -> MTLTexture? {
            guard let frame = image(name)?.frames.first else { return nil }
            return planeTexture(name.lowercased() + (effect.isNone ? "" : "|" + effect.key), renderer) {
                let f = frame.applying(effect)
                return renderer.texture(rgba: f.premultipliedRGBA(), width: f.width, height: f.height, premultiplied: true)
            }
        }
        return items.compactMap { item in
            switch item {
            case .character(let bank): return .character(bank: bank)
            case .quad(let q):
                let picture: MTLTexture?
                switch q.source {
                case .color(let color):
                    picture = planeTexture(String(format: "$%08X", color), renderer) { renderer.texture(color: color) }
                case .picture(let name, let effect):
                    picture = texture(name, effect)
                }
                guard let picture else { return nil }
                var drawing = CatSystemStageRenderer.PlaneDrawing(texture: picture, x: q.x, y: q.y, width: q.width, height: q.height,
                                                                  alpha: q.alpha, flipX: q.flipX, flipY: q.flipY, additive: q.additive)
                if let m = q.mask {
                    // A mask that isn't there hides the plane rather than showing all of it.
                    guard let mask = texture(m.name) else { return nil }
                    drawing.mask = (mask, m.x, m.y, m.width, m.height, m.flipX, m.flipY)
                }
                return .plane(drawing)
            }
        }
    }

    private func planeTexture(_ key: String, _ renderer: CatSystemStageRenderer, make: () -> MTLTexture?) -> MTLTexture? {
        if let hit = planeTextures[key] { return hit }
        guard let texture = make() else { return nil }
        planeTextures[key] = texture
        planeTextureOrder.append(key)
        if planeTextureOrder.count > 32 { planeTextures.removeValue(forKey: planeTextureOrder.removeFirst()) }
        return texture
    }

    /// The emotion marks at `time`, each its picture centred on its place, scaled and faded.
    private func markDrawings(_ renderer: CatSystemStageRenderer, at time: Double) -> [CatSystemStageRenderer.PlaneDrawing] {
        guard !particles.isEmpty else { return [] }
        let sprites = particles.sprites(at: time) { [weak self] bank in self?.emoteStage?.place(bank: bank, at: time) }
        return sprites.compactMap { sprite in
            guard let frame = image(sprite.texture)?.frames.first,
                  let texture = planeTexture(sprite.texture.lowercased(), renderer, make: {
                      renderer.texture(rgba: frame.premultipliedRGBA(), width: frame.width, height: frame.height, premultiplied: true)
                  }) else { return nil }
            let w = Double(frame.width) * sprite.scale, h = Double(frame.height) * sprite.scale
            return .init(texture: texture, x: sprite.x - w / 2, y: sprite.y - h / 2, width: w, height: h, alpha: sprite.alpha)
        }
    }

    /// A rule picture (`wipe04a`) as a texture of its grey levels.
    private func ruleTexture(_ name: String, _ renderer: CatSystemStageRenderer) -> MTLTexture? {
        let key = name.lowercased()
        if let hit = ruleTextures[key] { return hit }
        guard let frame = image(key)?.frames.first,
              let texture = renderer.ruleTexture(grey: frame.redPlane(), width: frame.width, height: frame.height) else {
            NSLog("CatSystem: no rule picture %@; crossfading", name)
            return nil
        }
        ruleTextures[key] = texture
        return texture
    }

    private func show(_ message: ScenePlayer.Message) {
        guard let game, let story else { return }
        present()
        lineSnapshot = story.snapshot()
        lineScene = message.scene
        lineIndex = message.index
        readBefore = readLines.contains(scene: message.scene, index: message.index)
        readLines.insert(scene: message.scene, index: message.index)
        let nameID = message.originalSpeaker.flatMap { speakerTable[$0] }
        hurrying = false
        atInput = !message.continues
        var shown = CatSystemLine(speaker: message.speaker, text: message.text, voice: message.voice, nameID: nameID)
        shown.save = lineSnapshot.map { CatSystemSave(date: Date(), snapshot: $0, speaker: shown.speaker, text: shown.text,
                                                      voice: shown.voice, messageIndex: lineIndex, scene: lineScene, nameID: nameID) }
        display(shown)
        if let voice = message.voice, !skipping { audio.playVoice(voice, game: game) }
    }

    /// The click wait of a line that went on after showing (`\@`).
    private func reachedInput() {
        atInput = true
        if hurrying {
            hurrying = false
            leaveLine()
        } else {
            updateKeyWait()
        }
    }

    private func display(_ shown: CatSystemLine) {
        line = shown
        backlog.append(shown)
        if backlog.count > Self.backlogLimit { backlog.removeFirst(backlog.count - Self.backlogLimit) }
        revealed = skipping ? Double((shown.text as NSString).length) : 0
        lineVoiced = shown.voice != nil
        keyWait.stopAnimating()
        keyWait.isHidden = true
        setName(shown)
        setText(revealing: Int(revealed))
        if window.alpha < 1, !windowHiddenByPlayer { setWindow(visible: true, frames: skipping ? 0 : 10) }
        windowWanted = true
        refreshButtons()
    }

    /// The speaker: the game's name picture (`sys_meswnd_name_<language>`, by
    /// `nametable.csv`) where it has one, else the name set in the game's font.
    private func setName(_ shown: CatSystemLine) {
        let language = storyLanguage
        if let id = shown.nameID, let frame = namePicture(language)?.frame(id: id), let cg = Self.layerImage(frame) {
            nameImage.image = UIImage(cgImage: cg)
            // `pl_name` sits at sys_meswnd frame 100 (264, 69); each name by its offset.
            nameImage.frame = CGRect(x: 264 + frame.offsetX, y: 69 + frame.offsetY, width: frame.width, height: frame.height)
            nameImage.isHidden = false
            nameLabel.attributedText = nil
            return
        }
        nameImage.isHidden = true
        nameLabel.attributedText = shown.speaker.map { name in
            NSAttributedString(string: name, attributes: [
                .font: nameFont,
                .foregroundColor: UIColor(red: 1, green: 0.84, blue: 0.25, alpha: 1),
                .strokeColor: UIColor(red: 0.42, green: 0.2, blue: 0.05, alpha: 1),
                .strokeWidth: -5,
            ])
        }
    }

    private func namePicture(_ language: String) -> HGImage? {
        if let hit = namePictures[language] { return hit }
        guard let game, let bytes = (try? game.file(named: "sys_meswnd_name_\(language).hg3")) ?? nil, let image = try? HGImage(bytes) else { return nil }
        namePictures[language] = image
        return image
    }

    private func setText(revealing count: Int) {
        guard let line else { return }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(red: 0, green: 0.13, blue: 0.26, alpha: 0.95)
        shadow.shadowOffset = CGSize(width: 0, height: 1.5)
        shadow.shadowBlurRadius = 3
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        var font = textFont
        if storyLanguage == "cn", let name = fontNames["notosanscjksc-bold"], let cn = UIFont(name: name, size: 25) { font = cn }
        let text = NSMutableAttributedString(string: line.text, attributes: [
            .font: font, .foregroundColor: UIColor.white, .shadow: shadow, .paragraphStyle: paragraph,
        ])
        let length = (line.text as NSString).length
        if count < length {
            text.addAttributes([.foregroundColor: UIColor.clear, .shadow: NSShadow()],
                               range: NSRange(location: count, length: length - count))
        }
        textLabel.attributedText = text
        // Top-aligned: size to the text, keep the box's width.
        let fitted = textLabel.sizeThatFits(CGSize(width: 802, height: 400))
        textLabel.frame = CGRect(x: 245, y: 112, width: 802, height: min(140, fitted.height))
    }

    private func revealLine() {
        guard let line else { return }
        let length = (line.text as NSString).length
        guard revealed < Double(length) else { return }
        revealed = min(Double(length), settings.lettersPerSecond.map { revealed + $0 / 60 } ?? Double(length))
        setText(revealing: Int(revealed))
        if revealed >= Double(length) { updateKeyWait() }
    }

    /// Auto: once the line is shown and its voice has ended, waits as the CONFIG's auto
    /// speed says (`startup.xml`'s `autopriset`), then reads on.
    private func autoAdvance(_ line: CatSystemLine) {
        guard autoMode, screen == nil, atInput else { lineDoneAt = nil; return }
        let length = (line.text as NSString).length
        guard revealed >= Double(length), !audio.isVoicePlaying else { lineDoneAt = nil; return }
        let now = CACurrentMediaTime()
        guard let done = lineDoneAt else { lineDoneAt = now; return }
        if now - done >= settings.autoWait(letters: length, voiced: lineVoiced) {
            lineDoneAt = nil
            readOn()
        }
    }

    /// The key-wait paw: shown once the line is out and the story waits for a click.
    private func updateKeyWait() {
        let waiting = line.map { atInput && revealed >= Double(($0.text as NSString).length) } ?? false
        guard waiting != !keyWait.isHidden else { return }
        keyWait.isHidden = !waiting
        if waiting { keyWait.startAnimating() } else { keyWait.stopAnimating() }
    }

    private func setWindow(visible: Bool, frames: Int) {
        let shown = visible && !windowHiddenByPlayer && screen == nil
        let duration = Double(frames) / 60
        UIView.animate(withDuration: duration) { self.window.alpha = shown ? 1 : 0 }
    }

    // MARK: The window's buttons

    /// One of the window's buttons (`meswnd.fes`'s `btn[i]`) with its three looks.
    @MainActor private final class WindowButton {
        let index: Int
        let view = UIImageView()
        let images: [UIImage]
        var enabled = true
        var visible = true
        var on = false
        var hovered = false
        var pressed = false

        init(index: Int, images: [UIImage], frame: CGRect) {
            self.index = index
            self.images = images
            view.frame = frame
            update()
        }

        /// 0 as drawn; 1 under the pointer, or dimmed while disabled (`_SETBUTTON`); 2
        /// pressed, or on (Auto and Skip while they run).
        func update() {
            view.isHidden = !visible
            let look = pressed || on ? 2 : (hovered && enabled) || !enabled ? 1 : 0
            view.image = images.indices.contains(look) ? images[look] : images.first
        }
    }

    private enum WindowAction: Int {
        case skip = 0, auto, log, config, save, load, quickSave, quickLoad, hide, voice
    }

    /// The buttons' states as `MES_SETSTATE` and `_SETBUTTON` set them: Auto and Skip lit
    /// while on, Quick Load only with a quick save, the voice button only for a voiced line.
    private func refreshButtons() {
        for b in windowButtons {
            switch WindowAction(rawValue: b.index) {
            case .skip: b.on = skipMode
            case .auto: b.on = autoMode
            case .quickLoad: b.enabled = slots.files()[CatSystemSlots.quickSlot] != nil
            case .voice: b.visible = line?.voice != nil
            case .save, .quickSave: b.enabled = lineSnapshot != nil
            default: break
            }
            b.update()
        }
    }

    /// The window button at a point on the stage, if the window is up.
    private func windowButton(at point: CGPoint) -> WindowButton? {
        guard story != nil, screen == nil, window.alpha > 0.5, !windowHiddenByPlayer else { return nil }
        let p = CGPoint(x: point.x, y: point.y - window.frame.minY)
        return windowButtons.first { $0.visible && $0.view.frame.contains(p) }
    }

    private func press(_ button: WindowButton) {
        guard button.enabled, let action = WindowAction(rawValue: button.index) else { return }
        button.pressed = true
        button.update()
        playSystemSound(101)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            button.pressed = false
            button.update()
            self?.windowAction(action)
        }
    }

    private func windowAction(_ action: WindowAction) {
        guard story != nil, screen == nil, movie == nil else { return }
        switch action {
        case .skip:
            skipMode.toggle()
            if skipMode { autoMode = false }
        case .auto:
            autoMode.toggle()
            if autoMode { skipMode = false }
            lineDoneAt = nil
        case .log: openBacklog()
        case .config: openScreen(.config)
        case .save: openScreen(.saveLoad, save: true)
        case .load: openScreen(.saveLoad, save: false)
        // `meswnd.fes` sends these straight to the engine (`_SYS_QSAVE`, `_SYS_QLOAD`): no
        // question first (its `CONF_QSAVE` dialog would ask with another screen's words).
        case .quickSave: quickSave()
        case .quickLoad: quickLoad()
        case .hide: hideWindow()
        case .voice:
            if let voice = line?.voice, let game { audio.playVoice(voice, game: game) }
        }
        refreshButtons()
    }

    /// The pointer over the window's buttons: the one under it lights up, with its help
    /// balloon (`DISPHELP`, while the CONFIG's help is on: `$961`).
    private func hoverWindow(at point: CGPoint?) {
        highlightWindowButton(point.flatMap(windowButton(at:)))
    }

    /// Lights one of the window's buttons (the pointer's or the keys'), or none.
    private func highlightWindowButton(_ button: WindowButton?) {
        guard button?.index != hoveredButton else { return }
        if let old = hoveredButton, windowButtons.indices.contains(old) {
            windowButtons[old].hovered = false
            windowButtons[old].update()
        }
        hoveredButton = button?.index
        if let button {
            button.hovered = true
            button.update()
            if button.enabled { playSystemSound(105) }
        }
        // The quick load button shows the quick save it would load (`DISP_QLOAD`).
        if button?.index == WindowAction.quickLoad.rawValue, button?.enabled == true, let file = slots.files()[CatSystemSlots.quickSlot],
           let save = CatSystemSave.read(saves.appendingPathComponent(file)) {
            quickPanel.show(save, thumbnail: slots.thumbnail(for: file), loading: true)
        } else {
            quickPanel.hide()
        }
        if let button, button.enabled, (settings.globals[961] ?? 1) != 0, let help = windowHelp[button.index] {
            helpBalloon.image = help.image
            helpBalloon.frame = help.frame.offsetBy(dx: 0, dy: 10)
            UIView.animate(withDuration: 10.0 / 60) {
                self.helpBalloon.alpha = 1
                self.helpBalloon.frame = help.frame
            }
        } else {
            UIView.animate(withDuration: 10.0 / 60) { self.helpBalloon.alpha = 0 }
        }
    }

    /// The window's system sounds (`$814` 100+: `se_sys_01` a press, `se_sys_05` the pointer
    /// arriving), while the CONFIG's system sounds are on (`$962`).
    private func playSystemSound(_ code: Int) {
        guard let game, (settings.globals[962] ?? 1) != 0 else { return }
        audio.playEffect(String(format: "se_sys_%02d", code - 100), channel: "sys-window", game: game)
    }

    private func hideWindow() {
        windowHiddenByPlayer = true
        hoverWindow(at: nil)
        setWindow(visible: false, frames: 8)
    }

    private func showWindowAgain() {
        windowHiddenByPlayer = false
        setWindow(visible: windowWanted, frames: 8)
    }

    // MARK: Input

    func gestureRecognizer(_ recognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        lastTouchWasPointer = touch.isPointer
        if touch.isPointer { pointerHovering = true } else { pointerHovering = false }
        return true
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, pan.allowedScrollTypesMask.isEmpty else { return true }
        // A drag moves a slider on the game's screens, and nothing else.
        let p = recognizer.location(in: stage)
        return (screen ?? fes)?.isSlider(atX: Int(p.x), y: Int(p.y)) ?? false
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
        guard let player = screen ?? fes else { return }
        let p = recognizer.location(in: stage)
        switch recognizer.state {
        case .began: _ = player.beginDrag(atX: Int(p.x), y: Int(p.y))
        case .changed: player.hover(atX: Int(p.x), y: Int(p.y))
        default:
            player.endDrag()
            if !lastTouchWasPointer { player.hover(atX: nil, y: nil) }
        }
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard presentedViewController == nil else { return }
        let point = recognizer.location(in: stage)
        primaryAction(at: point, pointer: lastTouchWasPointer)
    }

    /// A tap, a click, Enter or Space.
    private func primaryAction(at point: CGPoint?, pointer: Bool, pressLit: Bool = true) {
        if movie != nil {
            // A tap skips the movie.
            endMovie()
            return
        }
        if let player = screen ?? fes {
            if let point {
                let pressed = player.click(atX: Int(point.x), y: Int(point.y), pointer: pointer)
                #if DEBUG
                NSLog("CatSystem: click at %.0f,%.0f: %@ (%@)", point.x, point.y, pressed ?? "nothing", player.stack.joined(separator: " > "))
                #endif
            } else {
                player.pressFocused()
            }
            return
        }
        guard story != nil else { return }
        if windowHiddenByPlayer {
            showWindowAgain()
            return
        }
        if let point, let button = windowButton(at: point) {
            press(button)
            return
        }
        // Enter (or A) with a window button lit (by the keys, the pad or the pointer) presses it.
        if point == nil, pressLit, let i = hoveredButton, windowButtons.indices.contains(i),
           windowButtons[i].visible, windowButtons[i].enabled, window.alpha > 0.5 {
            press(windowButtons[i])
            return
        }
        if point != nil { highlightWindowButton(nil) }
        if skipMode {
            skipMode = false
            refreshButtons()
            return
        }
        if autoMode, settings.value("autoleft") == 0 {
            autoMode = false
            refreshButtons()
        }
        if let line {
            let length = (line.text as NSString).length
            if revealed < Double(length) {
                revealed = Double(length)
                setText(revealing: length)
                updateKeyWait()
                return
            }
            readOn()
        } else if CACurrentMediaTime() < waitUntil {
            // A tap cuts a wait or a crossfade short.
            waitUntil = 0
            picture.removeAllAnimations()
            stageRenderer?.endCrossfade()
            planeStage.finishMotions()
            pump()
        }
    }

    /// A right click, a two-finger tap or Escape: in the story the window hides (as the PC
    /// game's right click does) or comes back; on a screen, the screen's own way back.
    @objc private func secondaryAction() {
        guard presentedViewController == nil, movie == nil else { return }
        if let player = screen ?? fes {
            player.rightClick()
            return
        }
        guard story != nil else { return }
        if skipMode || autoMode {
            skipMode = false
            autoMode = false
            refreshButtons()
            return
        }
        if windowHiddenByPlayer { showWindowAgain() } else if window.alpha > 0.5 { hideWindow() }
    }

    /// Leaves the line on screen for the story's next: the voice stops, unless the CONFIG
    /// says voices carry on after a click (`contvoice`).
    private func readOn() {
        guard atInput else {
            // The line's own motions are still playing: they finish now, and the story reads
            // on at its click wait.
            hurrying = true
            waitUntil = 0
            stageRenderer?.endCrossfade()
            planeStage.finishMotions()
            emoteStage?.finishMotions()
            pump()
            return
        }
        leaveLine()
        pump()
    }

    /// The line on screen is done with: its voice stops (unless CONFIG's `contvoice`).
    private func leaveLine() {
        if settings.value("contvoice") == 0 || skipping { audio.stopVoice() }
        line = nil
        atInput = false
        lineDoneAt = nil
        keyWait.stopAnimating()
        keyWait.isHidden = true
    }

    /// A swipe right: Skip on or off, in the story.
    @objc private func swipedSkip() {
        guard presentedViewController == nil, story != nil, screen == nil, movie == nil else { return }
        windowAction(.skip)
        refreshButtons()
        NSLog("CatSystem: skip %@ (gesture)", skipMode ? "on" : "off")
    }

    /// A two-finger swipe up (or X on the pad): Auto on or off, in the story.
    @objc private func swipedAuto() {
        guard presentedViewController == nil, story != nil, screen == nil, movie == nil else { return }
        windowAction(.auto)
        refreshButtons()
        NSLog("CatSystem: auto %@ (gesture)", autoMode ? "on" : "off")
    }

    /// A finger held on the message window: Auto on or off, as in the other engines.
    @objc private func heldOnWindow(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, !windowHiddenByPlayer, window.alpha > 0.5,
              window.frame.contains(recognizer.location(in: window.superview)) else { return }
        swipedAuto()
    }

    @objc private func openBacklog() {
        guard presentedViewController == nil, story != nil, screen == nil, movie == nil, !backlog.isEmpty else { return }
        openScreen(.backlog)
    }

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        confirmLeave()
    }

    private func confirmLeave() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Leave the game?", message: currentSave() != nil ? "Your place is saved to the Load screen." : "Progress since your last save is lost.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        leaveAlert = alert
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        savePlace(reason: "leaving the game")
        leaving = true
        stopMovie()
        readLines.save(to: saves)
        settings.save(to: saves)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        ControllerInput.gameReceiver = nil
        OrientationLock.set(.all, in: view.window?.windowScene)
        onExit()
    }

    // MARK: Pointer, wheel and keys

    /// A trackpad or mouse over the game: the game's buttons light up under it (the title's,
    /// the screens', the window's) and its cursor follows.
    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            pointerMoved(to: recognizer.location(in: stage))
        default:
            pointerLocation = nil
            (screen ?? fes)?.hover(atX: nil, y: nil)
            hoverWindow(at: nil)
            cursorLayer.isHidden = true
        }
    }

    /// The pointer at a point on the stage: what is under it lights up, the cursor follows.
    private func pointerMoved(to p: CGPoint) {
        pointerHovering = true
        pointerLocation = stage.convert(p, to: view)
        if let player = screen ?? fes {
            player.hover(atX: Int(p.x), y: Int(p.y))
            hoverWindow(at: nil)
        } else {
            hoverWindow(at: p)
        }
        layoutCursor()
    }

    #if DEBUG
    /// `-ShioriCatSystemPointer 1180,600`: a pointer resting there (game pixels), to check
    /// rollovers and the game's cursor in the simulator, which has no hover of its own.
    private lazy var debugPointer: CGPoint? = UserDefaults.standard.string(forKey: "ShioriCatSystemPointer").flatMap { text in
        let v = text.split(separator: ",").compactMap { Double($0) }
        return v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil
    }
    #endif

    private var scrollTravel: CGFloat = 0

    /// The wheel: on a screen, the screen's own (pages, the backlog); in the story, up opens
    /// the backlog and down reads on, as on the PC.
    @objc private func scrolled(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { scrollTravel = 0 }
        guard recognizer.state == .changed else { return }
        let travel = recognizer.translation(in: view).y - scrollTravel
        guard abs(travel) >= 30 else { return }
        scrollTravel += travel > 0 ? 30 : -30
        wheel(up: travel > 0)
    }

    private func wheel(up: Bool) {
        if let player = screen ?? fes {
            player.scroll(up: up)
        } else if story != nil, movie == nil {
            if up { openBacklog() } else if line != nil { primaryAction(at: nil, pointer: true, pressLit: false) }
        }
    }

    /// The game's cursor at the pointer: `cursor.cur`, or `cur_over.cur` over something to
    /// press (`xchgcursor btndown`), at the game's scale; the iPad's own pointer hides.
    private func updateCursor() {
        guard pointerHovering, pointerLocation != nil else { return }
        layoutCursor()
    }

    private func layoutCursor() {
        let over = (screen ?? fes)?.cursorOverButton ?? (hoveredButton.map { windowButtons[$0].enabled } ?? false)
        guard let location = pointerLocation, pointerHovering, let cursor = (over ? cursors.over : nil) ?? cursors.normal else {
            cursorLayer.isHidden = true
            return
        }
        let scale = stage.transform.a
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if (cursorLayer.contents as AnyObject?) !== cursor.image { cursorLayer.contents = cursor.image }
        cursorLayer.frame = CGRect(x: location.x - cursor.hotspot.x * scale, y: location.y - cursor.hotspot.y * scale,
                                   width: cursor.size.width * scale, height: cursor.size.height * scale)
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        cursors.normal == nil ? nil : .hidden()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { Self.handledKeys.contains($0) }
        for key in keys { keyDown(key) }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let (keys, rest) = presses.splitKeys { Self.handledKeys.contains($0) }
        for key in keys where key == .keyboardLeftControl || key == .keyboardRightControl { controlHeld = false }
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        controlHeld = false
        super.pressesCancelled(presses, with: event)
    }

    private static let handledKeys: Set<UIKeyboardHIDUsage> = [
        .keyboardEscape, .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar, .keyboardUpArrow, .keyboardDownArrow,
        .keyboardLeftArrow, .keyboardRightArrow, .keyboardLeftControl, .keyboardRightControl, .keyboardDeleteOrBackspace,
        .keyboardPageUp, .keyboardPageDown,
    ]

    /// Escape (or Backspace) as a right click; Enter and Space read on (or press the button
    /// lit); the arrows move between buttons (see `arrow`); Ctrl held skips.
    private func keyDown(_ key: UIKeyboardHIDUsage) {
        guard presentedViewController == nil else { return }
        switch key {
        case .keyboardEscape, .keyboardDeleteOrBackspace: secondaryAction()
        case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar: primaryAction(at: nil, pointer: true)
        case .keyboardUpArrow: arrow(.up)
        case .keyboardDownArrow: arrow(.down)
        case .keyboardLeftArrow: arrow(.left)
        case .keyboardRightArrow: arrow(.right)
        case .keyboardLeftControl, .keyboardRightControl: controlHeld = story != nil && screen == nil
        case .keyboardPageUp: if screen != nil || fes != nil { wheel(up: true) } else { openBacklog() }
        case .keyboardPageDown: if screen != nil || fes != nil { wheel(up: false) }
        default: break
        }
    }

    /// An arrow key or the d-pad. On the game's screens the highlight moves between their
    /// buttons (`FESPlayer.moveFocus`: the `#KEYBLOCK` buttons where a screen names them, a
    /// slider's knob left and right), and up or down past the last one turns the wheel (the
    /// save screen's pages, the backlog's lines). In the story, left and right move along
    /// the window's buttons, up opens the backlog and down reads on, as the wheel does.
    private func arrow(_ direction: FESPlayer.Direction) {
        guard movie == nil else { return }
        if let player = screen ?? fes {
            let moved = player.moveFocus(direction)
            #if DEBUG
            NSLog("CatSystem: arrow %@ on %@: %@", "\(direction)", player.stack.joined(separator: " > "), moved ? "moved" : "nothing that way")
            #endif
            if !moved, direction == .up || direction == .down {
                player.scroll(up: direction == .up)
            }
            return
        }
        guard story != nil else { return }
        switch direction {
        case .left, .right:
            guard !windowHiddenByPlayer, window.alpha > 0.5 else { return }
            // In reading order: the top row, then the bottom one.
            let row = windowButtons.filter { $0.visible && $0.enabled }
                .sorted { (Int($0.view.frame.minY / 20), $0.view.frame.minX) < (Int($1.view.frame.minY / 20), $1.view.frame.minX) }
            guard !row.isEmpty else { return }
            let at = row.firstIndex { $0.index == hoveredButton }
            let next = at.map { min(row.count - 1, max(0, $0 + (direction == .right ? 1 : -1))) } ?? (direction == .right ? 0 : row.count - 1)
            highlightWindowButton(row[next])
        case .up:
            highlightWindowButton(nil)
            wheel(up: true)
        case .down:
            highlightWindowButton(nil)
            wheel(up: false)
        }
    }

    // MARK: Controller

    private enum PadKey: Hashable { case up, down, left, right, a, b, x, y, lb, rb, menu }

    private var padHeld: Set<PadKey> = []
    private var padRepeatAt: [PadKey: CFTimeInterval] = [:]
    private var padOptionsDown = false
    private var leaveAlert: UIAlertController?

    /// The controller, read every frame: the d-pad (or left stick) as the arrow keys, held
    /// directions repeating; A as Enter; B as the right click; Y and LB the backlog (on a
    /// screen, the wheel up); RB or RT held skips in the story (on a screen, the wheel down);
    /// Menu opens CONFIG in the story (on a screen, backs out); Options asks to leave, and on
    /// that question A leaves and B stays.
    private func pad(_ pad: GCExtendedGamepad) {
        let options = pad.buttonOptions?.isPressed ?? false
        defer { padOptionsDown = options }
        if let alert = leaveAlert, presentedViewController === alert {
            if pad.buttonA.isPressed, !padHeld.contains(.a) {
                alert.dismiss(animated: true) { [weak self] in self?.leave() }
            } else if pad.buttonB.isPressed, !padHeld.contains(.b) {
                alert.dismiss(animated: true)
            }
            padHeld = pad.buttonA.isPressed ? [.a] : pad.buttonB.isPressed ? [.b] : []
            return
        }
        guard presentedViewController == nil, !leaving else { return }
        if options, !padOptionsDown {
            padHeld.removeAll()
            controlHeld = false
            confirmLeave()
            return
        }
        let stick = pad.leftThumbstick
        let threshold: Float = 0.55
        let pressed: [PadKey: Bool] = [
            .up: pad.dpad.up.isPressed || stick.yAxis.value > threshold,
            .down: pad.dpad.down.isPressed || stick.yAxis.value < -threshold,
            .left: pad.dpad.left.isPressed || stick.xAxis.value < -threshold,
            .right: pad.dpad.right.isPressed || stick.xAxis.value > threshold,
            .a: pad.buttonA.isPressed,
            .b: pad.buttonB.isPressed,
            .x: pad.buttonX.isPressed,
            .y: pad.buttonY.isPressed,
            .lb: pad.leftShoulder.isPressed,
            .rb: pad.rightShoulder.isPressed || pad.rightTrigger.isPressed,
            .menu: pad.buttonMenu.isPressed,
        ]
        let now = CACurrentMediaTime()
        for (key, isDown) in pressed {
            let wasDown = padHeld.contains(key)
            if isDown, !wasDown {
                padHeld.insert(key)
                padRepeatAt[key] = now + 0.35
                padPress(key, down: true)
            } else if isDown, [.up, .down, .left, .right].contains(key), let at = padRepeatAt[key], now >= at {
                padRepeatAt[key] = now + 0.11
                padPress(key, down: true)
            } else if !isDown, wasDown {
                padHeld.remove(key)
                padRepeatAt[key] = nil
                padPress(key, down: false)
            }
        }
    }

    private func padPress(_ key: PadKey, down: Bool) {
        if key == .rb, !down { controlHeld = false; return }
        guard down else { return }
        // The pad, like the keys, hides the iPad's pointer highlight.
        pointerHovering = false
        let onScreen = screen != nil || fes != nil
        switch key {
        case .up: arrow(.up)
        case .down: arrow(.down)
        case .left: arrow(.left)
        case .right: arrow(.right)
        case .a: primaryAction(at: nil, pointer: true)
        case .b: secondaryAction()
        case .x: swipedAuto()
        case .y, .lb: if onScreen { wheel(up: true) } else { openBacklog() }
        case .rb: if onScreen { wheel(up: false) } else { controlHeld = story != nil }
        case .menu:
            if onScreen { secondaryAction() } else if story != nil, movie == nil { windowAction(.config) }
        }
    }

    #if DEBUG
    /// `-ShioriCatSystemInput "4:down;4.5:return;9:pad-a"`: keys (`up`, `down`, `left`,
    /// `right`, `return`, `escape`) and pad buttons (`pad-a`, `pad-b`, `pad-y`, `pad-menu`,
    /// `pad-down` …), `skip`, `auto`, `leave` and `load-screen` at seconds from launch, to
    /// check them in the simulator.
    private func scheduleDebugInput() {
        let script = UserDefaults.standard.string(forKey: "ShioriCatSystemInput") ?? ""
        let keys: [String: UIKeyboardHIDUsage] = [
            "up": .keyboardUpArrow, "down": .keyboardDownArrow, "left": .keyboardLeftArrow, "right": .keyboardRightArrow,
            "return": .keyboardReturnOrEnter, "escape": .keyboardEscape,
        ]
        let pads: [String: PadKey] = [
            "pad-up": .up, "pad-down": .down, "pad-left": .left, "pad-right": .right, "pad-a": .a, "pad-b": .b,
            "pad-x": .x, "pad-y": .y, "pad-lb": .lb, "pad-rb": .rb, "pad-menu": .menu,
        ]
        for step in script.split(separator: ";") {
            let parts = step.split(separator: ":")
            guard parts.count == 2, let delay = Double(parts[0]) else { continue }
            let name = String(parts[1])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                NSLog("CatSystem: debug input %@", name)
                if name == "leave" {
                    // The leave question's Leave.
                    self.leave()
                } else if name == "load-screen" {
                    self.openScreen(.saveLoad, save: false)
                } else if name == "skip" || name == "auto" {
                    if name == "skip" { self.swipedSkip() } else { self.swipedAuto() }
                } else if let key = keys[name] {
                    self.keyDown(key)
                } else if let key = pads[name] {
                    self.padPress(key, down: true)
                    if key == .rb { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.padPress(.rb, down: false) } }
                }
            }
        }
    }
    #endif

    // MARK: The game's screens over the story

    /// Opens one of the game's screens over the story: the save and load screen
    /// (`saveload.fes`, `$800` 0 save / 1 load, `$801` 1 from the story), CONFIG
    /// (`config.fes`) or the backlog (`hist_b.fes`). The story waits underneath.
    private func openScreen(_ kind: Screen, save: Bool = false) {
        guard let game, screen == nil else { return }
        let player = Self.makePlayer(game: game, fonts: fontNames, settings: settings)
        player.transparent = true
        let host = CatSystemScreens(controller: self)
        screenHost = host
        player.host = host
        let script: String
        switch kind {
        case .saveLoad:
            if save { pendingThumbnail = takeThumbnail() }
            player.setVariable(800, save ? 0 : 1)
            player.setVariable(801, 1)
            script = "saveload"
        case .config:
            player.setVariable(801, 1)
            script = "config"
        case .backlog:
            // Its jump-back buttons take the story back to a line (`exit -2`, the line in
            // `$518`): each line read keeps its place.
            script = "hist_b"
        }
        do { try player.start(script) } catch {
            NSLog("CatSystem: %@ doesn't open: %@", script, String(describing: error))
            return
        }
        screen = player
        screenKind = kind
        screenDrawn = nil
        autoMode = false
        skipMode = false
        controlHeld = false
        hoverWindow(at: nil)
        UIView.animate(withDuration: 0.15) { self.window.alpha = 0 }
        screenLayer.contents = nil
        screenLayer.isHidden = false
        refreshButtons()
    }

    private func screenFrame(_ player: FESPlayer) {
        player.step()
        playSounds(player)
        keepGlobals(player)
        if player.returnedToTitle {
            NSLog("CatSystem: back to the title from %@", player.stack.first ?? "a screen")
            autosave()
            startTitle(skipLogo: true)
            return
        }
        draw(player, into: screenLayer, drawn: &screenDrawn, opaque: false)
        guard let code = player.rootExitCode else { return }
        let kind = screenKind
        let jumpTo = player.variables[518]
        closeScreen()
        switch kind {
        case .saveLoad:
            if code >= 0, let save = save(forSlot: code) {
                load(save)
            } else if code == -3 {
                leave()
            }
        case .backlog:
            if code == -2, let index = jumpTo { jumpBack(to: index) }
        case .config: break
        }
    }

    /// The backlog's jump back: the story as it was when line `index` showed, the lines
    /// after it gone from the backlog.
    private func jumpBack(to index: Int) {
        guard backlog.indices.contains(index), let save = backlog[index].save else {
            NSLog("CatSystem: no place kept for backlog line %d", index)
            return
        }
        NSLog("CatSystem: back to backlog line %d of %d (scene %@)", index, backlog.count, save.scene)
        load(save, keeping: Array(backlog[..<index]))
    }

    private func closeScreen() {
        guard screen != nil else { return }
        screen = nil
        screenLayer.isHidden = true
        screenLayer.contents = nil
        pendingThumbnail = nil
        settings.save(to: saves)
        applySettings()
        if story != nil { setWindow(visible: windowWanted, frames: 8) }
        refreshButtons()
    }

    /// The story's screen at twice a save's thumbnail size (186×105), smoothly scaled.
    private func takeThumbnail() -> CGImage? {
        guard let big = stageRenderer?.snapshot(width: 744, height: 420) else { return nil }
        let w = 372, h = 210
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(big, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: What the screens ask (CatSystemScreens)

    func config(_ name: String) -> Int? {
        switch name {
        case "messpd": return settings.messageSpeed
        case "autospd": return settings.autoLevel
        case "autospd_b": return CatSystemSettings.autoPresets[settings.autoLevel].base
        case "autospd_c": return CatSystemSettings.autoPresets[settings.autoLevel].char
        case "wndcolor": return settings.windowOpacity << 24
        case "screen": return 1
        default: return settings.value(name)
        }
    }

    func setConfig(_ name: String, _ value: Int) {
        switch name {
        case "messpd": settings.messageSpeed = value
        case "autospd": settings.autoLevel = value
        case "wndcolor": settings.windowOpacity = (value >> 24) & 0xFF
        case "screen": break
        case "lang_ui":
            settings.game[name] = value
            let language = ["en", "jp", "cn"][max(0, min(2, value))]
            fes?.language = language
            screen?.language = language
        case "lang_text_main":
            settings.game[name] = value
            story?.language = storyLanguage
        default: settings.game[name] = value
        }
        applySettings()
    }

    func soundConfig(_ args: [String]) -> Int? {
        guard let kind = args.first else { return nil }
        let percent = { (v: Double) in Int((v * 100).rounded()) }
        if kind == "volume_id", args.count >= 3, let n = Int(args[2]) {
            return percent(settings.characterVoices[min(7, max(0, n))])
        }
        guard kind == "volume", args.count >= 2 else { return nil }
        switch args[1] {
        case "master": return percent(settings.master)
        case "bgm", "movie": return percent(settings.music)
        case "se": return percent(settings.effects)
        case "voice", "bgsong": return percent(settings.voice)
        case "sysse": return percent(settings.system)
        case "bgvoice": return transientVolumes["bgvoice"] ?? 80
        default: return nil
        }
    }

    /// Volumes the scripts set for a moment (the save screen quiets background voices).
    private var transientVolumes: [String: Int] = [:]

    func setSoundConfig(_ args: [String], _ value: Int) {
        guard let kind = args.first else { return }
        let v = Double(max(0, min(100, value))) / 100
        switch kind {
        case "volume_id" where args.count >= 3:
            // Group 2 is the voices; group 4 (background voices) follows it.
            if args[1] == "2", let n = Int(args[2]) { settings.characterVoices[min(7, max(0, n))] = v }
        case "volume" where args.count >= 2:
            switch args[1] {
            case "master": settings.master = v
            case "bgm": settings.music = v
            case "se": settings.effects = v
            case "voice": settings.voice = v
            case "sysse": settings.system = v
            default: transientVolumes[args[1]] = value
            }
        case "reset" where args.count >= 2:
            // Reset Settings: `soundconf.xml`'s volumes.
            switch args[1] {
            case "master": settings.master = 1
            case "bgm": settings.music = 0.8
            case "se": settings.effects = 0.9
            case "voice": settings.voice = 1
            default: break
            }
        default: break
        }
        applySettings()
    }

    func saveState(_ slot: Int) -> Int { slots.files()[mapSlot(slot)] == nil ? 0 : (slots.save(in: mapSlot(slot)) == nil ? -1 : 1) }

    /// The load screen's extra pages: 400–407 the quick saves (Shiori has one), 480–487 the
    /// autosaves (one).
    private func mapSlot(_ slot: Int) -> Int {
        if (400..<408).contains(slot) { return slot == 400 ? CatSystemSlots.quickSlot : -1 }
        if (480..<488).contains(slot) { return slot == 480 ? CatSystemSlots.autoSlot : -1 }
        return slot
    }

    /// The save a slot number from the scripts names (the extra pages' too).
    private func save(forSlot slot: Int) -> CatSystemSave? {
        let mapped = mapSlot(slot)
        return mapped >= 0 ? slots.save(in: mapped) : nil
    }

    func newestSave(from: Int, count: Int) -> Int {
        let files = slots.files().filter { $0.key >= from && $0.key < from + count && $0.key < 80 }
        var best: (slot: Int, date: Date)?
        for (slot, _) in files {
            guard let save = slots.save(in: slot) else { continue }
            if best.map({ save.date > $0.date }) ?? true { best = (slot, save.date) }
        }
        return best?.slot ?? -1
    }

    func saveInto(_ slot: Int) {
        guard let save = currentSave(), slot >= 0, slot < 80 else { return }
        do {
            try slots.write(save, slot: slot, thumbnail: pendingThumbnail)
            NSLog("CatSystem: saved in slot %d (scene %@)", slot, save.scene)
        } catch {
            NSLog("CatSystem: couldn't save: %@", String(describing: error))
        }
    }

    func deleteSave(_ slot: Int) {
        guard slot >= 0, slot < 80 else { return }
        slots.delete(slot)
        NSLog("CatSystem: deleted slot %d", slot)
    }

    func saveInfo(_ slot: Int) -> FESSaveInfo? {
        let mapped = mapSlot(slot)
        guard let file = slots.files()[mapped], let save = CatSystemSave.read(saves.appendingPathComponent(file)) else { return nil }
        let title = mapped == CatSystemSlots.quickSlot ? "Quick Save" : mapped == CatSystemSlots.autoSlot ? "Autosave" : "Scene \(save.scene)"
        let comment = (save.speaker.map { "\($0): " } ?? "") + save.text
        return FESSaveInfo(title: title, comment: comment, date: save.date, thumbnail: slots.thumbnail(for: file) ?? drawnThumbnail(save))
    }

    /// Saves from before there were thumbnails get one drawn from the save itself (its
    /// planes and characters, on the CPU), once a session.
    private var drawnThumbnails: [String: (rgba: [UInt8], width: Int, height: Int)] = [:]

    private func drawnThumbnail(_ save: CatSystemSave) -> (rgba: [UInt8], width: Int, height: Int)? {
        if let hit = drawnThumbnails[save.file] { return hit }
        guard let game else { return nil }
        let player = ScenePlayer(game: game)
        guard (try? player.restore(save.snapshot)) != nil else { return nil }
        let full = player.render(width: 1280, height: 720, emote: emote) { [weak self] name in self?.image(name) }
        guard let big = Self.cgImage(full, width: 1280, height: 720, opaque: true) else { return nil }
        let w = 372, h = 210
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(big, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
        drawnThumbnails[save.file] = (rgba, w, h)
        return (rgba, w, h)
    }

    func screenReturnsToTitle() {}

    var logEntries: [FESLogEntry] {
        backlog.map { FESLogEntry(name: $0.speaker, nameID: $0.nameID, text: $0.text, hasVoice: $0.voice != nil) }
    }

    func playLogVoice(_ index: Int) {
        guard let game, backlog.indices.contains(index), let voice = backlog[index].voice else { return }
        audio.playVoice(voice, game: game)
    }

    /// CONFIG changes are written at most once a second (sliders send many).
    private var settingsDirty = false
    private var settingsSaved: CFTimeInterval = 0

    private func applySettings() {
        settingsDirty = true
        audio.setVolumes(master: Float(settings.master), music: Float(settings.music), voice: Float(settings.voice),
                         effects: Float(settings.effects), system: Float(settings.system))
        windowBand.alpha = CGFloat(settings.windowOpacity) / 100
        emoteStage?.bustInertia = Double(settings.value("m2_iner_lv_bust")) / 100
        faceStage?.bustInertia = Double(settings.value("m2_iner_lv_bust")) / 100
    }

    // MARK: Saves

    private func currentSave() -> CatSystemSave? {
        guard let line, let lineSnapshot else { return nil }
        return CatSystemSave(date: Date(), snapshot: lineSnapshot, speaker: line.speaker, text: line.text,
                             voice: line.voice, messageIndex: lineIndex, scene: lineScene, nameID: line.nameID)
    }

    private func quickSave() {
        guard let save = currentSave() else { return }
        do {
            try slots.write(save, slot: CatSystemSlots.quickSlot, thumbnail: takeThumbnail())
            NSLog("CatSystem: quick saved (scene %@)", save.scene)
            // `DISP_QSAVE`: the quick save's panel, for a second.
            if let file = slots.files()[CatSystemSlots.quickSlot] {
                quickPanel.show(save, thumbnail: slots.thumbnail(for: file), loading: false)
                quickPanel.hide(after: 1)
            }
        } catch {
            NSLog("CatSystem: couldn't quick save: %@", String(describing: error))
        }
        refreshButtons()
    }

    private func quickLoad() {
        guard let save = slots.save(in: CatSystemSlots.quickSlot) else { return }
        load(save)
    }

    private func autosave() {
        guard let save = currentSave() else { return }
        try? slots.write(save, slot: CatSystemSlots.autoSlot, thumbnail: stageRenderer.flatMap { _ in takeThumbnail() })
    }

    /// On leaving the game or the screen: the place into a normal slot of the game's Load
    /// screen (Shiori's slot from last time while the player hasn't saved over it, else the
    /// first free one), never loaded by itself (spec Saves, Keeping the place).
    private func savePlace(reason: String) {
        guard !leaving, let save = currentSave() else {
            NSLog("CatSystem: no place to keep, %@", reason)
            return
        }
        do {
            if let slot = try slots.savePlace(save, thumbnail: stageRenderer.flatMap { _ in takeThumbnail() }) {
                NSLog("CatSystem: kept the place in slot %d (scene %@, line %d), %@", slot, save.scene, save.messageIndex, reason)
            } else {
                NSLog("CatSystem: the place is already in Shiori's slot, %@", reason)
            }
        } catch {
            NSLog("CatSystem: couldn't keep the place: %@", String(describing: error))
        }
    }

    /// Picks the story up at a save (or a backlog line: `keeping` the lines before it).
    private func load(_ save: CatSystemSave, keeping earlier: [CatSystemLine] = []) {
        guard let game else { return }
        let player = ScenePlayer(game: game)
        player.language = storyLanguage
        player.emote = emote
        do { try player.restore(save.snapshot) } catch {
            fail("Couldn't load", error)
            return
        }
        NSLog("CatSystem: loaded %@ (scene %@, line %d)", save.file, save.scene, save.messageIndex)
        stopMovie()
        closeScreen()
        fes = nil
        startingStory = false
        audio.stopAll()
        story = player
        backlog = earlier
        transitionFrames = nil
        transitionMosaic = nil
        particles.reset()
        waitUntil = 0
        hurrying = false
        // A line that went on after showing (`\@`) goes on from where it was saved; older
        // saves were all made at the click wait.
        atInput = !(save.snapshot.beforeInput ?? false)
        shownPlanes = nil
        shownCast = nil
        autoMode = false
        skipMode = false
        emoteStage?.reset(player.cast, time: CACurrentMediaTime())
        faceStage?.reset(player.faces, time: CACurrentMediaTime())
        planeStage.reset(player.planes)
        transitionRule = nil
        present(force: true)
        musicName = player.bgm
        if let music = player.bgm { audio.playMusic(music, game: game, fadeFrames: 30) }
        lineSnapshot = save.snapshot
        lineScene = save.scene
        lineIndex = save.messageIndex
        readBefore = true
        windowHiddenByPlayer = false
        windowWanted = true
        let nameID = save.nameID
        var shown = CatSystemLine(speaker: save.speaker, text: save.text, voice: save.voice, nameID: nameID)
        shown.save = save
        display(shown)
        setWindow(visible: true, frames: 0)
        if let voice = save.voice { audio.playVoice(voice, game: game) }
        applySettings()
    }

    // MARK: Pictures

    /// A picture by name (`bg01a_19`), decoded once and kept while in use (the last 24).
    private func image(_ name: String) -> HGImage? {
        let key = name.lowercased()
        if let hit = images[key] { return hit }
        guard let game, let bytes = (try? game.file(named: key + ".hg3")) ?? nil, let image = try? HGImage(bytes) else {
            NSLog("CatSystem: no picture %@", name)
            return nil
        }
        images[key] = image
        imageOrder.append(key)
        if imageOrder.count > 24 { images.removeValue(forKey: imageOrder.removeFirst()) }
        return image
    }

    nonisolated static func cgImage(_ frame: HGImage.Frame) -> CGImage? {
        cgImage(frame.rgba, width: frame.width, height: frame.height, opaque: false)
    }

    /// A frame as Core Animation shows it (premultiplied: layers don't show straight alpha).
    nonisolated static func layerImage(_ frame: HGImage.Frame) -> CGImage? {
        cgImage(premultiplied: frame.premultipliedRGBA(), width: frame.width, height: frame.height)
    }

    nonisolated static func cgImage(_ rgba: [UInt8], width: Int, height: Int, opaque: Bool) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let info: CGImageAlphaInfo = opaque ? .noneSkipLast : .last
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A screen drawn over the story (premultiplied: `FESPlayer.transparent`).
    nonisolated static func cgImage(premultiplied rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Answers what the game's FES screens ask of the engine (settings, saves, the backlog)
/// from the game view, on the main thread where the screens run.
final class CatSystemScreens: FESHost, @unchecked Sendable {
    private weak var controller: CatSystemGameViewController?

    init(controller: CatSystemGameViewController) { self.controller = controller }

    private func on<T: Sendable>(_ body: @MainActor (CatSystemGameViewController) -> T?) -> T? {
        MainActor.assumeIsolated { controller.flatMap(body) }
    }

    func fesConfig(_ name: String) -> Int? { on { $0.config(name) } }
    func fesSetConfig(_ name: String, value: Int) { _ = on { $0.setConfig(name, value) } }
    func fesSoundConfig(_ args: [String]) -> Int? { on { $0.soundConfig(args) } }
    func fesSetSoundConfig(_ args: [String], value: Int) { _ = on { $0.setSoundConfig(args, value) } }
    func fesSaveState(slot: Int) -> Int { on { $0.saveState(slot) } ?? 0 }
    func fesNewestSave(from: Int, count: Int) -> Int { on { $0.newestSave(from: from, count: count) } ?? -1 }
    func fesSave(slot: Int) { _ = on { $0.saveInto(slot) } }
    func fesDeleteSave(slot: Int) { _ = on { $0.deleteSave(slot) } }
    func fesSaveInfo(slot: Int) -> FESSaveInfo? { on { $0.saveInfo(slot) } }
    func fesReturnToTitle() { _ = on { $0.screenReturnsToTitle() } }
    var fesLog: [FESLogEntry] { on { $0.logEntries } ?? [] }
    func fesPlayLogVoice(_ index: Int) { _ = on { $0.playLogVoice(index) } }
}

struct CatSystemGameView: UIViewControllerRepresentable {
    let gameFolder: URL
    var onFirstFrame: () -> Void = {}
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> CatSystemGameViewController {
        CatSystemGameViewController(gameFolder: gameFolder, onFirstFrame: onFirstFrame, onExit: onExit)
    }

    func updateUIViewController(_ controller: CatSystemGameViewController, context: Context) {}
}

#if os(iOS)
/// Laptop mode's trackpad and controls, as a trackpad over the game: buttons light under the
/// pointer and the game's own cursor follows it.
extension CatSystemGameViewController: LaptopInput {
    func laptopPointer(at point: CGPoint) -> Bool {
        pointerMoved(to: view.convert(point, to: stage))
        return cursors.normal != nil
    }

    func laptopClick(at point: CGPoint) {
        guard presentedViewController == nil else { return }
        primaryAction(at: view.convert(point, to: stage), pointer: true)
    }

    func laptopSecondaryClick(at point: CGPoint) { secondaryAction() }

    func laptopScroll(_ steps: Int, at point: CGPoint) {
        for _ in 0..<abs(steps) { wheel(up: steps > 0) }
    }

    func laptopSkip() { swipedSkip() }
    func laptopAuto() { swipedAuto() }
    func laptopBacklog() { openBacklog() }
    func laptopLeave() { confirmLeave() }
}
#endif
