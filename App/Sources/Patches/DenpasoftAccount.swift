#if os(iOS)
import Observation
import SwiftUI
import WebKit

/// The player's Denpasoft account, for the patches it sells or gives away (many 18+ DLCs are
/// free but still need an account to claim). Denpasoft has no customer API and sits behind a
/// Cloudflare check, so Shiori works the way a browser does: the player signs in on
/// Denpasoft's own page in an in-app web view (Shiori never sees the password; the session
/// cookie stays in WebKit's store on this device), Shiori reads "Account › Downloads" in a
/// hidden web view with that session, and downloads files through it.
@MainActor
@Observable
final class DenpasoftAccount: NSObject {
    struct Download: Hashable, Sendable {
        /// The product's URL slug (denpasoft.com/product/<slug>), when the page links it.
        var productSlug: String?
        var productName: String
        var fileName: String
        var url: URL
    }

    static let shared = DenpasoftAccount()
    static let site = URL(string: "https://denpasoft.com")!
    static let account = URL(string: "https://denpasoft.com/account/")!
    static let downloadsPage = URL(string: "https://denpasoft.com/account/downloads")!

    /// Whether the last check found a signed-in session (remembered between launches).
    private(set) var isSignedIn = UserDefaults.standard.bool(forKey: "denpasoftSignedIn") {
        didSet { UserDefaults.standard.set(isSignedIn, forKey: "denpasoftSignedIn") }
    }
    /// The account's downloads, from the last read of its Downloads page.
    private(set) var downloads: [Download] = []
    private(set) var isLoading = false
    private var loadedAt: Date?

