import SteamKit
import SwiftUI

/// Per-game screen: install, pause, resume, verify and delete, plus where the files are.
struct GameDetailView: View {
    let app: AppInfo
    @Environment(GameLibrary.self) private var games
    @Environment(SteamModel.self) private var steam
    @State private var confirmingDelete = false

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
                if let report = games.verifyReports[app.appID] {
                    Section("Last verify") { VerifyReportView(report: report) }
                }
                Section {
                    Button("Delete download", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
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
    }

    private func describe(_ problem: VerifyReport.Problem) -> String {
        switch problem {
        case .missing: "Missing"
        case let .wrongSize(expected, actual): "Size \(actual.formatted(.byteCount(style: .file))), expected \(expected.formatted(.byteCount(style: .file)))"
        case .modified: "Contents changed"
        }
    }
}
