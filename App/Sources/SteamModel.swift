import Observation
import SteamKit
import UIKit

/// App-side view of the Steam session: connection state, QR sign-in and the owned library.
@MainActor @Observable
final class SteamModel {
    enum SignIn: Equatable {
        case idle
        case starting
        case showing(URL, awaitingConfirmation: Bool)
        case failed(String)
    }

    private(set) var state: SessionState = .signedOut
    private(set) var signIn: SignIn = .idle
    private(set) var library: [AppInfo] = []
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

    func startQRSignIn() {
        signInTask?.cancel()
        resumeError = nil
        signIn = .starting
        signInTask = Task {
            do {
                for try await event in session.beginQRSignIn() {
                    switch event {
                    case let .challenge(url):
                        signIn = .showing(url, awaitingConfirmation: false)
                    case .awaitingConfirmation:
                        if case let .showing(url, _) = signIn { signIn = .showing(url, awaitingConfirmation: true) }
                    case .signedIn:
                        signIn = .idle
                    }
                }
            } catch is CancellationError {
                signIn = .idle
            } catch {
                signIn = .failed((error as? SteamError)?.description ?? error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        signIn = .idle
    }

    func signOut() async {
        await session.signOut()
        library = []
        hasStoredSession = false
    }

    func loadLibrary() async {
        guard !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        defer { isLoadingLibrary = false }
        do {
            library = try await session.ownedApps()
        } catch {
            libraryError = (error as? SteamError)?.description ?? error.localizedDescription
        }
    }

    private static var deviceName: String {
        "VN Hub (\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"))"
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
