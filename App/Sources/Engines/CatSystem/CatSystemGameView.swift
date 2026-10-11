import CatSystemKit
import CoreText
import SwiftUI
import UIKit

/// Plays a CatSystem2 game (NEKOPARA Vol. 3) with CatSystemKit. The title is the game's own
/// FES screens (logo, language picker, title menu) run by `FESPlayer`; GAME START runs the
/// kcScripts to the first scene, and `ScenePlayer` plays the story. The story's screen is
/// drawn with Metal every frame (`CatSystemStageRenderer`): each plane a texture, and the E-mote characters on the GPU at the screen's
/// resolution, posed for the moment by `EmoteStage` (idle loops, blinking, lip sync with the
/// voice, expression changes, `mpl` slides and fades, hair and bust inertia); `fmpl` faces
/// are drawn in the message window. Planes are drawn every frame too, moved, scaled, faded and
/// shaken by `PlaneStage`; transitions crossfade (`rdraw`) or wipe through the game's rule
/// pictures (`rwipe`). Movies (WMV) play through `CatSystemMovie`. The message
/// window is the game's art with the text set in the game's own font (GenJyuu Gothic X, from
/// `font/`). The title's FES screens are a Core Animation layer.
final class CatSystemGameViewController: UIViewController, UIGestureRecognizerDelegate {
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
    private let audio = CatSystemAudio()
    private var displayLink: CADisplayLink?
    private var leaving = false

    // The 1280×720 stage, scaled to fit; everything in it is in game pixels.
    private let stageSize = CGSize(width: 1280, height: 720)
    private let stage = UIView()
    private let picture = CALayer()
    private let window = UIView()
    private let windowArt = UIImageView()
    private let nameLabel = UILabel()
    private let textLabel = UILabel()
    private let keyWait = UIImageView()
    private var textFont = UIFont.systemFont(ofSize: 25, weight: .semibold)
    private var nameFont = UIFont.systemFont(ofSize: 25, weight: .heavy)

    // Title (FES)
    private var fes: FESPlayer?
    private var fesDrawn: Int?
    private var startingStory = false

    // Story
    private var story: ScenePlayer?
    private var shownPlanes: [Int: ScenePlayer.Plane]?
    private var shownCast: [Int: ScenePlayer.Character]?
    /// The next crossfade's length in frames (`rwipe`, `pl N fade`), else the game's default.
    private var transitionFrames: Int?
    private var transitionEnds: CFTimeInterval = 0
    private var waitUntil: CFTimeInterval = 0
    private var line: CatSystemLine?
    private var lineScene = ""
    private var lineIndex = 0
    private var revealed = 0.0
    /// The story's state while the line on screen shows (what a save keeps).
    private var lineSnapshot: ScenePlayer.Snapshot?
    private var backlog: [CatSystemLine] = []
    private var musicName: String?
    private var images: [String: HGImage] = [:]
    private var imageOrder: [String] = []
    private var settings = CatSystemSettings()
    private var sheet: UIViewController?
    /// A movie playing (`movie nekopara3op`): the story waits until it ends or a tap skips it.
    private var movie: CatSystemMovie?
    /// Auto mode (the two-finger menu): lines read on by themselves once shown and voiced.
    private var autoMode = false
    /// When the line on screen was fully shown with its voice ended (for Auto's wait).
    private var lineDoneAt: CFTimeInterval?

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

