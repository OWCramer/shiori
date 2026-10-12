import SteamKit
import SwiftUI

/// The top of a game's Patches card: its Steam DLC, and the patches the public patch list
/// knows for it, each with what it is, who made it, and Install, Update or Remove.
struct PatchListSection: View {
    let appID: UInt32
    let gameFolder: URL
    /// Called after a patch is installed or removed, so the card's file list refreshes.
    let onChange: () -> Void

    @Environment(PatchListStore.self) private var patchList
    @Environment(PatchInstaller.self) private var installer
    @Environment(SteamModel.self) private var steam
    @Environment(GameLibrary.self) private var games
    @Environment(\.openURL) private var openURL
    @State private var dlcs: [DLCInfo]?
    #if os(iOS)
    @State private var denpasoftPage: URL?
    private var denpasoft: DenpasoftAccount { .shared }
    #endif
    /// The question being asked: install (or update) a patch, or remove it. One dialog, since
    /// SwiftUI drops a second confirmationDialog on the same view.
    @State private var prompt: Prompt?

    private enum Prompt: Identifiable {
        case install(PatchListStore.Patch)
        /// A file from a shop account (Denpasoft), by its file name.
        case installFile(PatchListStore.Patch, String)
        case remove(PatchListStore.Patch)
        var patch: PatchListStore.Patch { switch self { case let .install(p), let .installFile(p, _), let .remove(p): p } }
        var id: String {
            switch self {
            case let .install(p): "i-\(p.id)"
            case let .installFile(p, f): "f-\(p.id)-\(f)"
            case let .remove(p): "r-\(p.id)"
            }
        }
    }

    private var patches: [PatchListStore.Patch] { patchList.patches(for: appID) }
    private var record: GameRecord? { if case let .installed(record) = games.status(for: appID) { record } else { nil } }

