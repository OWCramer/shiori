// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import SwiftUI

/// Your progress: when you last played or saved, how many saves there are, and where they
/// sync (iCloud between your devices, Steam Cloud with the PC), with Sync Now.
struct SavesSection: View {
    let game: LibraryGame
    let record: GameRecord
    @Environment(GameLibrary.self) private var games
    @State private var iCloud = false
    @State private var steamCloud = false
    @State private var syncRequested = false

    private var appID: UInt32 { game.appID }
    private var history: PlayHistory { .shared }
    private var syncing: Bool { games.saveSync[appID] == .syncing || games.steamCloud[appID] == .syncing }

    /// Artemis, Luca and CatSystem2 saves are Shiori's own format; KiriKiri's and Siglus's are
    /// the PC's, and sync when the game's cloud rules name its save folder.
    private var engineUsesSteamCloud: Bool { games.usesSteamCloud(appID) }

    var body: some View {
        GamePageSection(title: "Saves", footer: footer) {
            lastPlayedRow
            saveCountRow
            GamePageRow {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $iCloud) { Label("iCloud", systemImage: "icloud") }
                    if iCloud {
                        Text(GameText.sync(games.saveSync[appID]))
                            .font(.footnote)
                            .foregroundStyle(syncColour(games.saveSync[appID]))
                    }
                }
            }
            steamCloudRow
            GamePageRow {
                Button(action: syncNow) {
                    HStack {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        if syncRequested && syncing { ProgressView() }
                    }
                    .contentShape(.rect)
                }
                .disabled(syncing)
            }
        }
        .onAppear(perform: loadToggles)
        .onChange(of: iCloud) { _, on in setICloud(on) }
        .onChange(of: steamCloud) { _, on in setSteamCloud(on) }
        .onChange(of: syncing) { _, now in if !now { syncRequested = false; refreshSaves() } }
        .task(id: appID) { refreshSaves() }
    }

    /// Only once there's something to say (a launch from Shiori or a save).
    @ViewBuilder private var lastPlayedRow: some View {
        if let activity = history.lastActivity(appID) {
            GamePageValueRow(title: activity.kind == .saved ? "Last saved" : "Last played",
                             value: activity.date.formatted(.relative(presentation: .named)))
        }
    }

    private var saveCountRow: some View {
        let slots = history.saves[appID]?.slots ?? 0
        return GamePageValueRow(title: "Saves", value: slots == 0 ? "None yet" : slots.formatted())
    }

    @ViewBuilder private var steamCloudRow: some View {
        if games.steamCloudSupport[appID] == false {
            GamePageValueRow(title: "Steam Cloud", value: "Not used by this game")
        } else if !engineUsesSteamCloud {
            GamePageValueRow(title: "Steam Cloud", value: "Not available",
                             detail: "PC saves for this engine don't sync.")
        } else {
            GamePageRow {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(isOn: $steamCloud) { Label("Steam Cloud", systemImage: "cloud") }
                    if steamCloud {
                        Text(GameText.sync(games.steamCloud[appID]))
                            .font(.footnote)
                            .foregroundStyle(syncColour(games.steamCloud[appID]))
                        Text(steamCloudNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var steamCloudNote: String {
        if !SteamCloudSync.uploadsEnabled {
            return "Saves download before you play. Uploads are off in Settings."
        }
        if games.canUploadSteamCloud(appID) {
            return "Syncs when you start and stop; cloud copies are backed up first."
        }
        return "Saves download before you play. Saves made here don't upload: the PC's older Ren'Py might not load them."
    }

    private var footer: String {
        "If two devices change the same save, the older copy goes to saves/conflicts."
    }

    private func syncColour(_ state: GameLibrary.SaveSyncState?) -> Color {
        switch state {
        case .failed: .red
        case .unavailable: .orange
        default: .secondary
        }
    }

    private func loadToggles() {
        iCloud = games.isCloudSaveEnabled(appID)
        steamCloud = games.isSteamCloudEnabled(appID)
    }

    /// Only a change the player made: loading the toggles mustn't start a sync.
    private func setICloud(_ on: Bool) {
        if on != games.isCloudSaveEnabled(appID) { games.setCloudSave(appID, enabled: on) }
    }

    private func setSteamCloud(_ on: Bool) {
        if on != games.isSteamCloudEnabled(appID) { games.setSteamCloud(appID, enabled: on) }
    }

    private func syncNow() {
        syncRequested = true
        Task { await games.syncAllSaveLocations(appID: appID) }
    }

    private func refreshSaves() {
        let folder = games.folder(appID: appID, name: game.name)
        let engine = record.engine?.engine
        Task { await history.refreshSaves(appID: appID, folder: folder, engine: engine) }
    }
}
#endif
