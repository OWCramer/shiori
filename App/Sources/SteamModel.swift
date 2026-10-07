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
    /// Owned games, from the on-disk cache until Steam answers.
    private(set) var library: [LibraryGame] = LibraryCache.load()
    private(set) var isLoadingLibrary = false
    private(set) var libraryError: String?
    private(set) var resumeError: String?

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
        library = []
        LibraryCache.clear()
        hasStoredSession = false
    }

    func loadLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            library = try await session.ownedApps().map(LibraryGame.init)
            LibraryCache.save(library)
        } catch {
            libraryError = Self.message(for: error)
        }
    }

    private static var deviceName: String {
        "Shiori (\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))"
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
