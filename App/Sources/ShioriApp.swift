import Kingfisher
import SwiftUI

@main
struct ShioriApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var steam: SteamModel
    @State private var games: GameLibrary
    @State private var controllers = ControllerInput()
    @State private var curation = LibraryCuration()
    @State private var collections = LibraryCollections()
    @State private var engineScans: EngineScanStore
    @State private var compatibility = CompatibilityStore()
    @State private var patchList = PatchListStore()
    @State private var patchInstaller = PatchInstaller()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if os(tvOS)
        PressFilter.install()
        #endif
        APIKeyStore.steamGridDB.migrateToSynced()
        #if os(iOS)
        WhatsNew.shared.checkAtLaunch() // Before the library cache is written: tells an update from a first install.
        #endif
        SyncedPreferences.reload() // Loads (and migrates) the synced per-game choices now.
        // Other downloads (covers for the game runtime, SteamGridDB lookups) use URLCache.
        URLCache.shared = URLCache(memoryCapacity: 16 << 20, diskCapacity: 128 << 20)
        // Artwork: Kingfisher keeps decoded, downsampled images in memory and the originals
        // on disk, so scrolling the library doesn't decode art on the main thread again.
        let images = ImageCache.default
        images.memoryStorage.config.countLimit = 400
        images.memoryStorage.config.totalCostLimit = 150 << 20
        images.diskStorage.config.sizeLimit = 512 << 20
        images.diskStorage.config.expiration = .days(30)
        let steam = SteamModel()
        _steam = State(initialValue: steam)
        let games = GameLibrary(session: steam.session)
        games.libraryEntry = { [weak steam] appID in steam?.library.first { $0.appID == appID } }
        _games = State(initialValue: games)
        _engineScans = State(initialValue: EngineScanStore(session: steam.session))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(steam)
                .environment(games)
                .environment(controllers)
                .environment(curation)
                .environment(collections)
                .environment(engineScans)
                .environment(compatibility)
                .environment(patchList)
                .environment(patchInstaller)
                .environment(steam.artwork)
                .task { await games.syncAllSaves() }
                // Saves a game was left with (force quit, crash, background time ran out) go up
                // to Steam Cloud first thing once signed in.
                .task(id: steam.isLoggedOn) { if steam.isLoggedOn { await games.catchUpSteamCloudAll() } }
                .task { await compatibility.refresh() }
                .task { await patchList.refresh() }
                // Learn each visual novel's engine from its manifests, so the library and the
                // launcher can say what's playable before anything is downloaded.
                .task(id: "\(steam.library.count)-\(steam.isLoggedOn)-\(curation.added.count)") {
                    guard steam.isLoggedOn else { return }
                    engineScans.scan(steam.library.filter { curation.isVisualNovel($0) && games.status(for: $0.appID) == .notInstalled }.map(\.appID))
                }
                // Collections: suggested again whenever the games they're drawn from change, and
                // looked up on VNDB (cached) for the Visual Novels tab's games.
                .task(id: collectionInputs) {
                    collections.update(library: steam.library) { game in
                        curation.isVisualNovel(game) || games.status(for: game.appID) != .notInstalled
                    }
                }
                .task(id: visualNovelIDs) { await collections.refreshVNDB(appIDs: visualNovelIDs) }
            #if DEBUG || SHIORI_AUTOMATION
                .task(id: "\(steam.library.count)-\(steam.isLoggedOn)") { DebugAutomation.run(steam: steam, games: games, patches: patchInstaller) }
            #endif
            #if os(tvOS)
                // tvOS may have cleared downloaded games while Shiori wasn't running.
                .task(id: steam.isLoggedOn) { if steam.isLoggedOn { games.restoreClearedGames() } }
            #endif
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .background:
                shiori_renpy_did_enter_background()
                // A game running in any engine: its autosave, iCloud, then Steam Cloud, in one
                // background task (Steam's sync on exit, without ending the game).
                games.saveRunningGameForBackground()
                games.didEnterBackground()
                steam.didEnterBackground()
            case .inactive where old == .active:
                shiori_renpy_will_resign_active()
            case .active:
                // Settings other devices changed through iCloud Keychain.
                curation.reload()
                collections.reload()
                steam.artwork.reload()
                PlayHistory.shared.reload()
                SyncedPreferences.reload()
                if old == .background { Task { await steam.adoptSyncedSession() } }
                if old == .background { shiori_renpy_will_enter_foreground() }
                #if os(tvOS)
                if old == .background, steam.isLoggedOn, shiori_renpy_is_running() == 0 { games.restoreClearedGames() }
                #endif
                shiori_renpy_did_become_active()
                games.willEnterForeground()
                steam.willEnterForeground()
            default: break
            }
        }
        #if os(iOS)
        .commands { ShioriCommands(games: games) }
        #endif
    }
}

