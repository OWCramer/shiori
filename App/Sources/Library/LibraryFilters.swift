// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// The filters on a library tab (Visual Novels, Installed), remembered per tab on this device.
struct LibraryFilters: Codable, Equatable {
    /// Which games show, by whether Shiori plays them.
    enum Playability: String, Codable, CaseIterable, Identifiable {
        case all = "All Games"
        /// Hides games whose engine is known not to play; unchecked ones stay.
        case hideUnsupported = "Hide Unsupported"
        case plays = "Plays in Shiori"
        var id: Self { self }
    }

    /// The compatibility list's verdict, or none.
    enum Compatibility: String, Codable, CaseIterable, Identifiable {
        case complete = "Complete"
        case plays = "Plays"
        case boots = "Boots"
        case unsupported = "Unsupported"
        case notTested = "Not Tested"
        var id: Self { self }

        init(_ status: CompatibilityStore.Status?) {
            switch status {
            case .complete: self = .complete
            case .plays: self = .plays
            case .boots: self = .boots
            case .unsupported: self = .unsupported
            case nil: self = .notTested
            }
        }
    }

    enum Download: String, Codable, CaseIterable, Identifiable {
        case all = "Downloaded or Not"
        case downloaded = "Downloaded"
        case notDownloaded = "Not Downloaded"
        var id: Self { self }
    }

    /// The engine key for games whose engine check found nothing Shiori knows.
    static let unknownEngine = "unknown"
    /// The engine key for games not checked yet.
    static let uncheckedEngine = "unchecked"

    var playability: Playability = .all
    /// Empty: any.
    var compatibility: Set<Compatibility> = []
    /// Engine keys; empty: any.
    var engines: Set<String> = []
    var download: Download = .all

    var isActive: Bool { self != LibraryFilters() }

    /// Whether a game passes every filter.
    func admits(_ traits: GameTraits, isDownloaded: Bool) -> Bool {
        switch playability {
        case .all: break
        case .hideUnsupported: if traits.plays == .no { return false }
        case .plays: if traits.plays != .yes { return false }
        }
        if !compatibility.isEmpty, !compatibility.contains(Compatibility(traits.compatibility)) { return false }
        if !engines.isEmpty, !engines.contains(traits.engine ?? Self.uncheckedEngine) { return false }
        switch download {
        case .all: break
        case .downloaded: if !isDownloaded { return false }
        case .notDownloaded: if isDownloaded { return false }
        }
        return true
    }

    /// The active filters in words: "Plays in Shiori, Ren'Py, Artemis".
    var summary: String {
        var parts: [String] = []
        if playability != .all { parts.append(playability.rawValue) }
        parts += Compatibility.allCases.filter(compatibility.contains).map { "Compatibility: \($0.rawValue)" }
        parts += engines.sorted().map(Self.engineName)
        if download != .all { parts.append(download.rawValue) }
        return parts.joined(separator: ", ")
    }

    static func engineName(_ key: String) -> String {
        switch key {
        case unknownEngine: "Unknown Engine"
        case uncheckedEngine: "Not Checked"
        default: EngineDetection.displayName(for: key)
        }
    }

    // MARK: Storage

    private static func key(_ section: LibrarySection) -> String {
        "libraryFilters.\(section.storageKey)"
    }

    static func load(_ section: LibrarySection) -> LibraryFilters {
        guard let data = UserDefaults.standard.data(forKey: key(section)),
              let filters = try? JSONDecoder().decode(LibraryFilters.self, from: data) else { return LibraryFilters() }
        return filters
    }

    func save(_ section: LibrarySection) {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key(section))
    }
}