    /// One web view, hidden, shares the sign-in sheet's cookies (the default data store).
    @ObservationIgnored private var readerView: WKWebView?
    private var reader: WKWebView {
        if let readerView { return readerView }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: DenpasoftAccount.configuration())
        readerView = view
        return view
    }

    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        return configuration
    }

    /// The download for a Denpasoft product the patch list names, if the account has it.
    func download(forProductURL url: String) -> Download? {
        guard let slug = Self.slug(url) else { return nil }
        if let match = downloads.first(where: { $0.productSlug == slug }) { return match }
        // Without a product link on the Downloads page, match the name the slug was made from.
        let key = slug.replacingOccurrences(of: "-", with: "")
        return downloads.first { Self.normalised($0.productName) == key }
    }

    static func slug(_ url: String) -> String? {
        guard let range = url.range(of: "/product/") ?? url.range(of: "/products/") else { return nil }
        return url[range.upperBound...].split(whereSeparator: { "/?#".contains($0) }).first.map(String.init)
    }

    private static func normalised(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Reads the Downloads page again (at most once a minute unless `force`).
    func refresh(force: Bool = false) async {
        guard isSignedIn, !isLoading else { return }
        if !force, let loadedAt, Date().timeIntervalSince(loadedAt) < 60 { return }
        isLoading = true
        defer { isLoading = false }
        guard let html = await load(Self.downloadsPage) else { return }
        if html.signedOut {
            isSignedIn = false
            downloads = []
            return
        }
        downloads = html.downloads
        loadedAt = Date()
    }

    /// Checks the session after the sign-in sheet closes.
    func checkSession() async {
        guard let page = await load(Self.account) else { return }
        isSignedIn = !page.signedOut
        if isSignedIn { await refresh(force: true) } else { downloads = [] }
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                               for: records.filter { $0.displayName.contains("denpasoft") })
        isSignedIn = false
        downloads = []
    }

    // MARK: Reading a page

    private struct Page {
        var signedOut: Bool
        var downloads: [Download]
    }

    private var navigation: CheckedContinuation<Void, Never>?

    /// Loads `url` in the hidden web view, waits for it (and any Cloudflare check) to settle,
    /// then reads it with a script.
    private func load(_ url: URL) async -> Page? {
        reader.navigationDelegate = self
        reader.load(URLRequest(url: url))
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            guard !reader.isLoading else { continue }
            let title = (try? await reader.evaluateJavaScript("document.title") as? String) ?? ""
            if title.contains("Just a moment") { continue }
            break
        }
        let script = """
        (() => {
          const text = document.body ? document.body.innerText : '';
          const onLogin = location.pathname.startsWith('/account/login');
          const loginForm = !!document.querySelector('input[type=password]');
          const signedOut = onLogin || (loginForm && !document.querySelector('a[href*="logout"]'));
          const rows = [];
          for (const a of document.querySelectorAll('a[href*="download_file="]')) {
            let box = a;
            for (let i = 0; i < 6 && box.parentElement; i++) {
              if (box.querySelector('a[href*="/product/"]') || box.tagName === 'TR') break;
              box = box.parentElement;
            }
            const product = box.querySelector('a[href*="/product/"]');
            const name = (product ? product.innerText : (box.innerText || '')).trim().split('\\n')[0];
            rows.push({ href: a.href, file: (a.innerText || a.getAttribute('download') || '').trim(),
                        product: product ? product.href : null, name });
          }
          return JSON.stringify({ signedOut, rows });
        })()
        """
        guard let json = try? await reader.evaluateJavaScript(script) as? String,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let rows = object["rows"] as? [[String: Any]] ?? []
        let downloads = rows.compactMap { row -> Download? in
            guard let href = row["href"] as? String, let url = URL(string: href) else { return nil }
            let product = row["product"] as? String
            return Download(productSlug: product.flatMap(Self.slug), productName: row["name"] as? String ?? "",
                            fileName: row["file"] as? String ?? "", url: url)
        }
        return Page(signedOut: object["signedOut"] as? Bool ?? true, downloads: downloads)
    }

    // MARK: Downloading through the session

    private var downloadTargets: [ObjectIdentifier: (destination: URL, continuation: CheckedContinuation<URL, Error>)] = [:]
    private var progressObservers: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var progressHandlers: [ObjectIdentifier: (Int64, Int64) -> Void] = [:]

    enum Failure: LocalizedError {
        case notInAccount
        case signedOut

        var errorDescription: String? {
            switch self {
            case .notInAccount: "This patch isn't in your Denpasoft downloads yet. Claim it on its Denpasoft page first."
            case .signedOut: "Sign in to Denpasoft in Settings first."
            }
        }
    }

    /// Downloads the account's file into `destination` through the signed-in web session.
    func fetch(_ download: Download, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws -> URL {
        guard isSignedIn else { throw Failure.signedOut }
        try? FileManager.default.removeItem(at: destination)
        let wkDownload = await reader.startDownload(using: URLRequest(url: download.url))
        wkDownload.delegate = self
        let id = ObjectIdentifier(wkDownload)
        progressHandlers[id] = progress
        progressObservers[id] = wkDownload.progress.observe(\.completedUnitCount) { [weak self] p, _ in
            let done = p.completedUnitCount, total = p.totalUnitCount
            Task { @MainActor in self?.progressHandlers[id]?(done, max(total, 0)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloadTargets[id] = (destination, continuation)
            }
        } onCancel: {
            Task { @MainActor in wkDownload.cancel { _ in } }
        }
    }

    fileprivate func finish(_ download: WKDownload, error: Error?) {
        let id = ObjectIdentifier(download)
        guard let target = downloadTargets.removeValue(forKey: id) else { return }
        progressObservers[id] = nil
        progressHandlers[id] = nil
        if let error { target.continuation.resume(throwing: error) } else { target.continuation.resume(returning: target.destination) }
    }

    fileprivate func destination(for download: WKDownload) -> URL? {
        downloadTargets[ObjectIdentifier(download)]?.destination
    }
}

extension DenpasoftAccount: WKNavigationDelegate, WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                              suggestedFilename: String) async -> URL? {
        await MainActor.run {
            guard let base = destination(for: download) else { return nil }
            // Keep the server's file name (its extension says how to unpack it).
            let named = base.deletingLastPathComponent().appendingPathComponent(base.lastPathComponent + "-" + suggestedFilename)
            if let entry = downloadTargets[ObjectIdentifier(download)] {
                downloadTargets[ObjectIdentifier(download)] = (named, entry.continuation)
            }
            try? FileManager.default.removeItem(at: named)
            return named
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        Task { @MainActor in finish(download, error: nil) }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        Task { @MainActor in finish(download, error: error) }
    }
}

/// Denpasoft's own pages in the app, sharing the account's session: signing in, and claiming
/// a free patch (a $0 checkout).
struct DenpasoftWebSheet: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DenpasoftWebView(url: url)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .onDisappear { Task { await DenpasoftAccount.shared.checkSession() } }
    }
}

private struct DenpasoftWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: DenpasoftAccount.configuration())
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
