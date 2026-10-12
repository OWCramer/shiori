import Observation
import SteamKit
import UIKit

/// App-side view of the Steam session: connection state, QR sign-in and the owned library.
@MainActor @Observable
final class SteamModel {
    enum SignIn: Equatable {
        case idle
        case working
        /// Password sign-in waiting on Steam Guard.
        case steamGuard(SteamGuardPrompt, codeError: String?, isSubmittingCode: Bool)
        /// QR sign-in, for scanning with the Steam app on another device.
        case qr(URL, scanned: Bool)
        case failed(String)
    }

    private(set) var state: SessionState = .signedOut
    private(set) var signIn: SignIn = .idle
    /// Owned games, from the on-disk cache until Steam answers, with picked artwork applied.
    var library: [LibraryGame] { steamLibrary.map(artwork.apply) }
    /// Owned games as Steam describes them.
    private var steamLibrary: [LibraryGame] = LibraryCache.load()
    /// Alternate artwork picked from SteamGridDB.
    let artwork = ArtworkStore()
    /// The signed-in player's persona name and avatar (Settings).
    let profile = SteamProfile()
    private(set) var isLoadingLibrary = false
    private(set) var libraryError: String?
    private(set) var resumeError: String?
    /// Why the stored session didn't log on at launch, if it failed for another reason
    /// (offline, Steam unreachable, the Keychain); SteamSession may still be retrying.
    private(set) var connectionError: String?

    let session: SteamSession
    private var signInTask: Task<Void, Never>?

