import SteamKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-game screen: install, pause, resume, verify and delete, plus where the files are.
struct GameDetailView: View {
    let app: AppInfo
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @State private var confirmingDelete = false
    @State private var importingPatch = false
    @State private var confirmingRemovePatches = false
    @State private var patchFiles: [PatchStore.PatchFile] = []
    @State private var patchMessage: String?
    @Environment(\.scenePhase) private var scenePhase

    private var folder: URL { games.folder(appID: app.appID, name: app.name) }

    private var status: GameLibrary.Status { games.status(for: app.appID) }

    var body: some View {
        List {
            Section {
                LabeledContent("App ID", value: String(app.appID))
                if case .installed = status {} else if let size = estimatedSize {
                    LabeledContent("Size (approx.)", value: size.formatted(.byteCount(style: .file)))
                }
            }

            Section { statusContent }

            if case let .installed(record) = status {
                Section("Installed") {
                    LabeledContent("Engine", value: engineDescription(record.engine))
                    if let python = record.engine?.details["python"] {
                        LabeledContent("Python", value: python)
                    }
                    LabeledContent("Size", value: record.sizeBytes.formatted(.byteCount(style: .file)))
                    LabeledContent("Folder", value: "On My \(UIDevice.current.localizedModel) › VN Hub › Games › \(games.folder(appID: app.appID, name: app.name).lastPathComponent)")
                        .font(.footnote)
                }
                patchesSection
                if let report = games.verifyReports[app.appID] {
                    Section("Last verify") { VerifyReportView(report: report, patchCount: patchFiles.count) }
                }
                Section {
                    Button("Delete download", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadPatches)
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadPatches() } }
        .onChange(of: games.status(for: app.appID)) { reloadPatches() }
        .fileImporter(isPresented: $importingPatch, allowedContentTypes: [.zip, .folder, .item]) { result in
            importPatch(result)
        }
        .confirmationDialog("Remove all patches?", isPresented: $confirmingRemovePatches, titleVisibility: .visible) {
            Button("Remove \(patchFiles.count) patch files", role: .destructive) {
                try? PatchStore.removeAll(gameFolder: folder)
                reloadPatches()
            }
        } message: {
            Text("The game goes back to exactly what Steam delivered. Saves are kept.")
        }
        .confirmationDialog("Delete \(app.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete game files and saves", role: .destructive) { games.delete(appID: app.appID, name: app.name) }
        } message: {
            Text("This removes the game's folder, including any patches and saves in it.")
        }
    }

    @ViewBuilder private var statusContent: some View {
        switch status {
        case .notInstalled:
            Button("Download") { games.download(app) }
                .disabled(!steam.isLoggedOn)
        case .preparing:
            HStack {
                ProgressView()
                Text("Preparing download…").padding(.leading, 8)
            }
            Button("Pause") { games.pause(appID: app.appID) }
        case let .downloading(progress):
            DownloadProgressView(progress: progress)
            Button("Pause") { games.pause(appID: app.appID) }
        case let .paused(progress):
            if let progress { DownloadProgressView(progress: progress) }
            Text("Paused").foregroundStyle(.secondary)
            Button("Resume") { games.resume(appID: app.appID, name: app.name) }
                .disabled(!steam.isLoggedOn)
            Button("Delete partial download", role: .destructive) { confirmingDelete = true }
        case let .verifying(progress):
            ProgressView(value: progress.fraction) {
                Text("Verifying files…")
            } currentValueLabel: {
                Text("\(progress.checkedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file)))")
            }
        case .installed:
            if let blocker = games.playBlocker(appID: app.appID) {
                Label(blocker, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                Button {
                    games.play(appID: app.appID)
                } label: {
                    Label("Play", systemImage: "play.fill").font(.headline)
                }
            }
            Button("Verify files") { games.verify(appID: app.appID) }
        case let .failed(message, canResume):
            Text(message).foregroundStyle(.red)
            if canResume {
                Button("Resume") { games.resume(appID: app.appID, name: app.name) }
                    .disabled(!steam.isLoggedOn)
            }
        }
    }

    @ViewBuilder private var patchesSection: some View {
        Section {
            if patchFiles.isEmpty {
                Text("No patches. Files in the game's patch/game folder replace or add to its game folder.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(patchFiles.prefix(30)) { file in
                HStack {
                    Text(file.path).font(.footnote.monospaced()).lineLimit(2)
                    Spacer()
                    // Only loose base files can be checked here; a patch may also replace a
                    // file packed inside one of the game's archives.
                    if file.overridesBase {
                        Text("Replaces").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if patchFiles.count > 30 {
                Text("and \(patchFiles.count - 30) more").font(.footnote).foregroundStyle(.secondary)
            }
            if let patchMessage {
                Text(patchMessage).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Import patch…", systemImage: "square.and.arrow.down") { importingPatch = true }
            Button("Open folder in Files", systemImage: "folder") { openInFiles() }
            if !patchFiles.isEmpty {
                Button("Remove all patches", systemImage: "arrow.uturn.backward", role: .destructive) {
                    confirmingRemovePatches = true
                }
            }
        } header: {
            Text("Patches")
        }
    }

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

    private var estimatedSize: UInt64? {
        // Base-game Windows depots' sizes from PICS; DLC and ownership are settled when downloading.
        let depots = DepotSelection.windowsDepots(of: app, owned: Set(app.keyValues["depots"]?.children.compactMap { UInt32($0.name) } ?? []))
            .filter { app.keyValues[path: "depots", String($0.depotID), "dlcappid"] == nil }
        let total = depots.reduce(0) { $0 + $1.size }
        return total > 0 ? total : nil
    }

    private func engineDescription(_ engine: EngineMatch?) -> String {
        guard let engine else { return "Not recognised" }
        let name = EngineDetection.displayName(for: engine.engine)
        return engine.version.map { "\(name) \($0)" } ?? name
    }
}

private struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        ProgressView(value: progress.fraction) {
            Text(progress.phase == .finishing ? "Finishing…" : "Downloading…")
        } currentValueLabel: {
            Text("\(progress.completedBytes.formatted(.byteCount(style: .file))) of \(progress.totalBytes.formatted(.byteCount(style: .file))) · \(progress.fraction.formatted(.percent.precision(.fractionLength(0))))")
                .monospacedDigit()
        }
    }
}

private struct VerifyReportView: View {
    let report: VerifyReport
    let patchCount: Int

    var body: some View {
        if report.isClean {
            Label("All \(report.checkedFiles) files match Steam", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        } else {
            Label("\(report.problems.count) of \(report.checkedFiles) files differ from Steam", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            ForEach(report.problems.keys.sorted().prefix(20), id: \.self) { path in
                VStack(alignment: .leading) {
                    Text(path).font(.footnote.monospaced())
                    Text(describe(report.problems[path]!)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if !report.extraFiles.isEmpty {
            Text("\(report.extraFiles.count) extra files not from Steam").foregroundStyle(.secondary)
        }
        if patchCount > 0 {
            Text("\(patchCount) patch file\(patchCount == 1 ? "" : "s") layered on top (see Patches); they aren't part of the Steam files.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func describe(_ problem: VerifyReport.Problem) -> String {
        switch problem {
        case .missing: "Missing"
        case let .wrongSize(expected, actual): "Size \(actual.formatted(.byteCount(style: .file))), expected \(expected.formatted(.byteCount(style: .file)))"
        case .modified: "Contents changed"
        }
    }
}