    var body: some View {
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
        .task(id: steam.isLoggedOn) {
            guard steam.isLoggedOn, dlcs == nil else { return }
            dlcs = try? await steam.session.dlcs(appID: appID)
        }
        .onChange(of: installer.installed[appID]) { onChange() }
        #if os(iOS)
        .task(id: patches.contains { denpasoftProduct($0) != nil }) {
            if patches.contains(where: { denpasoftProduct($0) != nil }) { await denpasoft.refresh() }
        }
        .sheet(isPresented: Binding(get: { denpasoftPage != nil }, set: { if !$0 { denpasoftPage = nil } })) {
            if let url = denpasoftPage { DenpasoftWebSheet(url: url, title: "Denpasoft") }
        }
        #endif
        .alert(promptTitle, isPresented: Binding(
            get: { prompt != nil }, set: { if !$0 { prompt = nil } }
        ), presenting: prompt) { prompt in
            switch prompt {
            case let .install(patch):
                Button(installedVersion(patch) == nil ? "Download and Install" : "Update") {
                    installer.install(patch, appID: appID, gameFolder: gameFolder)
                }
            case let .installFile(patch, file):
                Button(installedVersion(patch) == nil ? "Download and Install" : "Replace") {
                    installer.install(patch, appID: appID, gameFolder: gameFolder, chosenFile: file)
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
            case let .installFile(patch, file): Text("Installs \(file.isEmpty ? "the file" : file) from your Denpasoft downloads. " + confirmationMessage(patch))
            case .remove: Text("Only this patch's files are deleted; saves and other patches stay.")
            }
        }
    }

    private var promptTitle: String {
        switch prompt {
        case let .install(patch), let .installFile(patch, _): "Install \(patch.name)?"
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
                } else if !dlc.owned {
                    Button("Steam", systemImage: "arrow.up.right") {
                        openURL(URL(string: "https://store.steampowered.com/app/\(dlc.appID)")!)
                    }
                    .patchButtonStyle()
                    .font(.caption)
                } else {
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
        if dlc.depotIDs.isEmpty { return "Owned · no files of its own (on PC it unlocks through Steam, which Shiori can't answer for)" }
        return isInstalled(dlc) ? "Owned · installed with the game" : "Owned · not downloaded yet"
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
                    Text(byline(patch)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                action(patch)
            }
            badges(patch)
            #if os(iOS)
            if let url = denpasoftProduct(patch), denpasoft.isSignedIn {
                let files = denpasoft.downloads(forProductURL: url)
                if let installed = installedVersion(patch)?.version, files.count > 1 {
                    Text("Installed: \(DenpasoftAccount.cleanFileName(installed))").font(.caption).foregroundStyle(.secondary)
                } else if !files.isEmpty {
                    Text("In your Denpasoft downloads: " + files.enumerated().map { fileLabel($1, index: $0) }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif
            if let job = installer.jobs[appID], job.patchID == patch.id { jobView(job) }
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
        let busy = installer.jobs[appID] != nil && installer.jobs[appID]?.phase.isFailure == false
        if let job = installer.jobs[appID], job.patchID == patch.id, !job.phase.isFailure {
            Button("Cancel") { installer.cancel(appID: appID) }
                .patchButtonStyle().font(.caption)
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
        } else if let denpasoftURL = denpasoftProduct(patch) {
            #if os(iOS)
            let files = denpasoft.isSignedIn ? denpasoft.downloads(forProductURL: denpasoftURL) : []
            if files.count > 1 {
                // Denpasoft can carry more than one file for a product: the player picks.
                Menu {
                    Section("Your Denpasoft downloads") {
                        ForEach(Array(files.enumerated()), id: \.element.url) { index, file in
                            Button(fileLabel(file, index: index)) {
                                prompt = .installFile(patch, file.fileName)
                            }
                        }
                    }
                } label: {
                    Label("Install", systemImage: "arrow.down.circle")
                }
                .patchButtonStyle().font(.caption)
                .disabled(busy)
            } else if let file = files.first {
                Button("Install", systemImage: "arrow.down.circle") { prompt = .installFile(patch, file.fileName) }
                    .patchButtonStyle().font(.caption)
                    .disabled(busy)
            } else {
                Button(patch.files.first?.price?.lowercased() == "free" ? "Free" : "Buy", systemImage: "arrow.up.right") {
                    denpasoftPage = URL(string: denpasoftURL)
                }
                .patchButtonStyle().font(.caption)
            }
            #else
            EmptyView()
            #endif
        } else if let dlc = patch.files.first?.dlc, dlcs?.first(where: { $0.appID == dlc })?.owned == true {
            Label("Owned", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.teal)
        } else if let link = externalLink(patch) {
            Button(link.title, systemImage: "arrow.up.right") { openURL(link.url) }
                .patchButtonStyle().font(.caption)
        }
    }

    @ViewBuilder private func jobView(_ job: PatchInstaller.Job) -> some View {
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

    private func badges(_ patch: PatchListStore.Patch) -> some View {
        HStack(spacing: 6) {
            badge(patch.official ? "Official" : "Community", tint: patch.official ? .teal : .purple)
            if patch.adult { badge("18+", tint: .pink) }
            if patch.files.first?.host == "store", let price = patch.files.first?.price {
                badge(price.lowercased() == "free" ? "Free" : price, tint: .blue)
            }
            if patch.verified != nil {
                badge("Works in Shiori", tint: .green)
            } else {
                badge("Not checked in Shiori", tint: .gray)
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

    private func byline(_ patch: PatchListStore.Patch) -> String {
        let site = switch patch.source.site {
        case "nekonyan": "NekoNyan's patch page"
        case "saikey": "Saikey Studios"
        case "uncensorpatch": "uncensorpat.ch"
        case "patchmoe": "patch.moe"
        case "vndb": "VNDB"
        case "wingedcloud": "Winged Cloud's Patreon"
        default: "the patch list"
        }
        if patch.by.isEmpty || site.localizedCaseInsensitiveContains(patch.by) || patch.by.localizedCaseInsensitiveContains(site) {
            return "via \(site)"
        }
        return "\(patch.by) · via \(site)"
    }

    #if os(iOS)
    private func fileLabel(_ file: DenpasoftAccount.Download, index: Int) -> String {
        if !file.fileName.isEmpty { return file.fileName }
        if !file.productName.isEmpty { return "\(file.productName) (file \(index + 1))" }
        return "File \(index + 1)"
    }
    #endif

    /// The Denpasoft product page of a patch Denpasoft sells or gives away.
    private func denpasoftProduct(_ patch: PatchListStore.Patch) -> String? {
        guard let file = patch.files.first, file.host == "store", file.url.contains("denpasoft.com/product") else { return nil }
        return file.url
    }

    private func externalLink(_ patch: PatchListStore.Patch) -> (title: String, url: URL)? {
        guard let file = patch.files.first, let url = URL(string: file.url) else { return nil }
        switch file.host {
        case "steam":
            if let dlc = file.dlc, dlcs?.first(where: { $0.appID == dlc })?.owned == true { return nil }
            return ("Steam", url)
        case "store": return (file.price?.lowercased() == "free" ? "Free" : "Buy", url)
        default:
            if patch.status == "unsupported" || file.installer == true { return ("Page", URL(string: patch.source.page) ?? url) }
            return ("Open", url)
        }
    }

    private func confirmationMessage(_ patch: PatchListStore.Patch) -> String {
        var parts: [String] = []
        if let size = patch.totalSize { parts.append("Downloads \(size.formatted(.byteCount(style: .file))) and installs it into this game's patch folder.") }
        else { parts.append("Downloads the patch and installs it into this game's patch folder.") }
        if !patch.official { parts.append("This is a community patch, not one from the game's publisher.") }
        if patch.verified == nil { parts.append("Nobody has checked it in Shiori yet; if the game misbehaves, remove it from here.") }
        if denpasoftProduct(patch) != nil {
            // The installFile message already says where it comes from.
        } else if patch.files.contains(where: { $0.sha256 == nil }) {
            parts.append("The list has no checksum for it yet, so the download can't be checked.")
        }
        if !(installer.installed[appID] ?? []).isEmpty, installedVersion(patch) == nil {
            parts.append("Files it shares with an installed patch are replaced by this one.")
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

private extension PatchInstaller.Phase {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}