extension ShioriApp {
    /// What Collections' suggestions are drawn from: the library as Steam describes it, the
    /// Visual Novels tab's choices and which games are downloaded.
    private var collectionInputs: CollectionInputs {
        CollectionInputs(library: steam.library, added: curation.added, hidden: curation.hidden,
                         downloaded: Set(games.statuses.compactMap { $0.value == .notInstalled ? nil : $0.key }))
    }

    private var visualNovelIDs: [UInt32] {
        steam.library.filter { curation.isVisualNovel($0) }.map(\.appID)
    }
}

struct RootView: View {
    @Environment(SteamModel.self) private var steam
    @Environment(ControllerInput.self) private var controllers
    @Environment(GameLibrary.self) private var games

    var body: some View {
        @Bindable var games = games
        content
            .alert("Couldn't start the game", isPresented: Binding(get: { games.launchFailure != nil }, set: { if !$0 { games.launchFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(games.launchFailure ?? "")
            }
            .fullScreenCover(item: $games.artemisSession) { session in
                CoveredGame(art: session.cover) { firstFrame in
                    ArtemisGameView(gameFolder: session.folder, onFirstFrame: firstFrame) { games.artemisSession = nil }
                        .ignoresSafeArea()
                }
            }
            #if !os(tvOS)
            // Siglus and KiriKiri aren't built for Apple TV yet (Phase 15).
            .fullScreenCover(item: $games.siglusSession) { session in
                CoveredGame(art: session.cover) { firstFrame in
                    SiglusGameView(gameFolder: session.folder, onFirstFrame: firstFrame) { games.siglusSession = nil }
                        .ignoresSafeArea()
                }
            }
            #endif
            .fullScreenCover(item: $games.lucaSession) { session in
                CoveredGame(art: session.cover) { firstFrame in
                    LucaGameView(gameFolder: session.folder, onFirstFrame: firstFrame) { games.lucaSession = nil }
                        .ignoresSafeArea()
                }
            }
            #if !os(tvOS)
            .fullScreenCover(item: $games.catSystemSession) { session in
                CoveredGame(art: session.cover) { firstFrame in
                    CatSystemGameView(gameFolder: session.folder, onFirstFrame: firstFrame) { games.catSystemSession = nil }
                        .ignoresSafeArea()
                }
            }
            .fullScreenCover(item: $games.kirikiriSession) { session in
                CoveredGame(art: session.cover) { firstFrame in
                    KiriKiriGameView(gameFolder: session.folder, appID: session.appID, onFirstFrame: firstFrame) {
                        games.kirikiriSession = nil
                    }
                    .ignoresSafeArea()
                }
            }
            #endif
            #if os(iOS)
            .modifier(OnboardingSheets())
            #endif
            .overlay {
                if let appID = games.endingSession {
                    SessionEndingView(game: steam.library.first { $0.appID == appID })
                }
            }
            // The controller launcher stays alive under a game; it must hear none of its presses.
            .onChange(of: gameOnScreen, initial: true) { _, open in ControllerInput.gameOnScreen = open }
    }

    /// An in-process game's session is open (Ren'Py games are gated by the runtime itself).
    private var gameOnScreen: Bool {
        games.artemisSession != nil || games.siglusSession != nil || games.lucaSession != nil
            || games.catSystemSession != nil || games.kirikiriSession != nil
    }

    /// `-ShioriPreviewLibrary` (debug): the library from its on-disk cache without signing in,
    /// to look at the screens in a simulator with no Steam account.
    private static var previewLibrary: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "ShioriPreviewLibrary")
        #else
        false
        #endif
    }

    @ViewBuilder private var content: some View {
        if steam.isLoggedOn || steam.hasStoredSession || Self.previewLibrary {
            #if os(tvOS)
            // Apple TV has its own library (design A, Phase 15), the same for remote and pad.
            TVHomeView()
            #else
            // With a controller in hand the library becomes a console-style launcher.
            if controllers.isActive {
                LauncherView()
            } else {
                DuoBook { ShowcaseShell() }
                    .modifier(DebugCanvas())
            }
            #endif
        } else {
            #if os(tvOS)
            SignInView()
            #else
            SignInScreen()
                .modifier(DebugCanvas())
            #endif
        }
    }
}

/// Shown between a game ending and the app closing, while its saves go up.
struct SessionEndingView: View {
    let game: LibraryGame?