    /// Whether to show that Steam can't be reached (the offline icon, "Can't reach Steam").
    /// A reconnect is normal: iOS suspends the socket whenever Shiori is in the background,
    /// so the last known state stands (signed in, the cached library) for a grace period,
    /// and only a reconnect still failing after it, or a refused sign-in, shows.
    private(set) var showsOffline = false
    /// How long a reconnect may take before it's shown.
    private static let offlineGrace: Duration = .seconds(10)
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        // In iCloud Keychain: signing in on one device signs in the user's others (spec: Sign-in).
        let store = KeychainSessionStore(service: "com.owencramer.vnhub.steam", synchronizable: true)
        store.migrateToSynchronizable()
        session = SteamSession(
            configuration: SteamConfiguration(deviceName: Self.deviceName, deviceSeed: Self.deviceSeed),
            store: store
        )
        // Known before the first frame, so a signed-in launch never shows the sign-in
        // screen (which on Apple TV starts a QR sign-in that would replace the session).
        hasStoredSession = (try? store.load()) != nil
        Task { await observeState() }
        Task { await resume() }
    }

    var accountName: String? {
        if case let .loggedOn(name, _) = state { return name }
        return nil
    }

    var isLoggedOn: Bool { accountName != nil }

    /// Signed in on an earlier launch, whether or not Steam is reachable right now.
    private(set) var hasStoredSession = false

    private func observeState() async {
        for await state in await session.stateUpdates() {
            let wasLoggedOn = isLoggedOn
            self.state = state
            if isLoggedOn { connectionError = nil }
            if state == .signedOut, let rejection = await session.tokenRejection { connectionError = rejection }
            updateOfflineIndicator()
            SteamLog.write("state \(state)" + (connectionError.map { " (\($0))" } ?? ""))
            hasStoredSession = await session.storedAccountName != nil
            if case let .loggedOn(_, steamID) = state, !wasLoggedOn {
                Task { await profile.load(steamID: steamID.rawValue) }
                await loadLibrary()
            }
        }
    }

    /// Set while the stored session is logging on, so a second logon doesn't race it.
    private var isResuming = false

    private func resume() async {
        guard !isResuming else { return }
        isResuming = true
        defer { isResuming = false }
        hasStoredSession = await session.storedAccountName != nil
        SteamLog.write("launch: stored session \(hasStoredSession ? "found" : "none")")
        guard hasStoredSession else { return }
        do {
            try await session.resume()
        } catch SteamError.sessionExpired {
            resumeError = SteamError.sessionExpired.description
            updateOfflineIndicator()
            SteamLog.write("resume: session expired (\(await session.tokenRejection ?? "?"))")
        } catch {
            // Offline or Steam unreachable: SteamSession keeps retrying in the background.
            connectionError = Self.message(for: error)
            SteamLog.write("resume failed: \(String(describing: error))")
        }
    }

    /// Signs in with a session another device saved to iCloud Keychain, if one arrived
    /// while this device was signed out (checked when the app comes to the foreground).
    func adoptSyncedSession() async {
        guard !isLoggedOn, !isResuming, state == .signedOut || state == .connectedAnonymously,
              await session.storedAccountName != nil else { return }
        SteamLog.write("adopting a sign-in synced from another device")
        cancelSignIn()
        await resume()
    }

    /// Shows the offline indicator only once a reconnect has gone on past the grace period,
    /// or at once when the stored sign-in was refused.
    private func updateOfflineIndicator() {
        if isLoggedOn || !hasStoredSession {
            graceTask?.cancel()
            graceTask = nil
            showsOffline = false
            return
        }
        if resumeError != nil {
            graceTask?.cancel()
            graceTask = nil
            showsOffline = true
            return
        }
        guard graceTask == nil, !showsOffline else { return }
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.offlineGrace)
            guard let self, !Task.isCancelled else { return }
            graceTask = nil
            if !isLoggedOn { showsOffline = true }
        }
    }

    /// Going to the background: asks iOS for a little time, so a quick trip to another app
    /// doesn't drop the connection at all.
    func didEnterBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Steam connection") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundTask() }
        }
    }

    /// Back in the foreground: a reconnect starting now gets the whole grace period again.
    func willEnterForeground() {
        endBackgroundTask()
        guard !isLoggedOn, hasStoredSession, resumeError == nil else { return }
        graceTask?.cancel()
        graceTask = nil
        showsOffline = false
        updateOfflineIndicator()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    func signIn(accountName: String, password: String) {
        run(session.beginCredentialsSignIn(accountName: accountName, password: password))
    }

    func startQRSignIn() {
        run(session.beginQRSignIn())
    }

    func submitSteamGuardCode(_ code: String) {
        guard case let .steamGuard(prompt, _, false) = signIn else { return }
        signIn = .steamGuard(prompt, codeError: nil, isSubmittingCode: true)
        Task {
            var codeError: String?
            do {
                try await session.submitSteamGuardCode(code)
            } catch {
                codeError = Self.message(for: error)
            }
            // The sign-in may have completed (or failed) while the code was in flight.
            if case .steamGuard = signIn { signIn = .steamGuard(prompt, codeError: codeError, isSubmittingCode: false) }
        }
    }

    private func run(_ events: AsyncThrowingStream<SignInEvent, Error>) {
        signInTask?.cancel()
        resumeError = nil
        signIn = .working
        signInTask = Task {
            // Approving means switching to the Steam app; ask iOS for time so the
            // connection survives a short trip away.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Steam sign-in")
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                for try await event in events {
                    switch event {
                    case let .challenge(url):
                        signIn = .qr(url, scanned: false)
                    case .awaitingConfirmation:
                        if case let .qr(url, _) = signIn { signIn = .qr(url, scanned: true) }
                    case let .steamGuard(prompt):
                        signIn = .steamGuard(prompt, codeError: nil, isSubmittingCode: false)
                    case .signedIn:
                        signIn = .idle
                        SteamLog.write("signed in; stored session \(await session.storedAccountName != nil ? "saved" : "MISSING")")
                    }
                }
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed(Self.message(for: error))
                SteamLog.write("sign-in failed: \(String(describing: error))")
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .idle
    }

    private static func message(for error: Error) -> String {
        (error as? SteamError)?.description ?? error.localizedDescription
    }

    func signOut() async {
        await session.signOut()
        steamLibrary = []
        LibraryCache.clear()
        profile.forget()
        hasStoredSession = false
    }

    func loadLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            steamLibrary = try await session.ownedApps().map(LibraryGame.init)
            LibraryCache.save(steamLibrary)
        } catch {
            // With a library on screen, a failed refresh (the connection dropping mid-way)
            // isn't worth an error: the cached one stands, and the next logon reloads it.
            if steamLibrary.isEmpty { libraryError = Self.message(for: error) }
            SteamLog.write("library refresh failed: \(String(describing: error))")
        }
    }

    private static var deviceName: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: "Shiori (iPad)"
        case .tv: "Shiori (Apple TV)"
        default: "Shiori (iPhone)"
        }
    }

    /// Why Steam actions are unavailable right now, for a line under a disabled button:
    /// calm while a reconnect is within its grace period, what's wrong once it isn't.
    var offlineReason: String? {
        switch state {
        case .loggedOn: return nil
        case .connecting, .reconnecting:
            return showsOffline ? "Can't reach Steam. Retrying…" : "Reconnecting to Steam…"
        case .connectedAnonymously: return "Not signed in to Steam."
        case .signedOut:
            if let resumeError { return resumeError }
            if hasStoredSession, !showsOffline { return "Reconnecting to Steam…" }
            if let connectionError { return "Can't reach Steam: \(connectionError)" }
            return hasStoredSession ? "Can't reach Steam." : "Not signed in to Steam."
        }
    }

    /// Random per-install seed for the machine ID Steam sees. Regenerated after a reinstall.
    private static var deviceSeed: String {
        let key = "steamDeviceSeed"
        if let seed = UserDefaults.standard.string(forKey: key) { return seed }
        let seed = UUID().uuidString
        UserDefaults.standard.set(seed, forKey: key)
        return seed
    }
}

/// A short record of the Steam connection (state changes, sign-in and logon failures; never
/// tokens) in Caches/steam-log.txt, readable from a device's app container.
enum SteamLog {
    static func write(_ line: String) {
        let url = URL.cachesDirectory.appendingPathComponent("steam-log.txt")
        let stamp = ISO8601DateFormatter().string(from: .now)
        let data = Data("\(stamp) \(line)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 200_000 { try? handle.truncate(atOffset: 0) }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
