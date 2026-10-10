import ArtemisKit
import SwiftUI

/// Every file an Artemis game sees (archives, loose files and patches, resolved the way the
/// engine resolves them), with text and image previews. Phase 9's on-device check that the
/// `.pfs` reader works, and a way to find what to patch.
struct ArchiveBrowserView: View {
    let gameFolder: URL

    @Environment(\.dismiss) private var dismiss
    @State private var fileSystem: ArtemisFileSystem?
    @State private var files: [ArtemisFileSystem.File] = []
    @State private var error: String?
    @State private var query = ""

    private var shown: [ArtemisFileSystem.File] {
        query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Couldn't Read the Archives", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                } else if let fileSystem {
                    List {
                        Section("Archives (load order)") {
                            ForEach(fileSystem.archives, id: \.url) { archive in
                                LabeledContent(archive.url.lastPathComponent,
                                               value: "pf\(archive.version.rawValue) · \(archive.entries.count) files")
                            }
                        }
                        Section("\(shown.count) of \(files.count) files") {
                            ForEach(shown, id: \.path) { file in
                                NavigationLink {
                                    ArchiveFilePreview(file: file, fileSystem: fileSystem)
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.path).font(.callout.monospaced()).lineLimit(2)
                                        Text("\(file.size.formatted(.byteCount(style: .file))) · \(file.source.label)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .searchable(text: $query, prompt: "Filter paths")
                } else {
                    ProgressView("Reading archives…")
                }
            }
            .navigationTitle("Archives")
            .inlineNavigationTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        let base = gameFolder.appendingPathComponent("base", isDirectory: true)
        let patch = gameFolder.appendingPathComponent("patch", isDirectory: true)
        do {
            let fs = try await Task.detached(priority: .userInitiated) {
                try ArtemisFileSystem(gameRoot: base, patchRoot: patch)
            }.value
            files = fs.files.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            fileSystem = fs
        } catch {
            self.error = String(describing: error)
        }
    }
}

private struct ArchiveFilePreview: View {
    let file: ArtemisFileSystem.File
    let fileSystem: ArtemisFileSystem

    @State private var text: String?
    @State private var image: UIImage?
    @State private var note: String?

    var body: some View {
        Group {
            if let image {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1000)
                }
            } else if let text {
                ScrollView {
                    Text(text)
                        .font(.caption.monospaced())
                        .selectableText()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            } else if let note {
                ContentUnavailableView(file.path, systemImage: "doc", description: Text(note))
            } else {
                ProgressView()
            }
        }
        .navigationTitle((file.path as NSString).lastPathComponent)
        .inlineNavigationTitle()
        .task { await load() }
    }

    private func load() async {
        let file = file
        let fileSystem = fileSystem
        guard let data = try? await Task.detached { try fileSystem.data(of: file) }.value else {
            note = "Couldn't read this file."
            return
        }
        let ext = (file.path as NSString).pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "bmp", "webp"].contains(ext), let image = UIImage(data: data) {
            self.image = image
        } else if ["txt", "iet", "lua", "ini", "csv", "ast", "tbl"].contains(ext) {
            // Artemis scripts of this generation are Shift-JIS; newer ones UTF-8.
            let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
            let shown = decoded.map { $0.count > 200_000 ? String($0.prefix(200_000)) + "\n…" : $0 }
            if let shown { text = shown } else { note = "Not readable as text." }
        } else {
            note = "\(data.count.formatted(.byteCount(style: .file))) · no preview for .\(ext) files"
        }
    }
}

private extension ArtemisFileSystem.Source {
    var label: String {
        switch self {
        case let .archive(url): url.lastPathComponent
        case .loose: "loose file"
        case .patch: "patch"
        }
    }
}
