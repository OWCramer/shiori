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
    private(set) var isLoadingLibrary = false
    private(set) var libraryError: String?
    private(set) var resumeError: String?
    /// Why the stored session didn't log on at launch, if it failed for another reason
    /// (offline, Steam unreachable, the Keychain); SteamSession may still be retrying.
    private(set) var connectionError: String?

    let session: SteamSession
    private var signInTask: Task<Void, Never>?

    init() {
        session = SteamSession(
            configuration: SteamConfiguration(deviceName: Self.deviceName, deviceSeed: Self.deviceSeed),
            store: KeychainSessionStore(service: "com.owencramer.vnhub.steam")
        )
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
            hasStoredSession = await session.storedAccountName != nil
            if isLoggedOn, !wasLoggedOn { await loadLibrary() }
        }
    }

    private func resume() async {
        hasStoredSession = await session.storedAccountName != nil
        guard hasStoredSession else { return }
        do {
            try await session.resume()
        } catch SteamError.sessionExpired {
            resumeError = SteamError.sessionExpired.description
        } catch {
            // Offline or Steam unreachable: SteamSession keeps retrying in the background.
            connectionError = Self.message(for: error)
        }
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
                    }
                }
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed(Self.message(for: error))
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
            libraryError = Self.message(for: error)
        }
    }

    private static var deviceName: String {
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: "Shiori (iPad)"
        case .tv: "Shiori (Apple TV)"
        default: "Shiori (iPhone)"
        }
    }

    /// Why Steam actions are unavailable right now, for a line under a disabled button.
    var offlineReason: String? {
        switch state {
        case .loggedOn: return nil
        case .connecting: return "Connecting to Steam…"
        case let .reconnecting(attempt): return "Reconnecting to Steam (attempt \(attempt))" + (connectionError.map { ": \($0)" } ?? "…")
        case .connectedAnonymously: return "Not signed in to Steam."
        case .signedOut:
            if let resumeError { return resumeError }
            if let connectionError { return "Not connected to Steam: \(connectionError)" }
            return hasStoredSession ? "Not connected to Steam." : "Not signed in to Steam."
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
