import SwiftUI

@main
struct VNHubApp: App {
    @State private var steam: SteamModel
    @State private var games: GameLibrary
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Capsule and hero art from Steam's CDN; keep plenty on disk so the grid is instant.
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
        let steam = SteamModel()
        _steam = State(initialValue: steam)
        _games = State(initialValue: GameLibrary(session: steam.session))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(steam)
                .environment(games)
                .task { await games.syncAllSaves() }
            #if DEBUG
                .task(id: "\(steam.library.count)-\(steam.isLoggedOn)") { DebugAutomation.run(steam: steam, games: games) }
            #endif
        }
        .onChange(of: scenePhase) { old, phase in
            switch phase {
            case .background:
                vnhub_renpy_did_enter_background()
                if vnhub_renpy_is_running() != 0 { games.pushRunningGameSaves() }
                games.didEnterBackground()
            case .inactive where old == .active:
                vnhub_renpy_will_resign_active()
            case .active:
                if old == .background { vnhub_renpy_will_enter_foreground() }
                vnhub_renpy_did_become_active()
                games.willEnterForeground()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Environment(SteamModel.self) private var steam

    var body: some View {
        if steam.isLoggedOn || steam.hasStoredSession {
            LibraryView()
        } else {
            SignInView()
        }
    }
}

#if DEBUG
/// Simulator test hooks, driven by launch arguments (`simctl launch … -VNHubAutoDownload 451760`).
/// `-VNHubAutoDownload <appid>` starts or resumes that download once the library loads;
/// `-VNHubAutoVerify <appid>` verifies an installed game; `-VNHubAutoPlay <appid>` starts it.
@MainActor
enum DebugAutomation {
    private static var done: Set<String> = []

    static func run(steam: SteamModel, games: GameLibrary) {
        let defaults = UserDefaults.standard
        if let appID = UInt32(exactly: defaults.integer(forKey: "VNHubAutoDownload")), appID != 0, steam.isLoggedOn,
           !done.contains("download"), let app = steam.library.first(where: { $0.appID == appID })
        {
            done.insert("download")
            games.download(app)
        }
        if let appID = UInt32(exactly: defaults.integer(forKey: "VNHubAutoPlay")), appID != 0, !done.contains("play") {
            done.insert("play")
            // `-VNHubInput "<s>:<x>,<y>;<s>:esc;…"` replays taps and keys into the game.
            if let input = defaults.string(forKey: "VNHubInput") { setenv("VNHUB_INPUT", input, 1) }
            games.play(appID: appID)
        }
        // `-VNHubImportPatch <file in tmp/> -VNHubPatchGame <appid>` imports a patch.
        if let name = defaults.string(forKey: "VNHubImportPatch"), !done.contains("import"),
           let appID = UInt32(exactly: defaults.integer(forKey: "VNHubPatchGame")), appID != 0,
           let gameName = steam.library.first(where: { $0.appID == appID })?.name
        {
            done.insert("import")
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                let count = try PatchStore.importItem(at: source, gameFolder: games.folder(appID: appID, name: gameName))
                NSLog("VN Hub: imported %d patch files from %@", count, name)
            } catch {
                NSLog("VN Hub: patch import failed: %@", String(describing: error))
            }
        }
        // `-VNHubSteamCloudPull <appid>` pulls that game's Steam Cloud saves once signed in.
        if let appID = UInt32(exactly: defaults.integer(forKey: "VNHubSteamCloudPull")), appID != 0,
           steam.isLoggedOn, !done.contains("cloud")
        {
            done.insert("cloud")
            Task { await games.pullSteamCloud(appID: appID) }
        }
        if let appID = UInt32(exactly: defaults.integer(forKey: "VNHubAutoVerify")), appID != 0, !done.contains("verify") {
            done.insert("verify")
            games.verify(appID: appID)
        }
    }
}
#endif
