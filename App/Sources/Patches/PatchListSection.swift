import SteamKit
import SwiftUI

/// The top of a game's Patches card: its Steam DLC, and the patches the public patch list
/// knows for it, each with what it is, who made it and where it's from (linked), and Install,
/// Update or Remove. Before the game is downloaded the list is shown too, and Install queues a
/// patch to install when the download finishes.
struct PatchListSection: View {
    let appID: UInt32
    let gameFolder: URL
    /// Called after a patch is installed or removed, so the card's file list refreshes.
    let onChange: () -> Void
    /// Told whether the section has anything to show (DLC or patches), so a host can
    /// collapse its row when it's empty.
    var onContentChange: (Bool) -> Void = { _ in }

    @Environment(PatchListStore.self) private var patchList
    @Environment(PatchInstaller.self) private var installer
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(\.openURL) private var openURL
    @State private var allDLCs: [DLCInfo]?
    /// The question being asked: install (or update) a patch, or remove it. One dialog, since
    /// SwiftUI drops a second confirmationDialog on the same view.
    @State private var prompt: Prompt?

    private enum Prompt: Identifiable {
        case install(PatchListStore.Patch)
        /// Install once the game is downloaded.
        case queue(PatchListStore.Patch)
        case remove(PatchListStore.Patch)
        var patch: PatchListStore.Patch { switch self { case let .install(p), let .queue(p), let .remove(p): p } }
        var id: String {
            switch self {
            case let .install(p): "i-\(p.id)"
            case let .queue(p): "q-\(p.id)"
            case let .remove(p): "r-\(p.id)"
            }
        }
    }

    /// The listed patches the account's store preferences allow (18+ ones only with adult content on).
    private var patches: [PatchListStore.Patch] { patchList.patches(for: appID, allowingAdult: steam.allowsAdultContent) }
    /// The game's DLC the account's store preferences allow, by Steam's content descriptors.
    private var dlcs: [DLCInfo]? { allDLCs?.filter { steam.allows(contentDescriptors: $0.contentDescriptors) } }
    private var hasContent: Bool { !(dlcs ?? []).isEmpty || !patches.isEmpty }
    private var record: GameRecord? { games.record(for: appID) }
    /// Patches install into a downloaded game; before that they're queued.
    private var gameInstalled: Bool { record != nil }
    private var libraryGame: LibraryGame? { steam.library.first { $0.appID == appID } }

