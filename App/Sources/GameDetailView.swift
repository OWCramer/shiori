import SteamKit
import SwiftUI
import UniformTypeIdentifiers

/// The page for one game, in the style of the user's Tana app: hero artwork with the logo
/// over it, a dark backdrop tinted by the art, and the details floating on glass.
struct GameDetailView: View {
    /// The game as navigated to; `game` follows the live library, so artwork picks show at once.
    private let opened: LibraryGame
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @Environment(LibraryCuration.self) private var curation
    @Environment(EngineScanStore.self) private var engineScans
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmingDelete = false
    @State private var importingPatch = false
    @State private var confirmingRemovePatches = false
    @State private var patchFiles: [PatchStore.PatchFile] = []
    @State private var patchMessage: String?
    @State private var overscroll: CGFloat = 0
    @State private var phoneLayout = false
    @State private var choosingArtwork = false
    @State private var browsingArchives = false
    @Namespace private var glassNamespace

    init(game: LibraryGame) {
        opened = game
    }

    private var game: LibraryGame { steam.library.first { $0.appID == opened.appID } ?? opened }
    private var appID: UInt32 { opened.appID }
    private var folder: URL { games.folder(appID: appID, name: game.name) }
    private var status: GameLibrary.Status { games.status(for: appID) }
    private var record: GameRecord? { if case let .installed(record) = status { record } else { nil } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GameHeroHeader(game: game, subtitle: subtitle, overscroll: overscroll)
                actionRow
                progressCard
                playBlockerNote
                engineScanNote
                chips
                if let record { statTiles(record) }
                if record != nil {
                    GameSection(title: "Saves", systemImage: "icloud") { savesCard }
                    GameSection(title: "Patches", systemImage: "bandage") { patchesCard }
                    if let report = games.verifyReports[appID] {
                        GameSection(title: "Verify", systemImage: "checkmark.shield") {
                            VerifyReportView(report: report, patchCount: patchFiles.count).glassCard()
                        }
                    }
                    GameSection(title: "Files", systemImage: "folder") { filesCard }
                }
                detailsFooter
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 40)
        }
        .scrollOverscroll($overscroll)
        .ignoresSafeArea(edges: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background { GameBackdrop(game: game) }
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationTitle(game.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $browsingArchives) {
            ArchiveBrowserView(gameFolder: folder)
        }
        .sheet(isPresented: $choosingArtwork) {
            ArtworkPickerView(appID: appID)
                .environment(steam.artwork)
        }
        .onAppear {
            reloadPatches()
            phoneLayout = RenPyEngine.usesPhoneLayout(appID: appID)
            #if DEBUG
            // `-VNHubBrowseArchives YES` (with -VNHubOpenGame) opens the archive browser.
            if UserDefaults.standard.bool(forKey: "VNHubBrowseArchives") { browsingArchives = true }
            #endif
        }
        .task(id: steam.isLoggedOn) {
            if record == nil, steam.isLoggedOn { engineScans.scan([appID]) }
            if steam.isLoggedOn { await games.loadSteamCloudSupport(appID) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadPatches() } }
        .onChange(of: status) { reloadPatches() }
        .fileImporter(isPresented: $importingPatch, allowedContentTypes: [.zip, .folder, .item]) { importPatch($0) }
        .confirmationDialog("Remove all patches?", isPresented: $confirmingRemovePatches, titleVisibility: .visible) {
            Button("Remove \(patchFiles.count) patch files", role: .destructive) {
                try? PatchStore.removeAll(gameFolder: folder)
                reloadPatches()
            }
        } message: {
            Text("The game goes back to exactly what Steam delivered. Saves are kept.")
        }
        .confirmationDialog("Delete \(game.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete game files and saves", role: .destructive) { games.delete(appID: appID, name: game.name) }
        } message: {
            Text("This removes the game's folder, including any patches and saves in it.")
        }
    }

    // MARK: - Header

    /// Engine · size, or "Visual Novel" before it's downloaded.
    private var subtitle: String {
        var parts: [String] = []
        if let record {
            parts.append(engineDescription(record.engine))
            parts.append(record.sizeBytes.formatted(.byteCount(style: .file)))
        } else {
            if curation.isVisualNovel(game) { parts.append("Visual Novel") }
            if let size = game.estimatedSize { parts.append(size.formatted(.byteCount(style: .file))) }
        }
        return parts.joined(separator: " · ")
    }

    /// One prominent primary action for the game's state, and a circular menu.
    private var actionRow: some View {
        HStack(spacing: 12) {
            primaryAction
                .font(.headline)
                .buttonStyle(.glassProminent)

            Menu {
                moreActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 22, height: 22)
                    .padding(14)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 20)
    }

    @ViewBuilder private var primaryAction: some View {
        switch status {
        case .notInstalled:
            wideButton("Download", systemImage: "arrow.down.circle.fill", tint: .blue) { games.download(game) }
                .disabled(!steam.isLoggedOn)
        case .queued:
            wideButton("Queued", systemImage: "clock", tint: .gray) { games.pause(appID: appID) }
        case .preparing, .downloading:
            wideButton("Pause", systemImage: "pause.fill", tint: .orange) { games.pause(appID: appID) }
        case .paused, .failed:
            wideButton("Resume", systemImage: "arrow.down.circle.fill", tint: .blue) { games.resume(appID: appID, name: game.name) }
                .disabled(!steam.isLoggedOn)
        case .verifying:
            wideButton("Verifying…", systemImage: "checkmark.shield", tint: .gray) {}
                .disabled(true)
        case .installed:
            if let phase = games.launchPhase(for: appID) {
                Button {} label: {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(phase.label)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .tint(.green)
                .disabled(true)
            } else if games.playBlocker(appID: appID) == nil {
                wideButton("Play", systemImage: "play.fill", tint: .green) { games.play(appID: appID) }
            } else {
                wideButton("Not playable yet", systemImage: "exclamationmark.triangle", tint: .gray) {}
                    .disabled(true)
            }
        }
    }

    private func wideButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .tint(tint)
    }

    @ViewBuilder private var moreActions: some View {
        Button(curation.isVisualNovel(game) ? "Remove from Visual Novels" : "Add to Visual Novels",
               systemImage: curation.isVisualNovel(game) ? "eye.slash" : "plus.circle") {
            curation.toggle(game)
        }
        Button("Change Artwork…", systemImage: "photo.on.rectangle") { choosingArtwork = true }
        if record == nil {
            Button("Check Engine Again", systemImage: "magnifyingglass") { engineScans.scan([appID], force: true) }
                .disabled(!steam.isLoggedOn)
        }
        Divider()
        if record?.engine?.engine == RenPyEngine.id {
            Toggle(isOn: Binding(
                get: { phoneLayout },
                set: { phoneLayout = $0; RenPyEngine.setPhoneLayout($0, appID: appID) }
            )) {
                Label("Phone Layout", systemImage: "iphone")
            }
        }
        if record != nil {
            if record?.engine?.engine == "artemis" {
                Button("Browse Archives", systemImage: "archivebox") { browsingArchives = true }
            }
            Button("Verify Files", systemImage: "checkmark.shield") { games.verify(appID: appID) }
            Button("Import Patch…", systemImage: "square.and.arrow.down") { importingPatch = true }
            Button("Open Folder in Files", systemImage: "folder") { openInFiles() }
            if !patchFiles.isEmpty {
                Button("Remove All Patches", systemImage: "arrow.uturn.backward") { confirmingRemovePatches = true }
            }
            Divider()
            Button("Delete Download", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        } else if status != .notInstalled {
            Button("Delete Partial Download", systemImage: "trash", role: .destructive) { confirmingDelete = true }
        }
    }

    // MARK: - Status

    @ViewBuilder private var progressCard: some View {
        switch status {
        case .preparing:
            HStack(spacing: 10) {
                ProgressView()
                Text("Preparing download…").font(.subheadline)
            }
            .glassCard()
            .padding(.horizontal, 20)
        case let .downloading(progress):
            downloadProgress(progress, label: progress.phase == .finishing ? "Finishing…" : "Downloading")
        case let .paused(progress):
            if let progress { downloadProgress(progress, label: "Paused") }
        case .queued:
            Label("Waiting for the download ahead of it", systemImage: "clock")
                .font(.subheadline).foregroundStyle(.secondary)
                .glassCard()
                .padding(.horizontal, 20)
        case let .failed(message, _):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline).foregroundStyle(.red)
                .glassCard()
                .padding(.horizontal, 20)
        case let .verifying(progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Verifying files").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(progress.fraction.formatted(.percent.precision(.fractionLength(0)))).font(.subheadline.monospacedDigit())
                }
                GlassProgressBar(fraction: progress.fraction, tint: .teal)
            }
            .glassCard()
            .padding(.horizontal, 20)
        default:
            EmptyView()
        }
    }

    private func downloadProgress(_ progress: DownloadProgress, label: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label).font(.subheadline.weight(.semibold))
                Spacer()
                Text(progress.fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.subheadline.monospacedDigit())
            }
            GlassProgressBar(fraction: progress.fraction, tint: .blue)
            Text("\(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .glassCard()
        .padding(.horizontal, 20)
    }

    /// Before download: the engine read from Steam's manifests and whether it'll play.
    @ViewBuilder private var engineScanNote: some View {
        if record == nil {
            if let scan = engineScans.result(for: appID) {
                if let error = scan.error {
                    Label("Couldn't check the engine: \(error)", systemImage: "questionmark.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                } else {
                    let playability = Playability(scan.engine)
                    VStack(alignment: .leading, spacing: 4) {
                        Label(engineLine(scan), systemImage: playability == .playable ? "checkmark.circle.fill" : "exclamationmark.triangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(playability == .playable ? .green : .orange)
                        Text(playabilityText(playability)).font(.caption).foregroundStyle(.secondary)
                    }
                    .glassCard()
                    .padding(.horizontal, 20)
                }
            } else if engineScans.scanning == appID {
                Label("Checking the engine…", systemImage: "magnifyingglass").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
        }
    }

    private func engineLine(_ scan: EngineScanResult) -> String {
        let engine = engineDescription(scan.engine)
        return scan.installSize > 0 ? "\(engine) · \(scan.installSize.formatted(.byteCount(style: .file)))" : engine
    }

    private func playabilityText(_ playability: Playability) -> String {
        switch playability {
        case .playable: "Playable in Shiori."
        case let .needsRuntime(reason): reason
        case let .unsupportedEngine(name): "\(name) games can be downloaded and patched, but not played in Shiori yet."
        case .unknownEngine: "Shiori doesn't recognise this game's engine."
        }
    }

    @ViewBuilder private var playBlockerNote: some View {
        if record != nil, let blocker = games.playBlocker(appID: appID) {
            Label(blocker, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
    }

    /// Artemis saves aren't the PC's format. KiriKiri's are, and sync when the game's cloud
    /// rules name its savedata folder (not when it writes the cloud through Steam's API).
    private var engineUsesSteamCloud: Bool {
        switch record?.engine?.engine {
        case "artemis": false
        case "kirikiri": games.steamCloudMapped[appID] == true
        default: true
        }
    }

    /// The game has no Steam Cloud at all, or Shiori can't use it for this engine yet.
    private var steamCloudChip: String? {
        if games.steamCloudSupport[appID] == false { return "No Steam Cloud" }
        if !engineUsesSteamCloud { return "No Steam Cloud yet" }
        return nil
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    if curation.isVisualNovel(game) {
                        GlassChip("Visual Novel", systemImage: "book.pages", tint: .pink)
                            .glassEffectID("vn", in: glassNamespace)
                    }
                    if let engine = record?.engine {
                        GlassChip(EngineDetection.displayName(for: engine.engine), systemImage: "gearshape.2",
                                  tint: [RenPyEngine.id, "artemis", "kirikiri"].contains(engine.engine) ? .green : .orange)
                            .glassEffectID("engine", in: glassNamespace)
                        // Artemis reads keyboard, mouse and touch only; Shiori drives KiriKiri
                        // games by touch.
                        if engine.engine == "artemis" || engine.engine == "kirikiri" {
                            GlassChip("Touch only", systemImage: "hand.tap", tint: .gray)
                                .glassEffectID("controls", in: glassNamespace)
                        }
                    }
                    if let label = steamCloudChip {
                        GlassChip(label, systemImage: "cloud.slash", tint: .gray)
                            .glassEffectID("steamcloud", in: glassNamespace)
                    }
                    if !patchFiles.isEmpty {
                        GlassChip("Patched", systemImage: "bandage", tint: .orange)
                            .glassEffectID("patched", in: glassNamespace)
                    }
                    if let report = games.verifyReports[appID] {
                        GlassChip(report.isClean ? "Verified" : "Files differ",
                                  systemImage: report.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle",
                                  tint: report.isClean ? .teal : .yellow)
                            .glassEffectID("verify", in: glassNamespace)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .scrollIndicators(.hidden)
    }

    /// Two tiles per row; a grid always fits the width it's given.
    private func statTiles(_ record: GameRecord) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            StatTile(value: record.sizeBytes.formatted(.byteCount(style: .file)), label: "On this \(UIDevice.current.localizedModel)",
                     systemImage: "internaldrive", tint: .blue)
            StatTile(value: record.engine?.version.map { shortVersion($0) } ?? "—",
                     label: record.engine.map { "\(EngineDetection.displayName(for: $0.engine)) version" } ?? "Engine not recognised",
                     systemImage: "gearshape.2", tint: .green)
            StatTile(value: "\(patchFiles.count)", label: patchFiles.count == 1 ? "Patch file" : "Patch files",
                     systemImage: "bandage", tint: .orange)
            StatTile(value: "\(saveCount)", label: saveCount == 1 ? "Save" : "Saves",
                     systemImage: "square.and.arrow.down.on.square", tint: .purple)
        }
        .padding(.horizontal, 20)
    }

    private func shortVersion(_ version: String) -> String {
        version.split(separator: ".").prefix(3).joined(separator: ".")
    }

    private var saveCount: Int {
        let saves = folder.appendingPathComponent("saves")
        return ((try? FileManager.default.contentsOfDirectory(atPath: saves.path)) ?? []).filter { $0.hasSuffix(".save") }.count
    }

    // MARK: - Cards

    private var patchesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if patchFiles.isEmpty {
                Text("No patches. Files in this game's patch/game folder replace or add to its game folder, and are picked up the next time you play.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(patchFiles.prefix(20)) { file in
                HStack(alignment: .firstTextBaseline) {
                    Text(file.path).font(.footnote.monospaced()).lineLimit(2)
                    Spacer(minLength: 8)
                    if file.overridesBase {
                        Text("Replaces").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
            }
            if patchFiles.count > 20 {
                Text("and \(patchFiles.count - 20) more").font(.caption).foregroundStyle(.secondary)
            }
            if let patchMessage {
                Text(patchMessage).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("Import", systemImage: "square.and.arrow.down") { importingPatch = true }
                    .buttonStyle(.glass)
                if !patchFiles.isEmpty {
                    Button("Remove All", systemImage: "arrow.uturn.backward", role: .destructive) { confirmingRemovePatches = true }
                        .buttonStyle(.glass)
                        .tint(.red)
                }
            }
            .font(.subheadline)
            .padding(.top, 4)
        }
        .glassCard()
    }

    @ViewBuilder private var steamCloudSection: some View {
        Toggle(isOn: Binding(
            get: { games.isSteamCloudEnabled(appID) },
            set: { games.setSteamCloud(appID, enabled: $0) }
        )) {
            Label("Steam Cloud", systemImage: "cloud")
        }
        .font(.subheadline)
        if games.isSteamCloudEnabled(appID) {
            statusLine(games.steamCloud[appID])
            Text(!SteamCloudSync.uploadsEnabled
                ? "Downloads saves from your PC before you play. Uploading is off; turn it on in Settings."
                : games.canUploadSteamCloud(appID)
                ? "Downloads saves from your PC before you play and uploads newer ones when you stop, backing up the cloud copy first."
                : "Downloads saves from your PC before you play. Saves made here stay on this device: Shiori runs this game on a newer Ren'Py than your PC, which might not load them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if games.steamCloudSupport[appID] == false {
                Label("No Steam Cloud", systemImage: "cloud.slash")
                    .font(.subheadline)
                Text("This game doesn't use Steam Cloud on PC, so there are no cloud saves to share with it. iCloud keeps saves made here in step between your devices.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !engineUsesSteamCloud {
                Label("Steam Cloud: not supported yet", systemImage: "cloud.slash")
                    .font(.subheadline)
                Text("Shiori can't read or write this engine's PC saves yet, so saves made here don't go to or come from your PC through Steam Cloud. iCloud keeps them in step between your devices.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                steamCloudSection
            }

            Divider().opacity(0.4)

            Toggle(isOn: Binding(
                get: { games.isCloudSaveEnabled(appID) },
                set: { games.setCloudSave(appID, enabled: $0) }
            )) {
                Label("Sync with iCloud", systemImage: "icloud")
            }
            .font(.subheadline)

            if games.isCloudSaveEnabled(appID) {
                statusLine(games.saveSync[appID])
            }
            Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await games.syncAllSaveLocations(appID: appID) }
            }
            .buttonStyle(.glass)
            .font(.subheadline)
            .disabled(games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing)
            Text("Saves download from iCloud before you play and upload when you stop. If two devices changed the same save, the older copy is kept in saves/conflicts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .glassCard()
    }

    @ViewBuilder private func statusLine(_ state: GameLibrary.SaveSyncState?) -> some View {
        switch state ?? .idle {
        case .idle:
            Text("Not synced yet").font(.caption).foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…").font(.caption) }
        case let .synced(date, summary):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.caption.weight(.semibold))
                Text(date, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
            }
        case .unavailable:
            Label("iCloud unavailable", systemImage: "icloud.slash").font(.caption).foregroundStyle(.orange)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.icloud").font(.caption).foregroundStyle(.red).lineLimit(3)
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("On My \(UIDevice.current.localizedModel) › Shiori › Games › \(folder.lastPathComponent)")
                .font(.subheadline)
            Text("base holds what Steam delivered, patch your changes, saves the game's saves.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open in Files", systemImage: "folder") { openInFiles() }
                .buttonStyle(.glass)
                .font(.subheadline)
        }
        .glassCard()
    }

    private var detailsFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            footerRow("App ID", String(appID))
            if let record {
                footerRow("Downloaded", record.installedAt.formatted(date: .abbreviated, time: .omitted))
                footerRow("Depots", record.depots.map { String($0.depotID) }.joined(separator: ", "))
                if let python = record.engine?.details["python"] { footerRow("Python", python) }
            } else if let size = game.estimatedSize {
                footerRow("Size (approx.)", size.formatted(.byteCount(style: .file)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    private func footerRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.primary).multilineTextAlignment(.trailing)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if record != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Open in Files", systemImage: "folder") { openInFiles() }
            }
        }
    }

    // MARK: - Actions

    private func reloadPatches() {
        patchFiles = PatchStore.list(gameFolder: folder)
    }

    private func importPatch(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let count = try PatchStore.importItem(at: url, gameFolder: folder)
            patchMessage = "Imported \(count) file\(count == 1 ? "" : "s") from \(url.lastPathComponent)."
        } catch {
            patchMessage = "Couldn't import the patch: \(error.localizedDescription)"
        }
        reloadPatches()
    }

    /// The Files app opens folders in our Documents through the shareddocuments scheme.
    private func openInFiles() {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = folder.path
        if let url = components.url { UIApplication.shared.open(url) }
    }

    private func engineDescription(_ engine: EngineMatch?) -> String {
        guard let engine else { return "Engine not recognised" }
        let name = EngineDetection.displayName(for: engine.engine)
        return engine.version.map { "\(name) \(shortVersion($0))" } ?? name
    }
}

private struct VerifyReportView: View {
    let report: VerifyReport
    let patchCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.isClean {
                Label("All \(report.checkedFiles) files match Steam", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.teal)
            } else {
                Label("\(report.problems.count) of \(report.checkedFiles) files differ from Steam", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                ForEach(report.problems.keys.sorted().prefix(20), id: \.self) { path in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path).font(.footnote.monospaced())
                        Text(describe(report.problems[path]!)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !report.extraFiles.isEmpty {
                Text("\(report.extraFiles.count) extra files in base that aren't from Steam").font(.caption).foregroundStyle(.secondary)
            }
            if patchCount > 0 {
                Text("\(patchCount) patch file\(patchCount == 1 ? "" : "s") are layered on top; they live in patch/, not in the Steam files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private func describe(_ problem: VerifyReport.Problem) -> String {
        switch problem {
        case .missing: "Missing"
        case let .wrongSize(expected, actual): "Size \(actual.formatted(.byteCount(style: .file))), expected \(expected.formatted(.byteCount(style: .file)))"
        case .modified: "Contents changed"
        }
    }
}
