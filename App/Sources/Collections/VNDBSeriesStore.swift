// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "com.owencramer.vnhub", category: "collections")

/// Looks the user's visual novels up on VNDB (its Kana API) for Collections: which VNDB entry
/// each Steam app is a release of, and how those entries relate. Kept in Application
/// Support, so suggestions work offline; an app is looked up again after a month (a week
/// when VNDB didn't know it). Requests go one at a time, a second apart, in batches, well
/// inside VNDB's limit of 200 requests in five minutes; a 429 ends the run until next time.
@MainActor @Observable
final class VNDBSeriesStore {
    private(set) var links: VNDBLinks
    @ObservationIgnored private var isRefreshing = false

    private static let endpoint = URL(string: "https://api.vndb.org/kana")!
    private static let batchSize = 25
    private static let foundAge: TimeInterval = 30 * 86_400
    private static let missingAge: TimeInterval = 7 * 86_400

    private static var cacheURL: URL { URL.shioriSupport.appendingPathComponent("vndb-series.json") }

    init() {
        links = (try? Data(contentsOf: Self.cacheURL)).flatMap { try? JSONDecoder().decode(VNDBLinks.self, from: $0) } ?? VNDBLinks()
    }

    /// Fetches what's missing or stale for these apps (the Visual Novels tab's games).
    func refresh(appIDs: [UInt32]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var working = links
        let now = Date.now
        let due = appIDs.filter { appID in
            guard let checked = working.checked[String(appID)] else { return true }
            let age = working.vns(of: appID).isEmpty ? Self.missingAge : Self.foundAge
            return now.timeIntervalSince(checked) > age
        }
        do {
            for batch in due.chunked(Self.batchSize) {
                let found = try await releases(steamIDs: batch)
                for appID in batch {
                    working.vns[String(appID)] = found[appID].map { Array($0).sorted() }
                    working.checked[String(appID)] = now
                }
                links = working
            }
            let vns = Set(appIDs.flatMap { working.vns(of: $0) }).filter { vn in
                working.vnChecked[vn].map { now.timeIntervalSince($0) > Self.foundAge } ?? true
            }
            for batch in vns.sorted().chunked(Self.batchSize) {
                for entry in try await entries(batch) {
                    working.relations[entry.id] = entry.relations
                    working.released[entry.id] = entry.released
                    working.vnChecked[entry.id] = now
                }
                links = working
            }
        } catch {
            log.notice("VNDB lookup stopped: \(String(describing: error), privacy: .public)")
        }
        if working != links { links = working }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(links).write(to: Self.cacheURL, options: .atomic)
    }

    // MARK: - Kana API

    private struct ReleasePage: Decodable {
        struct Release: Decodable {
            struct Link: Decodable { var name: String; var id: String }
            struct VN: Decodable { var id: String }
            var extlinks: [Link]
            var vns: [VN]
        }
        var results: [Release]
        var more: Bool
    }

    private struct EntryPage: Decodable {
        struct Entry: Decodable {
            struct Relation: Decodable { var id: String; var relation: String; var relation_official: Bool }
            var id: String
            var released: String?
            var relations: [Relation]
        }
        var results: [Entry]
        var more: Bool
    }

    /// Steam app id → the VNDB entries its releases belong to.
    private func releases(steamIDs: [UInt32]) async throws -> [UInt32: Set<String>] {
        let wanted = Set(steamIDs)
        var found: [UInt32: Set<String>] = [:]
        var page = 1
        while true {
            let filters = Self.anyOf(steamIDs.map { ["extlink", "=", ["steam", Int($0)]] as [Any] })
            let result: ReleasePage = try await query("release", filters: filters, fields: "extlinks.name,extlinks.id,vns.id", page: page)
            for release in result.results {
                let apps = release.extlinks.filter { $0.name == "steam" }.compactMap { UInt32($0.id) }.filter(wanted.contains)
                for app in apps { found[app, default: []].formUnion(release.vns.map(\.id)) }
            }
            guard result.more, page < 10 else { return found }
            page += 1
        }
    }

    private func entries(_ ids: [String]) async throws -> [(id: String, released: String?, relations: [VNDBLinks.Relation])] {
        let filters = Self.anyOf(ids.map { ["id", "=", $0] as [Any] })
        let result: EntryPage = try await query("vn", filters: filters,
                                               fields: "released,relations.id,relations.relation,relations.relation_official", page: 1)
        return result.results.map { entry in
            (entry.id, entry.released, entry.relations.map { .init(id: $0.id, relation: $0.relation, official: $0.relation_official) })
        }
    }

    private static func anyOf(_ filters: [[Any]]) -> [Any] {
        filters.count == 1 ? filters[0] : ["or"] + filters
    }

    private enum LookupError: Error { case status(Int) }

    private func query<T: Decodable>(_ path: String, filters: [Any], fields: String, page: Int) async throws -> T {
        // A second between requests.
        try await Task.sleep(for: .seconds(1))
        var request = URLRequest(url: Self.endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "filters": filters, "fields": fields, "results": 100, "page": page,
        ] as [String: Any])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LookupError.status(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

private extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
