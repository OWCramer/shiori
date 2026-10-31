// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

#if os(iOS)
import CryptoKit
import DeviceCheck
import Foundation
import OSLog
import UIKit

/// Share Compatibility Data (Settings, off until turned on): how long each game is played,
/// how often a session ended unexpectedly, and, once asked after half an hour, how it played.
/// Each game's totals go to compat.ocramer.com when a session ends, signed with App Attest so
/// only real installs of Shiori can send them; the site's daily update turns them into the
/// list's player counts and, from three players, its status.
///
/// Sent: the game's app id, name and engine, play time, sessions, unexpected ends, the rating,
/// and the app version, device model and iOS version. Nothing about the Steam account or saves.
@MainActor @Observable
final class PlayerReports {
    static let shared = PlayerReports()

    enum Rating: String, Codable, CaseIterable {
        case works, issues, broken

        var title: String {
            switch self {
            case .works: "Plays Well"
            case .issues: "Some Problems"
            case .broken: "Doesn't Work"
            }
        }
    }

    /// A game to ask "How did it play?" about.
    struct Question: Identifiable, Equatable {
        let appID: UInt32
        let name: String
        var id: UInt32 { appID }
    }

    var isSharing: Bool {
        get { access(keyPath: \.isSharing); return UserDefaults.standard.bool(forKey: Self.sharingKey) }
        set {
            withMutation(keyPath: \.isSharing) { UserDefaults.standard.set(newValue, forKey: Self.sharingKey) }
            if newValue { Task { await registerIfNeeded() } }
        }
    }

    /// Set when a game has been played long enough to ask about; the app shows the question.
    var question: Question?

    // MARK: Play time

    private struct Totals: Codable {
        var minutes = 0
        var sessions = 0
        var failures = 0
        var rating: Rating?
        /// The app version it was last asked about in, so a new version can ask again.
        var askedIn: String?
        var name = ""
        var engine = ""
        var engineVersion: String?
    }

    private struct Running: Codable {
        let appID: UInt32
        let started: Date
    }

    /// A game started: its clock runs until `ended`. A clock still running at the next launch
    /// means the session ended unexpectedly (the app was closed or crashed).
    func started(appID: UInt32, name: String, engine: String, engineVersion: String?) {
        if running?.appID == appID { return }
        if let running { ended(appID: running.appID) }
        var totals = totals(appID)
        totals.name = name
        totals.engine = engine
        totals.engineVersion = engineVersion
        save(totals, appID: appID)
        running = Running(appID: appID, started: .now)
    }

    /// The game closed normally.
    func ended(appID: UInt32) {
        guard let running, running.appID == appID else { return }
        self.running = nil
        var totals = totals(appID)
        totals.minutes += max(0, Int(Date.now.timeIntervalSince(running.started) / 60))
        totals.sessions += 1
        save(totals, appID: appID)
        guard isSharing else { return }
        if totals.minutes >= Self.askAfterMinutes, totals.askedIn != Self.appVersion {
            question = Question(appID: appID, name: totals.name)
        }
        Task { await send(appID: appID) }
    }

    /// At launch: a session left running was cut short.
    func recoverUnfinishedSession() {
        guard let running else { return }
        self.running = nil
        var totals = totals(running.appID)
        totals.failures += 1
        totals.sessions += 1
        save(totals, appID: running.appID)
        if isSharing { Task { await send(appID: running.appID) } }
    }

    func answer(_ rating: Rating?, for appID: UInt32) {
        question = nil
        var totals = totals(appID)
        totals.askedIn = Self.appVersion
        if let rating { totals.rating = rating }
        save(totals, appID: appID)
        if rating != nil { Task { await send(appID: appID) } }
    }

    private static let sharingKey = "ShareCompatibilityData"
    private static let askAfterMinutes = 30
    private static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private var running: Running? {
        get { UserDefaults.standard.data(forKey: "PlayerReports.running").flatMap { try? JSONDecoder().decode(Running.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "PlayerReports.running") }
    }

    private func totals(_ appID: UInt32) -> Totals {
        UserDefaults.standard.data(forKey: "PlayerReports.\(appID)").flatMap { try? JSONDecoder().decode(Totals.self, from: $0) } ?? Totals()
    }

    private func save(_ totals: Totals, appID: UInt32) {
        UserDefaults.standard.set(try? JSONEncoder().encode(totals), forKey: "PlayerReports.\(appID)")
    }

    // MARK: Sending

    private static let server = URL(string: "https://compat.ocramer.com/api/")!
    private static let log = Logger(subsystem: "com.owencramer.vnhub", category: "PlayerReports")
    private static let keyIDKey = "PlayerReports.keyID"
    private var registering: Task<String?, Never>?

    private struct Body: Encodable {
        let appID: UInt32
        let name: String
        let engine: String
        let engineVersion: String?
        let appVersion: String
        let device: String
        let os: String
        let minutes: Int
        let sessions: Int
        let failures: Int
        let rating: Rating?
    }

    /// The game's totals to the server. Quietly does nothing where App Attest isn't available
    /// (the simulator) or the server can't be reached; the next session sends them again.
    private func send(appID: UInt32) async {
        guard isSharing, let keyID = await registerIfNeeded() else { return }
        let totals = totals(appID)
        guard !totals.engine.isEmpty else { return }
        let body = Body(appID: appID, name: totals.name, engine: totals.engine, engineVersion: totals.engineVersion,
                        appVersion: Self.appVersion, device: Self.deviceModel, os: UIDevice.current.systemVersion,
                        minutes: totals.minutes, sessions: totals.sessions, failures: totals.failures, rating: totals.rating)
        do {
            let data = try JSONEncoder().encode(body)
            let assertion = try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: data)))
            var request = URLRequest(url: Self.server.appendingPathComponent("report"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(keyID, forHTTPHeaderField: "X-Key-ID")
            request.setValue(assertion.base64EncodedString(), forHTTPHeaderField: "X-Assertion")
            request.httpBody = data
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { UserDefaults.standard.removeObject(forKey: Self.keyIDKey) } // unknown key: register again
            Self.log.notice("Report \(appID): HTTP \(status)")
        } catch {
            Self.log.error("Report \(appID) not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// This install's App Attest key, made and registered with the server once.
    @discardableResult
    private func registerIfNeeded() async -> String? {
        if let keyID = UserDefaults.standard.string(forKey: Self.keyIDKey) { return keyID }
        guard DCAppAttestService.shared.isSupported else { return nil }
        if let registering { return await registering.value }
        let task = Task<String?, Never> {
            do {
                let keyID = try await DCAppAttestService.shared.generateKey()
                var challengeRequest = URLRequest(url: Self.server.appendingPathComponent("challenge"))
                challengeRequest.httpMethod = "POST"
                let (challengeData, _) = try await URLSession.shared.data(for: challengeRequest)
                struct Challenge: Decodable { let challenge: String }
                let challenge = try JSONDecoder().decode(Challenge.self, from: challengeData).challenge
                let attestation = try await DCAppAttestService.shared.attestKey(
                    keyID, clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8))))
                var request = URLRequest(url: Self.server.appendingPathComponent("register"))
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(["keyId": keyID, "attestation": attestation.base64EncodedString(),
                                                             "challenge": challenge])
                let (_, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 204 else {
                    Self.log.error("Register: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    return nil
                }
                UserDefaults.standard.set(keyID, forKey: Self.keyIDKey)
                return keyID
            } catch {
                Self.log.error("Register failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        registering = task
        let keyID = await task.value
        registering = nil
        return keyID
    }

    /// "iPhone19,4".
    private static let deviceModel: String = {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }()
}
#endif
