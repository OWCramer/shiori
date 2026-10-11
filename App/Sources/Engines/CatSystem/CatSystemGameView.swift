import CatSystemKit
import CoreText
import SwiftUI
import UIKit

/// Plays a CatSystem2 game (NEKOPARA Vol. 3) with CatSystemKit. The title is the game's own
/// FES screens (logo, language picker, title menu) run by `FESPlayer`; GAME START runs the
/// kcScripts to the first scene, and `ScenePlayer` plays the story. Pictures are composited
/// at the game's 1280×720 and shown in a Core Animation layer, letterboxed; waits, fades and
/// `rwipe` become crossfades. The message window is the game's art with the text set in the
/// game's own font (GenJyuu Gothic X, from `font/`). E-mote characters are drawn by
/// CatSystemKit's `EmoteCast` in their scene pose (still; their idle motions, blinking and lip
/// sync aren't played yet).
final class CatSystemGameViewController: UIViewController, UIGestureRecognizerDelegate {
    private let gameFolder: URL
    private let onExit: () -> Void
    private var onFirstFrame: (() -> Void)?
    private var game: CatSystemGame?
    private var emote: EmoteCast?
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
    /// Text reveal speed, characters a second.
    private let textSpeed = 60.0

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
        registerFonts()
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
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        audio.stopAll()
    }

    // MARK: Opening the game

    /// The archives' name key is recovered once (about a second) and kept in Caches.
    private func open() {
        let base = base
        let cache = URL.cachesDirectory.appendingPathComponent("CatSystem/\(gameFolder.lastPathComponent)", isDirectory: true)
        let keyFile = cache.appendingPathComponent("namekey")
        Task.detached(priority: .userInitiated) {
            let known = (try? String(contentsOf: keyFile, encoding: .utf8)).flatMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) }
            let result = Result { try CatSystemGame(root: base, nameKey: known) }
            if case .success(let game) = result, known == nil, let key = game.nameKey {
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                try? String(key, radix: 16).write(to: keyFile, atomically: true, encoding: .utf8)
            }
            await MainActor.run { [weak self] in
                switch result {
                case .success(let game): self?.opened(game)
                case .failure(let error): self?.fail("This game can't start", error)
                }
            }
        }
    }

    private func opened(_ game: CatSystemGame) {
        self.game = game
        emote = EmoteCast(game: game)
        buildWindow(game)
        #if DEBUG
        // `-ShioriCatSystemLoad latest`: loads the newest save straight away (unattended runs).
        if UserDefaults.standard.string(forKey: "ShioriCatSystemLoad") == "latest", let save = CatSystemSave.list(in: saves).first {
            load(save)
            return
        }
        #endif
        startTitle(skipLogo: false)
    }

    private func fail(_ title: String, _ error: Error) {
        NSLog("CatSystem: %@: %@", title, String(describing: error))
        let alert = UIAlertController(title: title, message: String(describing: error), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Leave", style: .default) { [weak self] _ in self?.leave() })
        present(alert, animated: true)
    }

    private func registerFonts() {
        let folder = base.appendingPathComponent("font", isDirectory: true)
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
        if let bold, let font = UIFont(name: bold, size: 25) { textFont = font }
        if let heavy, let font = UIFont(name: heavy, size: 27) { nameFont = font }
    }

    /// The window's art in one picture: the brown band and its row of buttons.
    private func buildWindow(_ game: CatSystemGame) {
        let size = CGSize(width: 1280, height: 260)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let band = image("sys_meswnd_n")
        let parts = image("sys_meswnd")
        windowArt.image = renderer.image { context in
            func draw(_ frame: HGImage.Frame) {
                guard let cg = Self.cgImage(frame) else { return }
                UIImage(cgImage: cg).draw(in: CGRect(x: frame.offsetX, y: frame.offsetY, width: frame.width, height: frame.height))
            }
            if let band = band?.frames.first { draw(band) }
            for id in stride(from: 1000, through: 1090, by: 10) {
                if let frame = parts?.frame(id: id) { draw(frame) }
            }
        }
        if let wait = image("sys_meswnd_wait") {
            keyWait.animationImages = (11...19).compactMap { wait.frame(id: $0).flatMap(Self.cgImage).map { UIImage(cgImage: $0) } }
        }
        if let marker = parts?.frame(id: 50) {
            keyWait.frame = CGRect(x: marker.offsetX, y: marker.offsetY + 4, width: 34, height: 33)
        }
    }

    // MARK: Frames

    @objc private func frame() {
        audio.tick()
        if let fes {
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
    private func startTitle(skipLogo: Bool) {
        guard let game else { return }
        story = nil
        line = nil
        lineSnapshot = nil
        shownPlanes = nil
        shownCast = nil
        audio.stopAll()
        musicName = nil
        setWindow(visible: false, frames: 0)
        let player = FESPlayer(game: game)
        // `$897` says the language picker was answered; ttlflow goes straight to the title.
        if settings.languageChosen { player.setVariable(897, 1) }
        do {
            try player.start(skipLogo ? "ttlflow" : "flow")
        } catch {
            fail("This game can't start", error)
            return
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
            let rgba = fes.render()
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
        guard let button = fes.button(atX: Int(point.x), y: Int(point.y)) else { return }
        switch button {
        case "btn1[1]":
            // DATA LOAD: Shiori's own saves.
            showLoad()
        case "btn1[2]":
            let alert = UIAlertController(title: "CONFIG", message: "The game's settings screen isn't in Shiori yet.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
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
        waitUntil = 0
        backlog = []
        line = nil
    }

    // MARK: Story

    private func storyFrame() {
        let now = CACurrentMediaTime()
        if line != nil {
            revealLine()
            return
        }
        guard now >= waitUntil else { return }
        pump()
    }

    /// Runs the story until it shows a line or waits.
    private func pump() {
        var budget = 4000
        while budget > 0, let story, line == nil, CACurrentMediaTime() >= waitUntil {
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
            transitionFrames = words.count >= 3 ? Int(words[2]) ?? 40 : 40
        case "pl" where words.count >= 4 && (words[2] == "fade" || words[2] == "m2fade"):
            if let frames = Int(words[3]) { transitionFrames = max(transitionFrames ?? 0, frames) }
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
        default:
            break
        }
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
        case "vol": break
        default: audio.playEffect(args[1], channel: channel, loop: args.dropFirst(2).contains("loop") || args[1].hasPrefix("bgs"), game: game)
        }
    }

    /// Shows the planes as they are now, crossfading from what was shown.
    private func present(force: Bool = false) {
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
        revealed = min(Double(length), revealed + textSpeed / 60)
        setText(revealing: Int(revealed))
        if revealed >= Double(length) { lineFinished() }
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
            // Reads on: the voice stops, as in the game.
            audio.stopVoice()
            self.line = nil
            keyWait.stopAnimating()
            keyWait.isHidden = true
            pump()
        } else if CACurrentMediaTime() < waitUntil {
            // A tap cuts a wait or a crossfade short.
            waitUntil = 0
            picture.removeAllAnimations()
            pump()
        }
    }

    @objc private func showMenu() {
        guard presentedViewController == nil, game != nil else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        if story != nil, lineSnapshot != nil {
            alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self] _ in self?.saveGame() })
        }
        alert.addAction(UIAlertAction(title: "Load", style: .default) { [weak self] _ in self?.showLoad() })
        if story != nil {
            alert.addAction(UIAlertAction(title: "Backlog", style: .default) { [weak self] _ in self?.showBacklog() })
            alert.addAction(UIAlertAction(title: "Title", style: .default) { [weak self] _ in
                self?.autosave()
                self?.startTitle(skipLogo: true)
            })
        }
        alert.addAction(UIAlertAction(title: "Quit", style: .destructive) { [weak self] _ in self?.leave() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        alert.popoverPresentationController?.permittedArrowDirections = []
        present(alert, animated: true)
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
        fes = nil
        startingStory = false
        audio.stopAll()
        story = player
        backlog = []
        transitionFrames = nil
        waitUntil = 0
        shownPlanes = nil
        shownCast = nil
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

    static func cgImage(_ frame: HGImage.Frame) -> CGImage? {
        cgImage(frame.rgba, width: frame.width, height: frame.height, opaque: false)
    }

    static func cgImage(_ rgba: [UInt8], width: Int, height: Int, opaque: Bool) -> CGImage? {
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