    var body: some View {
        ZStack {
            Color.black
            if let game {
                RemoteImage(url: game.hero, fallback: game.header) { Color.black }
                    .opacity(0.4)
            }
            VStack(spacing: 18) {
                if let logo = game?.logo {
                    RemoteImage(url: logo, contentMode: .fit) { EmptyView() }
                        .frame(maxWidth: 320, maxHeight: 140)
                }
                ProgressView().tint(.white)
                Text("Saving your progress…")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Shiori closes when your saves are up. Reopen it to play again.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }
}

// SHIORI_AUTOMATION: a Release build for smoke tests keeps these
// (`Scripts/release-smoke.sh`); shipped builds have neither flag.
#if DEBUG || SHIORI_AUTOMATION
/// Simulator test hooks, driven by launch arguments (`simctl launch … -ShioriAutoDownload 451760`).
/// `-ShioriAutoDownload <appid>` starts or resumes that download once the library loads;
/// `-ShioriAutoVerify <appid>` verifies an installed game; `-ShioriAutoPlay <appid>` starts it.
@MainActor
enum DebugAutomation {
    private static var done: Set<String> = []

    static func run(steam: SteamModel, games: GameLibrary, patches: PatchInstaller) {
        let defaults = UserDefaults.standard
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriAutoDownload")), appID != 0, steam.isLoggedOn,
           !done.contains("download"), let app = steam.library.first(where: { $0.appID == appID })
        {
            done.insert("download")
            games.download(app)
        }
        #if DEBUG
        // `-ShioriFakeDownload "<appid>,<appid>…"`: pretend downloads (the first runs, the rest
        // queue) ticking as real ones do, for measuring the screens; nothing is fetched.
        // `-ShioriFakePatch <appid>` (with `-ShioriFakePatchID <listed patch id>` to show it on
        // the game page) does the same for a patch download, ticking per network chunk.
        if let list = defaults.string(forKey: "ShioriFakeDownload"), !done.contains("fake") {
            done.insert("fake")
            for appID in list.split(separator: ",").compactMap({ UInt32($0) }) {
                if let game = steam.library.first(where: { $0.appID == appID }) { games.startFakeDownload(appID: appID, name: game.name) }
            }
        }
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriFakePatch")), appID != 0, !done.contains("fakePatch") {
            done.insert("fakePatch")
            patches.startFakeJob(appID: appID, patchID: defaults.string(forKey: "ShioriFakePatchID") ?? "fake")
        }
        #endif
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriAutoPlay")), appID != 0, !done.contains("play") {
            done.insert("play")
            // `-ShioriInput "<s>:<x>,<y>;<s>:esc;…"` replays taps and keys into the game.
            if let input = defaults.string(forKey: "ShioriInput") { setenv("SHIORI_INPUT", input, 1) }
            games.play(appID: appID)
        }
        // `-ShioriKiriKiriGame <folder in Documents>` opens a KiriKiri game folder (one holding
        // base/) without Steam: for running the engine on a Mac (Designed for iPad).
        // Not on Apple TV, which has no KiriKiri game view (the session would open nothing).
        #if !os(tvOS)
        if let name = defaults.string(forKey: "ShioriKiriKiriGame"), !done.contains("kirikiri") {
            done.insert("kirikiri")
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            games.kirikiriSession = .init(appID: 0, folder: documents.appendingPathComponent(name, isDirectory: true))
        }
        #endif
        // `-ShioriImportPatch <file in tmp/> -ShioriPatchGame <appid>` imports a patch.
        if let name = defaults.string(forKey: "ShioriImportPatch"), !done.contains("import"),
           let appID = UInt32(exactly: defaults.integer(forKey: "ShioriPatchGame")), appID != 0,
           let gameName = steam.library.first(where: { $0.appID == appID })?.name
        {
            done.insert("import")
            // Documents first (where the Files app puts things), else tmp/.
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let source = [documents, FileManager.default.temporaryDirectory].map { $0.appendingPathComponent(name) }
                .first { FileManager.default.fileExists(atPath: $0.path) } ?? documents.appendingPathComponent(name)
            let folder = games.folder(appID: appID, name: gameName)
            // Off the main thread with progress, as the game page imports.
            Task.detached {
                var shown = -1.0
                do {
                    let count = try PatchStore.importItem(at: source, gameFolder: folder) { written, total, file in
                        let fraction = total > 0 ? Double(written) / Double(total) : 0
                        guard fraction - shown >= 0.05 || fraction >= 1 else { return }
                        shown = fraction
                        NSLog("Shiori: importing %@: %.0f%% (%@)", name, fraction * 100, file)
                    }
                    NSLog("Shiori: imported %d patch files from %@", count, name)
                } catch {
                    NSLog("Shiori: patch import failed: %@", String(describing: error))
                }
            }
        }
        // `-ShioriSteamCloudPull <appid>` pulls that game's Steam Cloud saves once signed in.
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriSteamCloudPull")), appID != 0,
           steam.isLoggedOn, !done.contains("cloud")
        {
            done.insert("cloud")
            Task { await games.pullSteamCloud(appID: appID) }
        }
        // `-ShioriPreviewFiles <appid>` writes the game's depot file list (from manifests only,
        // nothing downloaded) to tmp/preview-<appid>.txt.
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriPreviewFiles")), appID != 0,
           steam.isLoggedOn, !done.contains("preview")
        {
            done.insert("preview")
            Task {
                do {
                    // `-ShioriPreviewBranch <name>` reads a beta branch instead of the default.
                    let preview = try await steam.session.preview(appID: appID, branch: defaults.string(forKey: "ShioriPreviewBranch") ?? "public")
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(appID).txt")
                    try preview.paths.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
                    NSLog("Shiori preview: %d paths for %u at %@", preview.paths.count, appID, url.path)
                    // `-ShioriPreviewFetch <path>` also fetches one small file (≤ 40 MB).
                    if let path = defaults.string(forKey: "ShioriPreviewFetch"),
                       let data = try await preview.contents(of: path, maxSize: 40 << 20)
                    {
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(appID)-" + (path as NSString).lastPathComponent)
                        try data.write(to: file)
                        NSLog("Shiori preview: fetched %@ (%d bytes)", path, data.count)
                    }
                } catch {
                    NSLog("Shiori preview failed: %@", String(describing: error))
                }
            }
        }
        // `-ShioriSteamCloudList <appid>,<appid>…` logs those games' Steam Cloud file names (read only).
        if let list = defaults.string(forKey: "ShioriSteamCloudList"), steam.isLoggedOn, !done.contains("cloudlist") {
            done.insert("cloudlist")
            Task {
                for appID in list.split(separator: ",").compactMap({ UInt32($0) }) {
                    do {
                        let (_, files) = try await steam.session.cloudFiles(appID: appID)
                        let names = files.filter { !$0.isDeleted }.map { "\($0.path) (\($0.size))" }
                        NSLog("Shiori cloud list %u: %d files: %@", appID, names.count, names.joined(separator: " | "))
                    } catch {
                        NSLog("Shiori cloud list %u failed: %@", appID, String(describing: error))
                    }
                }
            }
        }
        // `-ShioriSteamCloudDryRun <appid>` logs what an upload would send, without writing.
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriSteamCloudDryRun")), appID != 0,
           steam.isLoggedOn, !done.contains("dryrun"), let game = steam.library.first(where: { $0.appID == appID })
        {
            done.insert("dryrun")
            let saves = games.folder(appID: appID, name: game.name).appendingPathComponent("saves")
            Task {
                do {
                    let result = try await SteamCloudSync.push(session: steam.session, appID: appID, saves: saves, dryRun: true)
                    NSLog("Shiori dry run: would upload %@; would back up remote copies of %@",
                          result.uploaded.joined(separator: ", "), result.failed.joined(separator: ", "))
                } catch {
                    NSLog("Shiori dry run failed: %@", String(describing: error))
                }
            }
        }
        if let appID = UInt32(exactly: defaults.integer(forKey: "ShioriAutoVerify")), appID != 0, !done.contains("verify") {
            done.insert("verify")
            games.verify(appID: appID)
        }
    }
}
#endif
