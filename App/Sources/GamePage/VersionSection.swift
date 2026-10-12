#if os(iOS)
import SwiftUI

/// Which build of the game this is and what runs it: the Steam version (beta) to download,
/// the engine and its version, how it plays here, and Ren'Py's Phone Layout.
struct VersionSection: View {
    let game: LibraryGame
    let model: GamePageModel
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility
    @State private var branch = "public"
    @State private var phoneLayout = false

    private var appID: UInt32 { game.appID }
    private var record: GameRecord? {
        games.record(for: appID)
    }

    /// The engine: the downloaded game's, else what Steam's manifests say.
    private var engine: EngineMatch? { record?.engine ?? engineScans.result(for: appID)?.engine }
    /// "Python 3" for Ren'Py games (which runtime they get).
    private var python: String? { record?.engine?.details["python"].map { "Python \($0)" } }

    /// Before download: the Windows depots' size from the scan, else from PICS.
    private var downloadSize: UInt64? {
        if let size = engineScans.result(for: appID)?.installSize, size > 0 { return size }
        return game.estimatedSize
    }
    private var engineKnown: Bool { record != nil || engineScans.result(for: appID).map { $0.error == nil } == true }

    var body: some View {
        GamePageSection(title: "Version & Engine") {
            if let branches = game.branches, branches.count > 1 {
                GamePageRow {
                    LabeledContent("Version") {
                        Picker("Version", selection: $branch) {
                            ForEach(branches, id: \.name) { branch in
                                Text(GameText.branch(branch.name, of: game)).tag(branch.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            }
            if engineKnown {
                let playability = Playability(engine, appID: appID)
                GamePageValueRow(
                    title: "Engine",
                    value: GameText.engine(engine),
                    detail: playability == .playable ? python : GameText.playability(playability, engine: engine, appID: appID),
                    valueStyle: playability == .playable ? nil : .orange
                )
            }
            if record == nil, let size = downloadSize {
                GamePageValueRow(title: "Download size", value: size.formatted(.byteCount(style: .file)))
            }
            if record?.engine?.engine == "artemis" {
                // Artemis reads keyboard, mouse and touch only. (KiriKiri games take a
                // controller as their keyboard: see KiriKiriGameViewController.pad.)
                GamePageValueRow(title: "Controls", value: "Touch, keyboard and mouse")
            }
            if record?.engine?.engine == RenPyEngine.id {
                GamePageRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(isOn: $phoneLayout) { Label("Phone Layout", systemImage: "iphone") }
                        Text("Ren'Py's phone screens instead of the PC layout, for games that include them.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if record == nil {
                GamePageRow {
                    Button("Check Engine Again", systemImage: "magnifyingglass", action: checkEngine)
                        .disabled(!steam.isLoggedOn || engineScans.scanning == appID)
                }
            }
            GamePageValueRow(title: "Store", value: "Steam", detail: "App \(appID)")
        }
        .onAppear(perform: load)
        .onChange(of: games.branch(for: appID)) { _, current in branch = current }
        .onChange(of: branch) { _, picked in model.chooseBranch(picked, game: game, games: games) }
        .onChange(of: model.pendingBranch) { _, pending in
            // Asked and cancelled: the picker goes back to the version in use.
            if pending == nil { branch = games.branch(for: appID) }
        }
        .onChange(of: phoneLayout) { _, on in if on != model.phoneLayout { model.setPhoneLayout(on) } }
    }

    private func load() {
        branch = games.branch(for: appID)
        phoneLayout = model.phoneLayout
    }

    private func checkEngine() { engineScans.scan([appID], force: true) }
}
#endif
