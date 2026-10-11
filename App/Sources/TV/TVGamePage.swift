#if os(tvOS)
import SwiftUI

/// A game's page on Apple TV (design A): hero art behind, the logo, what it runs on and a
/// column of actions at the left, and tiles about its saves and storage along the bottom.
struct TVGamePage: View {
    let game: LibraryGame
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(CompatibilityStore.self) private var compatibility
    @State private var showingMore = false
    @State private var confirmingDelete = false
    @State private var showingPatches = false

    private var appID: UInt32 { game.appID }
    private var status: GameLibrary.Status { games.status(for: appID) }
    private var record: GameRecord? { if case let .installed(record) = status { record } else { nil } }
    private var engine: EngineMatch? { record?.engine ?? engineScans.result(for: appID)?.engine }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TVBackdrop(game: game)
            VStack(alignment: .leading, spacing: 30) {
                TVGameTitle(game: game, maxWidth: 700, maxHeight: 240)
                chips
                Text(TVGameText.statusLine(game, games: games))
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.85))
                if case let .downloading(progress) = status {
                    ProgressView(value: progress.fraction).frame(maxWidth: 560)
                }
                actions
                Spacer(minLength: 20)
                tiles
            }
        }
        .environment(\.colorScheme, .dark)
        .confirmationDialog(game.name, isPresented: $showingMore) { moreActions }
        .sheet(isPresented: $showingPatches) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Patches for \(game.name)").font(.title2.bold())
                    PatchListSection(appID: appID, gameFolder: games.folder(appID: appID, name: game.name)) {}
                    Text("Patches install into this game's patch folder; Remove puts the game back as Steam delivered it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(60)
                .frame(maxWidth: 1200, alignment: .leading)
            }
        }
        .confirmationDialog("Delete \(game.name)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { games.delete(appID: appID, name: game.name) }
        } message: {
            Text("Removes the game from this Apple TV, with its patches and the saves kept here. Saves synced to Steam Cloud or iCloud stay there.")
        }
    }

    // MARK: - Header

    private var chips: some View {
        HStack(spacing: 14) {
            if engine != nil { chip(Playability.badge(engine, appID: appID), tint: Playability(engine) == .playable ? .green : nil) }
            if let entry = compatibility.entry(for: appID)?.entry { chip(entry.status.rawValue.capitalized, tint: entry.status == .unsupported ? .red : nil) }
        }
    }

    private func chip(_ text: String, tint: Color?) -> some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background((tint ?? .white).opacity(tint == nil ? 0.16 : 0.32), in: .capsule)
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 18) {
            let primary = TVGameText.primaryAction(game, games: games, steam: steam)
            Button {
                primary.run()
            } label: {
                Label(primary.title, systemImage: primary.symbol)
                    .frame(width: 520, alignment: .leading)
            }
            .disabled(!primary.isEnabled)
            if record != nil {
                Button {
                    Task { await games.syncAllSaveLocations(appID: appID) }
                } label: {
                    Label("Sync Saves", systemImage: "arrow.triangle.2.circlepath")
                        .frame(width: 520, alignment: .leading)
                }
                .disabled(games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing)
            }
            Button {
                showingMore = true
            } label: {
                Label("More…", systemImage: "ellipsis")
                    .frame(width: 520, alignment: .leading)
            }
            if !steam.isLoggedOn, let reason = steam.offlineReason, record == nil {
                Text(reason).font(.callout).foregroundStyle(.secondary)
            }
        }
        .focusSection()
    }

    @ViewBuilder private var moreActions: some View {
        if record != nil {
            // Apple TV has no Files app: the patch list is how patches get here.
            Button("Patches") { showingPatches = true }
            Button("Verify Files") { games.verify(appID: appID) }
        }
        switch status {
        case .queued, .preparing, .downloading:
            Button("Pause Download") { games.pause(appID: appID) }
        case .paused, .failed:
            Button("Resume Download") { games.resume(appID: appID, name: game.name) }
        default:
            EmptyView()
        }
        Button(curation.isVisualNovel(game) ? "Remove from Visual Novels" : "Add to Visual Novels") { curation.toggle(game) }
        if record == nil {
            Button("Check Engine Again") { engineScans.scan([appID], force: true) }
        }
        if status != .notInstalled {
            Button("Delete…", role: .destructive) { confirmingDelete = true }
        }
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 24) {
            tile("Runs on", engineLine)
            tile("iCloud", syncText(games.saveSync[appID], none: "Not synced yet", unavailable: "Not on Apple TV yet"))
            tile("Steam Cloud", syncText(games.steamCloud[appID], none: games.steamCloudSupport[appID] == false ? "Not used by this game" : "Not synced yet"))
            tile("Storage", record == nil ? "Not downloaded" : "On this Apple TV")
        }
    }

    private var engineLine: String {
        guard let engine else { return "Not checked yet" }
        // "Ren'Py 8.1.3" rather than the badge and the full build number side by side.
        guard let version = engine.version else { return Playability.badge(engine) }
        let short = version.split(separator: ".").prefix(3).joined(separator: ".")
        return "\(EngineDetection.displayName(for: engine.engine)) \(short)"
    }

    private func syncText(_ state: GameLibrary.SaveSyncState?, none: String, unavailable: String = "Unavailable") -> String {
        switch state ?? .idle {
        case .idle: none
        case .syncing: "Syncing…"
        case let .synced(date, summary): "\(summary) · \(date.formatted(.relative(presentation: .named)))"
        case .unavailable: unavailable
        case let .failed(message): message
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.65))
            Text(value).font(.callout.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .padding(24)
        .background(.white.opacity(0.1), in: .rect(cornerRadius: 22))
    }
}
#endif