    var body: some View {
        let _ = RenderProbe.hit("PatchListSection")
        VStack(alignment: .leading, spacing: 14) {
            if let dlcs, !dlcs.isEmpty { dlcList(dlcs) }
            if !patches.isEmpty {
                Text("From the patch list").font(.subheadline.weight(.semibold))
                ForEach(patches) { patch in row(patch) }
                Link(destination: PatchListStore.repository) {
                    Label("About the patch list", systemImage: "arrow.up.right.square")
                }
                .font(.caption)
            }
        }
        .task(id: appID) {
            installer.load(appID: appID, gameFolder: gameFolder)
            await patchList.load(appID: appID)
        }
        .task(id: gameInstalled) {
            // Patches queued for a download that finished while their hook couldn't run.
            if gameInstalled, installer.queued[appID] != nil { installer.installQueued(appID: appID, gameFolder: gameFolder) }
        }
        .task(id: steam.isLoggedOn) {
            guard steam.isLoggedOn, allDLCs == nil else { return }
            allDLCs = try? await steam.session.dlcs(appID: appID)
        }
        .onChange(of: installer.installed[appID]) { onChange() }
        .onChange(of: hasContent, initial: true) { _, has in onContentChange(has) }
        .alert(promptTitle, isPresented: Binding(
            get: { prompt != nil }, set: { if !$0 { prompt = nil } }
        ), presenting: prompt) { prompt in
            switch prompt {
            case let .install(patch):
                Button(installedVersion(patch) == nil ? "Download and Install" : "Update") {
                    installer.install(patch, appID: appID, gameFolder: gameFolder)
                }
            case let .queue(patch):
                if games.isOnDevice(appID) {
                    Button("Install After Download") { installer.enqueue(patch, appID: appID) }
                } else if let game = libraryGame {
                    Button("Download Game and Install") {
                        installer.enqueue(patch, appID: appID)
                        games.download(game)
                    }
                }
            case let .remove(patch):
                Button("Remove", role: .destructive) {
                    try? installer.remove(patch.id, appID: appID, gameFolder: gameFolder)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { prompt in
            switch prompt {
            case let .install(patch): Text(confirmationMessage(patch))
            case let .queue(patch): Text("Installs after the game downloads. " + confirmationMessage(patch))
            case .remove: Text("Saves and other patches stay.")
            }
        }
    }

    private var promptTitle: String {
        switch prompt {
        case let .install(patch), let .queue(patch): "Install \(patch.name)?"
        case let .remove(patch): "Remove \(patch.name)?"
        case nil: ""
        }
    }

    // MARK: Steam DLC

    @ViewBuilder private func dlcList(_ dlcs: [DLCInfo]) -> some View {
        Text("Steam DLC").font(.subheadline.weight(.semibold))
        ForEach(dlcs) { dlc in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(dlc.name).font(.subheadline)
                    Text(dlcStatus(dlc)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if dlc.owned, !dlc.depotIDs.isEmpty, !isInstalled(dlc) {
                    Button("Download") {
                        if let game = steam.library.first(where: { $0.appID == appID }) { games.download(game) }
                    }
                    .patchButtonStyle()
                    .font(.caption)
                } else if dlc.owned {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal)
                }
            }
        }
    }

    private func isInstalled(_ dlc: DLCInfo) -> Bool {
        let installed = Set(record?.depots.map(\.depotID) ?? [])
        return dlc.depotIDs.contains { installed.contains($0) }
    }

    private func dlcStatus(_ dlc: DLCInfo) -> String {
        guard dlc.owned else { return "Not owned" }
        if dlc.depotIDs.isEmpty { return "Owned · no files of its own" }
        return isInstalled(dlc) ? "Owned · installed with the game" : "Owned · not downloaded"
    }

    // MARK: Patch list

    private func installedVersion(_ patch: PatchListStore.Patch) -> PatchInstaller.InstalledPatch? {
        installer.installedPatch(patch.id, appID: appID)
    }

    @ViewBuilder private func row(_ patch: PatchListStore.Patch) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(patch.name).font(.subheadline.weight(.medium))
                    byline(patch).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action(patch)
            }
            badges(patch)
            if let job = installer.jobs[appID], job.patchID == patch.id { PatchJobLine(job: job, appID: appID) }
            if let notes = patch.notes, !notes.isEmpty {
                #if os(tvOS)
                Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                #else
                DisclosureGroup("Notes") {
                    Text(notes).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
                #endif
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private func action(_ patch: PatchListStore.Patch) -> some View {
        let busy = installer.jobs[appID] != nil && installer.jobs[appID]?.isFailure == false
        if let job = installer.jobs[appID], job.patchID == patch.id, !job.isFailure {
            Button("Cancel") { installer.cancel(appID: appID) }
                .patchButtonStyle().font(.caption)
        } else if !gameInstalled, patch.isDownloadable {
            if installer.isQueued(patch.id, appID: appID) {
                Menu {
                    Button("Remove from Queue", systemImage: "xmark", role: .destructive) {
                        installer.dequeue(patch.id, appID: appID)
                    }
                } label: {
                    Label("Queued", systemImage: "clock")
                }
                .patchButtonStyle().font(.caption)
            } else if games.isOnDevice(appID) || libraryGame != nil {
                Button("Install", systemImage: "arrow.down.circle") { prompt = .queue(patch) }
                    .patchButtonStyle().font(.caption)
            }
        } else if let installed = installedVersion(patch) {
            Menu {
                if installed.fingerprint != patch.fingerprint, patch.isDownloadable {
                    Button("Update", systemImage: "arrow.down.circle") { prompt = .install(patch) }
                }
                Button("Remove", systemImage: "trash", role: .destructive) { prompt = .remove(patch) }
            } label: {
                Label(installed.fingerprint != patch.fingerprint && patch.isDownloadable ? "Update" : "Installed",
                      systemImage: installed.fingerprint != patch.fingerprint && patch.isDownloadable ? "arrow.down.circle" : "checkmark.circle.fill")
            }
            .patchButtonStyle().font(.caption)
        } else if patch.isDownloadable {
            Button("Install", systemImage: "arrow.down.circle") { prompt = .install(patch) }
                .patchButtonStyle().font(.caption)
                .disabled(busy)
        } else if let dlc = patch.files.first?.dlc, dlcs?.first(where: { $0.appID == dlc })?.owned == true {
            Label("Owned", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.teal)
        } else if let link = externalLink(patch) {
            Button("Open", systemImage: "arrow.up.right") { openURL(link) }
                .patchButtonStyle().font(.caption)
        }
    }

    private func badges(_ patch: PatchListStore.Patch) -> some View {
        HStack(spacing: 6) {
            badge(patch.official ? "Official" : "Community", tint: patch.official ? .teal : .purple)
            if patch.adult { badge("18+", tint: .pink) }
            if patch.verified != nil {
                badge("Works", tint: .green)
            } else {
                badge("Untested", tint: .gray)
            }
            if patch.status == "dead" { badge("Link down", tint: .red) }
            if let size = patch.totalSize, size > 0 {
                Text(size.formatted(.byteCount(style: .file))).font(.caption2).foregroundStyle(.secondary)
            }
            let languages = patch.languages.filter { $0 != "en" }
            if !languages.isEmpty {
                Text(languages.map(languageName).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.22), in: Capsule())
            .foregroundStyle(tint)
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// Who made the patch and where the list found it ("Winged Cloud · via uncensorpat.ch"): the
    /// maker linked to its own page when the list knows it, the site to the patch's page there.
    private func byline(_ patch: PatchListStore.Patch) -> Text {
        let site = siteName(patch.source)
        let showsMaker = !patch.by.isEmpty && !site.localizedCaseInsensitiveContains(patch.by)
            && !patch.by.localizedCaseInsensitiveContains(site)
        var line = AttributedString()
        if showsMaker {
            var maker = AttributedString(patch.by)
            #if !os(tvOS)
            maker.link = patch.source.originURL
            #endif
            line += maker
            line += AttributedString(" · ")
        }
        var from = AttributedString(site)
        #if !os(tvOS)
        from.link = patch.source.pageURL
        #endif
        line += AttributedString("via ")
        line += from
        return Text(line)
    }

    private func siteName(_ source: PatchListStore.Patch.Source) -> String {
        switch source.site {
        case "nekonyan": "NekoNyan's patch page"
        case "saikey": "Saikey Studios"
        case "kagami": "Kagami Games' patch page"
        case "uncensorpatch": "uncensorpat.ch"
        case "patchmoe": "patch.moe"
        case "vndb": "VNDB"
        case "wingedcloud": "Winged Cloud's Patreon"
        case "denpasoft": "Denpasoft"
        default:
            source.pageURL?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "the patch list"
        }
    }

    /// A patch Shiori can't download itself (a shop's or Steam's product page, a page that needs
    /// a browser, a Windows installer): Open takes the link to Safari, out of the app.
    private func externalLink(_ patch: PatchListStore.Patch) -> URL? {
        guard let file = patch.files.first, let url = URL(string: file.url),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        if file.host == "steam", let dlc = file.dlc, dlcs?.first(where: { $0.appID == dlc })?.owned == true { return nil }
        if patch.status == "unsupported" || file.installer == true { return patch.source.pageURL ?? url }
        return url
    }

    private func confirmationMessage(_ patch: PatchListStore.Patch) -> String {
        var parts: [String] = []
        if let size = patch.totalSize { parts.append("Downloads \(size.formatted(.byteCount(style: .file))) into the game's patch folder.") }
        else { parts.append("Downloads into the game's patch folder.") }
        if !patch.official { parts.append("Community patch, not from the publisher.") }
        if patch.verified == nil { parts.append("Not tested in Shiori.") }
        if patch.files.contains(where: { $0.sha256 == nil }) {
            parts.append("The download can't be verified: the list has no checksum for it.")
        }
        if !(installer.installed[appID] ?? []).isEmpty, installedVersion(patch) == nil {
            parts.append("It replaces files it shares with an installed patch.")
        }
        return parts.joined(separator: " ")
    }
}

private extension View {
    /// Content buttons: bordered on the iPhone and iPad game page (Liquid Glass is for the
    /// controls floating over content), glass on the Apple TV's page as before.
    func patchButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.glass)
        #else
        buttonStyle(.bordered)
        #endif
    }
}

/// A patch job's progress under its row. Only this reads the job's phase, so progress
/// doesn't re-evaluate the whole patch list.
private struct PatchJobLine: View {
    let job: PatchInstaller.Job
    let appID: UInt32
    @Environment(PatchInstaller.self) private var installer

    var body: some View {
        switch job.phase {
        case let .downloading(written, total, part, parts):
            VStack(alignment: .leading, spacing: 3) {
                if total > 0 { ProgressView(value: Double(written), total: Double(max(total, written))) } else { ProgressView() }
                Text("Downloading\(parts > 1 ? " part \(part) of \(parts)" : "") · \(written.formatted(.byteCount(style: .file)))\(total > 0 ? " of \(total.formatted(.byteCount(style: .file)))" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .checking:
            Text("Checking the download…").font(.caption).foregroundStyle(.secondary)
        case let .installing(fraction):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction)
                Text("Installing…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message):
            HStack(alignment: .firstTextBaseline) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("OK") { installer.dismissFailure(appID: appID) }.font(.caption)
            }
        }
    }
}