    private var base: URL { gameFolder.appendingPathComponent("base", isDirectory: true) }
    private var saves: URL { gameFolder.appendingPathComponent("saves", isDirectory: true) }

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
        windowArt.frame = window.bounds
        window.addSubview(windowArt)
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

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        view.addGestureRecognizer(tap)
        let menu = UITapGestureRecognizer(target: self, action: #selector(showMenu))
        menu.numberOfTouchesRequired = 2
        view.addGestureRecognizer(menu)
        tap.require(toFail: menu)
        let history = UISwipeGestureRecognizer(target: self, action: #selector(showBacklog))
        history.direction = .down
        history.numberOfTouchesRequired = 2
        view.addGestureRecognizer(history)
        let leave = UILongPressGestureRecognizer(target: self, action: #selector(askToLeave(_:)))
        leave.numberOfTouchesRequired = 2
        leave.minimumPressDuration = 0.8
        view.addGestureRecognizer(leave)
        menu.require(toFail: leave)

        try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        settings = CatSystemSettings.load(from: saves)
        applySettings()
        open()

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        let link = CADisplayLink(target: self, selector: #selector(frame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        OrientationLock.set(.landscape, in: view.window?.windowScene)
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
        let fonts: (text: String?, name: String?)
        let window: Window
        let title: FESPlayer?
        let titleError: Error?
    }

    /// The message window's art: the band and its buttons as one picture, the key-wait
    /// paw's frames and its place.
    private struct Window {
        var art: UIImage?
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
        let cache = URL.cachesDirectory.appendingPathComponent("CatSystem/\(gameFolder.lastPathComponent)", isDirectory: true)
        let keyFile = cache.appendingPathComponent("namekey")
        let languageChosen = settings.languageChosen
        Task.detached(priority: .userInitiated) {
            let started = CACurrentMediaTime()
            let known = (try? String(contentsOf: keyFile, encoding: .utf8)).flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) }
            let result = Result { try CatSystemGame(root: base, nameKey: known) }
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
            let title = FESPlayer(game: game)
            if languageChosen { title.setVariable(897, 1) }
            var titleError: Error?
            do { try title.start("flow") } catch { titleError = error }
            title.preload(scripts: ["flow", "brandlogo"])
            NSLog("CatSystem: opened in %.2f s (archives %.2f s), all off the main thread",
                  CACurrentMediaTime() - started, archives - started)
            let opened = Opened(game: game, cast: cast, stage: stage, fonts: fonts, window: window,
                                title: titleError == nil ? title : nil, titleError: titleError)
            await MainActor.run { [weak self] in self?.opened(opened) }
            // The language picker's and the title's pictures, while the logo shows.
            let preloading = CACurrentMediaTime()
            title.preload(scripts: ["langselect", "title", "ttlflow", "confirm"])
            NSLog("CatSystem: title pictures decoded in %.2f s", CACurrentMediaTime() - preloading)
        }
    }

    private func opened(_ opened: Opened) {
        let game = opened.game
        self.game = game
        emote = opened.cast
        emoteStage = EmoteStage(cast: opened.cast)
        faceStage = EmoteStage(cast: opened.cast)
        if let name = opened.fonts.text, let font = UIFont(name: name, size: 25) { textFont = font }
        if let name = opened.fonts.name, let font = UIFont(name: name, size: 27) { nameFont = font }
        windowArt.image = opened.window.art
        keyWait.animationImages = opened.window.wait
        if let frame = opened.window.waitFrame { keyWait.frame = frame }
        if let resources = opened.stage, let renderer = CatSystemStageRenderer(resources: resources) {
            stageRenderer = renderer
            renderer.layer.frame = stage.bounds
            renderer.layer.isHidden = true
            stage.layer.insertSublayer(renderer.layer, above: picture)
            renderer.faceLayer.frame = CatSystemStageRenderer.faceBox
            window.layer.insertSublayer(renderer.faceLayer, above: windowArt.layer)
            view.setNeedsLayout()
        }
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

    private func fail(_ title: String, _ error: Error) {
        NSLog("CatSystem: %@: %@", title, String(describing: error))
        let alert = UIAlertController(title: title, message: String(describing: error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    /// Registers the game's fonts (`font/`, GenJyuu Gothic X) for this process: the names of
    /// its bold (the text) and heavy (the speaker) faces.
    nonisolated private static func registerFonts(in folder: URL) -> (text: String?, name: String?) {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var names: [String: String] = [:]
        for url in files where ["ttf", "otf", "ttc"].contains(url.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
               let name = descriptors.first.flatMap({ CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }) {
                names[url.deletingPathExtension().lastPathComponent.lowercased()] = name
            }
        }
        let bold = names.first { $0.key.hasSuffix("bold") }?.value
        let heavy = names.first { $0.key.hasSuffix("heavy") }?.value ?? bold
        return (bold, heavy)
    }

    /// The window's art in one picture: the brown band and its row of buttons.
    nonisolated private static func windowArt(_ game: CatSystemGame) -> Window {
        func picture(_ name: String) -> HGImage? {
            ((try? game.file(named: name + ".hg3")) ?? nil).flatMap { try? HGImage($0) }
        }
        let size = CGSize(width: 1280, height: 260)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let band = picture("sys_meswnd_n")
        let parts = picture("sys_meswnd")
        var window = Window()
        window.art = renderer.image { context in
            func draw(_ frame: HGImage.Frame) {
                guard let cg = cgImage(frame) else { return }
                UIImage(cgImage: cg).draw(in: CGRect(x: frame.offsetX, y: frame.offsetY, width: frame.width, height: frame.height))
            }
            if let band = band?.frames.first { draw(band) }
            for id in stride(from: 1000, through: 1090, by: 10) {
                if let frame = parts?.frame(id: id) { draw(frame) }
            }
        }
        if let wait = picture("sys_meswnd_wait") {
            window.wait = (11...19).compactMap { wait.frame(id: $0).flatMap(cgImage).map { UIImage(cgImage: $0) } }
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
                  movie != nil ? "movie" : fes != nil ? "title" : "story")
        }
        lastFrame = now
        audio.tick()
        if let movie {
            movie.draw()
            if movie.finished { endMovie() }
        } else if let fes {
            titleFrame(fes)
        } else if story != nil {
            storyFrame()
        }
    }

    private func liftCover() {
        if let lift = onFirstFrame {
            onFirstFrame = nil
            lift()
        }
    }

    // MARK: Title

    /// The boot flow (`flow.fes`: logo, language picker, title) or, coming back from the
    /// story, the title flow alone (`ttlflow.fes`).
    private func startTitle(skipLogo: Bool, prepared: FESPlayer? = nil) {
        guard let game else { return }
        stopMovie()
        story = nil
        line = nil
        lineSnapshot = nil
        shownPlanes = nil
        shownCast = nil
        stageRenderer?.layer.isHidden = true
        emoteStage?.reset([:], time: 0)
        faceStage?.reset([:], time: 0)
        stageRenderer?.renderFaces([])
        audio.stopAll()
        musicName = nil
        setWindow(visible: false, frames: 0)
        let player: FESPlayer
        if let prepared {
            player = prepared
        } else {
            player = FESPlayer(game: game)
            // `$897` says the language picker was answered; ttlflow goes straight to the title.
            if settings.languageChosen { player.setVariable(897, 1) }
            do {
                try player.start(skipLogo ? "ttlflow" : "flow")
            } catch {
                fail("This game can't start", error)
                return
            }
        }
        fes = player
        fesDrawn = nil
        startingStory = false
    }

    private func titleFrame(_ fes: FESPlayer) {
        guard let game else { return }
        fes.step()
        for sound in fes.takeSounds() {
            let channel = sound.channel.lowercased()
            if let file = sound.file {
                if sound.table {
                    audio.playMusic(file, game: game, fadeFrames: 30)
                } else if channel.hasPrefix("voice") {
                    audio.playVoice(file, game: game)
                } else {
                    audio.playEffect(file, channel: "sys-" + channel, game: game)
                }
            } else if sound.table {
                audio.stopMusic(fadeFrames: 30)
            } else if channel.hasPrefix("voice") {
                audio.stopVoice()
            } else {
                audio.stopEffect("sys-" + channel, fadeFrames: 0)
            }
        }
        if !settings.languageChosen, fes.stack.contains(where: { $0.hasPrefix("title#") }) {
            settings.languageChosen = true
            settings.save(to: saves)
        }
        let state = fes.drawState
        if state != fesDrawn {
            fesDrawn = state
            let started = CACurrentMediaTime()
            let rgba = fes.render()
            let took = CACurrentMediaTime() - started
            if took > 0.03 { NSLog("CatSystem: the title screen took %.0f ms to draw", took * 1000) }
            picture.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            picture.contents = Self.cgImage(rgba, width: fes.width, height: fes.height, opaque: true)
            CATransaction.commit()
            liftCover()
        }
        // GAME START: flow.fes asks for sscript; ttlflow alone exits 0 with `$512 = -3`.
        if !startingStory, fes.requestedKCS == "sscript" || (fes.rootExitCode == 0 && fes.variables[512] == -3) {
            startingStory = true
            startStory(after: fes)
        }
    }

    private func titleTap(_ point: CGPoint) {
        guard let fes, !startingStory else { return }
        let button = fes.button(atX: Int(point.x), y: Int(point.y))
        #if DEBUG
        NSLog("CatSystem: title tap at %.0f,%.0f: %@ (%@)", point.x, point.y, button ?? "nothing", fes.stack.joined(separator: " > "))
        #endif
        guard let button else { return }
        switch button {
        case "btn1[1]":
            // DATA LOAD: Shiori's own saves.
            showLoad()
        case "btn1[2]":
            // CONFIG: Shiori's own (the game's config.fes isn't run yet).
            showConfig()
        case "btn1[4]":
            confirmLeave()
        default:
            fes.push(button)
        }
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
        planeStage.reset([:])
        waitUntil = 0
        backlog = []
        line = nil
    }

    // MARK: Story

    private func storyFrame() {
        if movie != nil {
            return
        } else if let line {
            revealLine()
            autoAdvance(line)
        } else if CACurrentMediaTime() >= waitUntil {
            pump()
        }
        drawStage()
    }

    /// The story's screen this frame: characters posed for now (idle, blinks, the voice's
    /// lip sync, motions under way), drawn with Metal.
    private func drawStage() {
        guard story != nil, let stageRenderer, let emoteStage, !stageRenderer.layer.isHidden else { return }
        let now = CACurrentMediaTime()
        emoteStage.setVoice(audio.isVoicePlaying ? audio.voiceName : nil, startedAt: audio.voiceStarted)
        let planes = planeDrawings(stageRenderer, at: now)
        stageRenderer.render(below: planes.below, emoteStage.drawings(at: now), above: planes.above)
        if let faceStage {
            faceStage.setVoice(audio.isVoicePlaying ? audio.voiceName : nil, startedAt: audio.voiceStarted)
            stageRenderer.renderFaces(faceStage.drawings(at: now))
        }
    }

    /// Runs the story until it shows a line or waits.
    private func pump() {
        var budget = 4000
        while budget > 0, let story, line == nil, movie == nil, CACurrentMediaTime() >= waitUntil {
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
            if words.count >= 2, let frames = Int(words[1]) {
                waitUntil = now + Double(frames) / 60
            } else if words.count == 1 {
                waitUntil = max(waitUntil, transitionEnds)
            }
        case "rwipe":
            // `rwipe wipe04a 40`: a wipe through the rule picture (`wipedef`, 40 frames).
            transitionFrames = words.count >= 3 ? Int(words[2]) ?? 40 : 40
            transitionRule = words.count >= 2 ? words[1] : nil
        case "rdraw", "rwmos":
            // `rdraw 60`: the next drawing crossfades over its frames (`drawdef`, 15);
            // `rwmos` (a mosaic) is a crossfade here.
            transitionFrames = words.count >= 2 ? Int(words[1]) ?? 15 : 15
            transitionRule = nil
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
            soundEffect(Array(words.dropFirst()), game: game)
        case "frameoff":
            setWindow(visible: false, frames: words.count >= 3 ? Int(words[2]) ?? 15 : 15)
        case "frameon":
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
        guard let player = CatSystemMovie(name: name, game: game, volume: audio.musicVolume) else {
            NSLog("CatSystem: movie %@ doesn't play here; skipped", name)
            return
        }
        player.layer.frame = stage.bounds
        let scale = stage.transform.a, screen = view.window?.screen.scale ?? 3
        player.layer.contentsScale = max(1, screen * scale)
        player.layer.drawableSize = CGSize(width: (stageSize.width * scale * screen).rounded(),
                                           height: (stageSize.height * scale * screen).rounded())
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
        let frames = force ? 0 : transitionFrames ?? 15
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
        let frames = force ? 0 : transitionFrames ?? (planesChanged ? 15 : 20)
        let transitionRuleName = transitionRule
        let rule = force ? nil : transitionRule.flatMap { ruleTexture($0, renderer) }
        transitionFrames = nil
        transitionRule = nil
        if renderer.layer.isHidden {
            renderer.layer.isHidden = false
        } else if frames > 0 {
            var seconds = Double(frames) / 60
            #if DEBUG
            // `-ShioriCatSystemSlowTransitions 8`: transitions eight times as long (to look at wipes).
            let slow = UserDefaults.standard.double(forKey: "ShioriCatSystemSlowTransitions")
            if slow > 0 { seconds *= slow }
            #endif
            renderer.transition(seconds: seconds, rule: rule)
            if rule != nil { NSLog("CatSystem: wipe %@ over %.2f s", transitionRuleName ?? "?", seconds) }
        }
        transitionEnds = CACurrentMediaTime() + Double(frames) / 60
        liftCover()
    }

    /// `pl N amove1/2/3`, `move`, `ascale1/2/3`, `fade`, `quake`, `stop` (and `pl quake`
    /// for every plane) start at once on what is shown, without a transition.
    private func planeMotion(_ words: [String], text: String, story: ScenePlayer, time: Double) {
        guard words.count >= 3 else { return }
        let motions: Set<String> = ["amove1", "amove2", "amove3", "move", "ascale1", "ascale2", "ascale3",
                                    "fade", "m2fade", "quake", "stop"]
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
    }

    /// The planes shown, as drawn at `time`: those up to 0 under the characters, the rest
    /// over them.
    private func planeDrawings(_ renderer: CatSystemStageRenderer, at time: Double)
        -> (below: [CatSystemStageRenderer.PlaneDrawing], above: [CatSystemStageRenderer.PlaneDrawing]) {
        guard let planes = shownPlanes else { return ([], []) }
        var below: [CatSystemStageRenderer.PlaneDrawing] = [], above: [CatSystemStageRenderer.PlaneDrawing] = []
        let w = Double(stageSize.width), h = Double(stageSize.height)
        for n in planes.keys.sorted() {
            guard let plane = planes[n], plane.visible else { continue }
            let state = planeStage.state(n, plane, at: time)
            guard state.alpha > 0.5 else { continue }
            var drawing: CatSystemStageRenderer.PlaneDrawing?
            if let color = plane.color {
                let key = String(format: "$%08X", color)
                if let texture = planeTexture(key, renderer, make: { renderer.texture(color: color) }) {
                    drawing = .init(texture: texture, x: state.offsetX, y: state.offsetY, width: w, height: h, alpha: state.alpha / 255)
                }
            } else if let file = plane.file, let image = image(file), let frame = image.frames.first {
                let at = plane.placement(baseX: frame.baseX, baseY: frame.baseY, canvasWidth: frame.canvasWidth,
                                         canvasHeight: frame.canvasHeight, width: Int(w), height: Int(h))
                let baseX = Double(at.anchorX - at.originX), baseY = Double(at.anchorY - at.originY)
                let ax = state.x ?? Double(at.anchorX), ay = state.y ?? Double(at.anchorY)
                let sx = state.scaleX / 100, sy = state.scaleY / 100
                if let texture = planeTexture(file.lowercased(), renderer, make: {
                    renderer.texture(rgba: frame.premultipliedRGBA(), width: frame.width, height: frame.height, premultiplied: true)
                }) {
                    drawing = .init(texture: texture,
                                    x: ax + (Double(frame.offsetX) - baseX) * sx + state.offsetX,
                                    y: ay + (Double(frame.offsetY) - baseY) * sy + state.offsetY,
                                    width: Double(frame.width) * sx, height: Double(frame.height) * sy,
                                    alpha: state.alpha / 255)
                }
            }
            guard let drawing else { continue }
            if n <= 0 { below.append(drawing) } else { above.append(drawing) }
        }
        return (below, above)
    }

    private func planeTexture(_ key: String, _ renderer: CatSystemStageRenderer, make: () -> MTLTexture?) -> MTLTexture? {
        if let hit = planeTextures[key] { return hit }
        guard let texture = make() else { return nil }
        planeTextures[key] = texture
        planeTextureOrder.append(key)
        if planeTextureOrder.count > 16 { planeTextures.removeValue(forKey: planeTextureOrder.removeFirst()) }
        return texture
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
        display(CatSystemLine(speaker: message.speaker, text: message.text, voice: message.voice))
        if let voice = message.voice { audio.playVoice(voice, game: game) }
    }

    private func display(_ shown: CatSystemLine) {
        line = shown
        backlog.append(shown)
        if backlog.count > 300 { backlog.removeFirst(backlog.count - 300) }
        revealed = 0
        keyWait.stopAnimating()
        keyWait.isHidden = true
        nameLabel.attributedText = shown.speaker.map { name in
            NSAttributedString(string: name, attributes: [
                .font: nameFont,
                .foregroundColor: UIColor(red: 1, green: 0.84, blue: 0.25, alpha: 1),
                .strokeColor: UIColor(red: 0.42, green: 0.2, blue: 0.05, alpha: 1),
                .strokeWidth: -5,
            ])
        }
        setText(revealing: 0)
        if window.alpha < 1 { setWindow(visible: true, frames: 10) }
    }

    private func setText(revealing count: Int) {
        guard let line else { return }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor(red: 0.25, green: 0.1, blue: 0.02, alpha: 0.9)
        shadow.shadowOffset = CGSize(width: 0, height: 1.5)
        shadow.shadowBlurRadius = 3
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        let text = NSMutableAttributedString(string: line.text, attributes: [
            .font: textFont, .foregroundColor: UIColor.white, .shadow: shadow, .paragraphStyle: paragraph,
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
        if revealed >= Double(length) { lineFinished() }
    }

    /// Auto: once the line is shown and its voice has ended, waits as the CONFIG's auto
    /// speed says, then reads on.
    private func autoAdvance(_ line: CatSystemLine) {
        guard autoMode, presentedViewController == nil else { lineDoneAt = nil; return }
        let length = (line.text as NSString).length
        guard revealed >= Double(length), !audio.isVoicePlaying else { lineDoneAt = nil; return }
        let now = CACurrentMediaTime()
        guard let done = lineDoneAt else { lineDoneAt = now; return }
        if now - done >= settings.autoWait(letters: length) {
            lineDoneAt = nil
            readOn()
        }
    }

    private func lineFinished() {
        keyWait.isHidden = false
        keyWait.startAnimating()
    }

    private func setWindow(visible: Bool, frames: Int) {
        let duration = Double(frames) / 60
        UIView.animate(withDuration: duration) { self.window.alpha = visible ? 1 : 0 }
    }

    // MARK: Touch

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard presentedViewController == nil else { return }
        let point = recognizer.location(in: stage)
        if movie != nil {
            // A tap skips the movie.
            endMovie()
            return
        }
        if fes != nil {
            titleTap(point)
            return
        }
        guard story != nil else { return }
        if let line {
            let length = (line.text as NSString).length
            if revealed < Double(length) {
                revealed = Double(length)
                setText(revealing: length)
                lineFinished()
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

    /// Leaves the line on screen for the story's next: the voice stops, as in the game.
    private func readOn() {
        audio.stopVoice()
        line = nil
        lineDoneAt = nil
        keyWait.stopAnimating()
        keyWait.isHidden = true
        pump()
    }

    @objc private func showMenu() {
        guard presentedViewController == nil, game != nil else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if story != nil, lineSnapshot != nil {
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.saveGame() })
        }
        alert.addAction(UIAlertAction(title: "Load", style: .default) { [weak self] _ in self?.showLoad() })
        if story != nil {
            alert.addAction(UIAlertAction(title: autoMode ? "Auto: On" : "Auto: Off", style: .default) { [weak self] _ in
                guard let self else { return }
                self.autoMode.toggle()
                self.lineDoneAt = nil
                self.flash(self.autoMode ? "Auto" : "Auto Off")
            })
            alert.addAction(UIAlertAction(title: "Backlog", style: .default) { [weak self] _ in self?.showBacklog() })
            alert.addAction(UIAlertAction(title: "Title", style: .default) { [weak self] _ in
                self?.autosave()
                self?.startTitle(skipLogo: true)
            })
        }
        alert.addAction(UIAlertAction(title: "Config", style: .default) { [weak self] _ in self?.showConfig() })
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        alert.popoverPresentationController?.permittedArrowDirections = []
        present(alert, animated: true)
    }

    private func showConfig() {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView: CatSystemConfig(settings: settings, onChange: { [weak self] new in
            guard let self else { return }
            self.settings = new
            self.applySettings()
            self.settings.save(to: self.saves)
        }, onClose: { [weak self] in self?.dismiss(animated: true) }))
        host.overrideUserInterfaceStyle = .dark
        present(host, animated: true)
    }

    private func applySettings() {
        audio.setVolumes(music: Float(settings.music), voice: Float(settings.voice),
                         effects: Float(settings.effects), system: Float(settings.system))
    }

    @objc private func showBacklog() {
        guard presentedViewController == nil, story != nil, !backlog.isEmpty, let game else { return }
        let host = UIHostingController(rootView: CatSystemBacklog(lines: backlog, onVoice: { [weak self] voice in
            self?.audio.playVoice(voice, game: game)
        }, onClose: { [weak self] in self?.dismiss(animated: true) }))
        host.overrideUserInterfaceStyle = .dark
        present(host, animated: true)
    }

    @objc private func askToLeave(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        confirmLeave()
    }

    private func confirmLeave() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Leave the game?", message: story != nil ? "Your place is kept as the autosave." : nil,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Keep Playing", style: .cancel))
        present(alert, animated: true)
    }

    private func leave() {
        guard !leaving else { return }
        leaving = true
        stopMovie()
        autosave()
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
        OrientationLock.set(.all, in: view.window?.windowScene)
        onExit()
    }

    // MARK: Saves

    private func currentSave() -> CatSystemSave? {
        guard let line, let lineSnapshot else { return nil }
        return CatSystemSave(date: Date(), snapshot: lineSnapshot, speaker: line.speaker, text: line.text,
                             voice: line.voice, messageIndex: lineIndex, scene: lineScene)
    }

    private func saveGame() {
        guard let save = currentSave() else { return }
        do {
            let file = try save.write(to: saves)
            NSLog("CatSystem: saved %@ (scene %@)", file, save.scene)
            flash("Saved")
        } catch {
            fail("Couldn't save", error)
        }
    }

    private func autosave() {
        guard let save = currentSave() else { return }
        _ = try? save.write(to: saves, name: CatSystemSave.autosaveName)
    }

    private func showLoad() {
        guard presentedViewController == nil else { return }
        let host = UIHostingController(rootView: CatSystemLoadList(folder: saves, onPick: { [weak self] save in
            self?.dismiss(animated: true) { self?.load(save) }
        }, onClose: { [weak self] in self?.dismiss(animated: true) }))
        host.overrideUserInterfaceStyle = .dark
        present(host, animated: true)
    }

    private func load(_ save: CatSystemSave) {
        guard let game else { return }
        let player = ScenePlayer(game: game)
        do { try player.restore(save.snapshot) } catch {
            fail("Couldn't load", error)
            return
        }
        NSLog("CatSystem: loaded %@ (scene %@, line %d)", save.file, save.scene, save.messageIndex)
        stopMovie()
        fes = nil
        startingStory = false
        audio.stopAll()
        story = player
        backlog = []
        transitionFrames = nil
        waitUntil = 0
        shownPlanes = nil
        shownCast = nil
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
        display(CatSystemLine(speaker: save.speaker, text: save.text, voice: save.voice))
        setWindow(visible: true, frames: 0)
        if let voice = save.voice { audio.playVoice(voice, game: game) }
    }

    private func flash(_ text: String) {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        label.layer.cornerRadius = 12
        label.clipsToBounds = true
        label.frame = CGRect(x: 0, y: 0, width: 140, height: 44)
        label.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        view.addSubview(label)
        UIView.animate(withDuration: 0.4, delay: 0.9, options: []) { label.alpha = 0 } completion: { _ in label.removeFromSuperview() }
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

    nonisolated static func cgImage(_ rgba: [UInt8], width: Int, height: Int, opaque: Bool) -> CGImage? {
        guard width > 0, height > 0, rgba.count >= width * height * 4,
              let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        let info: CGImageAlphaInfo = opaque ? .noneSkipLast : .last
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: info.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
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
