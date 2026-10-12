import SwiftUI

/// Browse SteamGridDB's covers, banners and logos for a game and pick one, like Tana's
/// artwork picker. Picks replace Steam's art everywhere the game appears.
struct ArtworkPickerView: View {
    let appID: UInt32

    @Environment(ArtworkStore.self) private var artwork
    @Environment(\.dismiss) private var dismiss

    @State private var kind: SteamGridDB.Kind = .grid
    @State private var assets: [SteamGridDB.Asset] = []
    @State private var gameID: Int?
    @State private var phase: Phase = .loading
    @AppStorage("steamGridDBAdult") private var includeAdult = false

    private enum Phase: Equatable {
        case loading, loaded, empty, notConfigured, unknownGame
        case failed(String)
    }

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 200), spacing: 12)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Artwork type", selection: $kind) {
                    ForEach(SteamGridDB.Kind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                content
            }
            .navigationTitle("Artwork")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Toggle("Include Adult Artwork", isOn: $includeAdult)
                        if artwork.pick(kind, for: appID) != nil {
                            Button("Use Steam's \(kind.displayName)", systemImage: "arrow.uturn.backward") {
                                withAnimation(.smooth) { artwork.set(nil, kind: kind, for: appID) }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
            }
            .task(id: "\(kind.rawValue)-\(includeAdult)") { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured:
            ContentUnavailableView("SteamGridDB Isn't Set Up", systemImage: "key.horizontal",
                                   description: Text("Add an API key in Settings."))
        case .unknownGame:
            ContentUnavailableView("Not on SteamGridDB", systemImage: "questionmark.square.dashed",
                                   description: Text("SteamGridDB doesn't have this game."))
        case .empty:
            ContentUnavailableView("No \(kind.displayName) Art", systemImage: "photo.on.rectangle",
                                   description: includeAdult ? nil : Text("Adult artwork is hidden."))
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn't Load Artwork", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again", systemImage: "arrow.clockwise") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        case .loaded:
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(assets) { asset in
                        Button { select(asset) } label: { thumbnail(asset) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private func thumbnail(_ asset: SteamGridDB.Asset) -> some View {
        let selected = artwork.pick(kind, for: appID) == asset.url
        return VStack(spacing: 5) {
            RemoteImage(url: asset.thumbnail ?? asset.url, contentMode: .fit) {
                Color.secondary.opacity(0.12)
            }
            .aspectRatio(kind.previewAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(kind == .logo ? AnyShapeStyle(Color.black.opacity(0.55)) : AnyShapeStyle(.quaternary))
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 3)
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }
            if let dimensions = asset.dimensions {
                Text(dimensions).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .accessibilityLabel("\(kind.displayName) artwork\(selected ? ", selected" : "")")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func select(_ asset: SteamGridDB.Asset) {
        withAnimation(.smooth) { artwork.set(asset.url, kind: kind, for: appID) }
    }

    private func load() async {
        guard let client = SteamGridDB() else { phase = .notConfigured; return }
        phase = .loading
        do {
            if gameID == nil { gameID = try await client.gameID(steamAppID: appID) }
            guard let gameID else { phase = .unknownGame; return }
            let found = try await client.assets(kind, gameID: gameID, includeAdult: includeAdult)
            assets = found
            phase = found.isEmpty ? .empty : .loaded
        } catch is CancellationError {
        } catch {
            assets = []
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Settings row for the SteamGridDB key: paste, test against the live API, then save.
struct SteamGridDBKeySection: View {
    @State private var draft = ""
    @State private var isConfigured = SteamGridDB.isConfigured
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle, testing
        case saved
        case failed(String)
    }

    var body: some View {
        Section {
            if isConfigured {
                LabeledContent("API key", value: "Saved")
                Button("Remove Key", role: .destructive) {
                    APIKeyStore.steamGridDB.set(nil)
                    isConfigured = false
                    status = .idle
                }
            } else {
                SecureField("API key", text: $draft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    Task { await test() }
                } label: {
                    if status == .testing {
                        HStack { ProgressView(); Text("Testing…") }
                    } else {
                        Text("Test and Save")
                    }
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || status == .testing)
            }
        } header: {
            Text("SteamGridDB")
        } footer: {
            switch status {
            case .saved:
                Text("Key saved.")
            case let .failed(message):
                Text(message).foregroundStyle(.red)
            default:
                Text("For alternate artwork. Get a free key at steamgriddb.com › Preferences › API.")
            }
        }
    }

    private func test() async {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        status = .testing
        do {
            try await SteamGridDB(key: key).validate()
            APIKeyStore.steamGridDB.set(key)
            draft = ""
            isConfigured = true
            status = .saved
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
