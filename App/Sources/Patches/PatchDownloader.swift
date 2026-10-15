// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import CommonCrypto
import CryptoKit
import Foundation

/// Downloads one patch file from a plain link, Google Drive or MEGA into a file, with
/// progress and resume (a partial download is kept and continued with a Range request). MEGA
/// files are decrypted as they arrive (AES-128-CTR with the key in the link) and checked
/// against MEGA's MAC at the end. Every file's SHA-256 is computed on the way.
final class PatchDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case unsupportedLink
        case gone(String)
        case quota
        case server(Int)
        case notAFile
        case megaIntegrity

        var errorDescription: String? {
            switch self {
            case .unsupportedLink: "Shiori can't download from this link."
            case let .gone(detail): "The file is no longer there (\(detail))."
            case .quota: "MEGA's download limit for this network is used up; try again in a few hours."
            case let .server(code): "The server returned an error (\(code))."
            case .notAFile: "The link opened a web page instead of the file."
            case .megaIntegrity: "The file from MEGA didn't match its checksum; it was discarded."
            }
        }
    }

    struct Result: Sendable {
        var file: URL
        var name: String
        var size: Int64
        var sha256: String
    }

    /// Bytes so far and the total (0 when unknown).
    typealias Progress = @Sendable (Int64, Int64) -> Void

    private let destination: URL
    private let progress: Progress
    private var session: URLSession!
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var expected: Int64 = 0
    private var transform: ((Data, Int64) -> Data)?
    private var continuation: CheckedContinuation<Void, Error>?
    private var responseError: Error?

    /// `destination` keeps the partial file between attempts.
    init(destination: URL, progress: @escaping Progress) {
        self.destination = destination
        self.progress = progress
        super.init()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"]
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    /// Downloads `url` (on `host`: direct, gdrive or mega).
    func download(host: String, url: URL) async throws -> Result {
        switch host {
        case "direct":
            let link = PatchLinks.directURL(url)
            return try await fetch(link, name: link.lastPathComponent)
        case "gdrive":
            return try await drive(url)
        case "mega":
            return try await mega(url)
        case "wetransfer":
            return try await wetransfer(url)
        default:
            throw Failure.unsupportedLink
        }
    }

    // MARK: Plain HTTP with resume

    private func fetch(_ url: URL, name: String, transform: ((Data, Int64) -> Data)? = nil, size: Int64 = 0) async throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: destination.path) { fm.createFile(atPath: destination.path, contents: nil) }
        let existing = ((try? fm.attributesOfItem(atPath: destination.path)[.size]) as? Int64) ?? 0
        var request = URLRequest(url: url)
        if existing > 0 { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        written = existing
        expected = size
        self.transform = transform
        responseName = nil
        handle = try FileHandle(forWritingTo: destination)
        try handle?.seekToEnd()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                session.dataTask(with: request).resume()
            }
        } onCancel: { [session] in
            session?.getAllTasks { $0.forEach { $0.cancel() } }
        }
        try handle?.close()
        handle = nil
        return Result(file: destination, name: responseName ?? name, size: written,
                      sha256: try Self.sha256(of: destination))
    }

    private var responseName: String?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.allow); return }
        switch http.statusCode {
        case 200:
            if written > 0 {
                // The server ignored the Range: start over.
                try? handle?.truncate(atOffset: 0)
                written = 0
            }
        case 206:
            break
        case 416:
            // Already complete.
            completionHandler(.cancel)
            finish(nil)
            return
        case 404, 410:
            responseError = Failure.gone("HTTP \(http.statusCode)")
            completionHandler(.cancel)
            return
        default:
            responseError = Failure.server(http.statusCode)
            completionHandler(.cancel)
            return
        }
        if (http.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/html") {
            responseError = Failure.notAFile
            completionHandler(.cancel)
            return
        }
        if expected == 0, http.expectedContentLength > 0 { expected = written + http.expectedContentLength }
        responseName = Self.fileName(from: http)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let chunk = transform?(data, written) ?? data
        do { try handle?.write(contentsOf: chunk) } catch {
            responseError = error
            dataTask.cancel()
            return
        }
        written += Int64(chunk.count)
        progress(written, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(responseError ?? error)
    }

    private func finish(_ error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private static func fileName(from response: HTTPURLResponse) -> String? {
        guard let disposition = response.value(forHTTPHeaderField: "Content-Disposition") else { return nil }
        if let range = disposition.range(of: "filename*=UTF-8''") {
            return disposition[range.upperBound...].split(separator: ";").first.map { String($0).removingPercentEncoding ?? String($0) }
        }
        if let range = disposition.range(of: "filename=") {
            return disposition[range.upperBound...].split(separator: ";").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return nil
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1 << 22), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Google Drive

    static func driveFileID(_ url: URL) -> String? {
        let text = url.absoluteString
        if let range = text.range(of: #"/file/d/([\w-]+)"#, options: .regularExpression) {
            return String(text[range].dropFirst("/file/d/".count))
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value
    }

    private func drive(_ url: URL) async throws -> Result {
        guard let id = Self.driveFileID(url) else { throw Failure.unsupportedLink }
        // `confirm=t` skips the "can't scan this file for viruses" page for large files.
        let direct = URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")!
        do {
            return try await fetch(direct, name: id)
        } catch Failure.notAFile {
            // An older warning page: follow its form.
            let (data, _) = try await URLSession.shared.data(from: direct)
            let page = String(decoding: data, as: UTF8.self)
            guard let next = Self.driveFormURL(page) else { throw Failure.notAFile }
            return try await fetch(next, name: id)
        }
    }

    private static func driveFormURL(_ page: String) -> URL? {
        guard let action = page.firstMatch(of: #/<form[^>]+action="([^"]+)"/#)?.1 else { return nil }
        var components = URLComponents(string: String(action).replacingOccurrences(of: "&amp;", with: "&"))
        components?.queryItems = page.matches(of: #/name="([^"]+)" value="([^"]*)"/#).map {
            URLQueryItem(name: String($0.1), value: String($0.2))
        }
        return components?.url
    }

    // MARK: WeTransfer

    /// (transfer id, security hash) from wetransfer.com/downloads/ID/[recipient/]HASH, after
    /// following a we.tl short link.
    static func wetransferLink(_ url: URL) async throws -> (id: String, hash: String)? {
        var resolved = url
        if url.host?.lowercased() == "we.tl" {
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            let (_, response) = try await URLSession.shared.data(for: request)
            resolved = response.url ?? url
        }
        let text = resolved.absoluteString
        guard let match = text.firstMatch(of: #//downloads/([0-9a-f]+)/(?:[0-9a-f]+/)?([0-9a-f]+)/#) else { return nil }
        return (String(match.1), String(match.2))
    }

    private func wetransfer(_ url: URL) async throws -> Result {
        guard let link = try await Self.wetransferLink(url) else { throw Failure.unsupportedLink }
        var request = URLRequest(url: URL(string: "https://wetransfer.com/api/v4/transfers/\(link.id)/download")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["security_hash": link.hash, "intent": "entire_transfer"])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let direct = (object["direct_link"] as? String).flatMap(URL.init(string:)) else {
            throw Failure.gone(status == 404 ? "the transfer has expired" : "WeTransfer answered \(status)")
        }
        // The signed link expires within minutes; a resumed download asks for a new one.
        return try await fetch(direct, name: direct.lastPathComponent)
    }

    // MARK: MEGA

    /// (file id, key) from mega.nz/file/ID#KEY or the older mega.nz/#!ID!KEY.
    static func megaLink(_ url: URL) -> (id: String, key: String)? {
        let text = url.absoluteString
        if let match = text.firstMatch(of: ##/mega\.(?:co\.)?nz/file/([\w-]+)#([\w-]+)/##) { return (String(match.1), String(match.2)) }
        if let match = text.firstMatch(of: ##/mega\.(?:co\.)?nz/#!([\w-]+)!([\w-]+)/##) { return (String(match.1), String(match.2)) }
        return nil
    }

    private func mega(_ url: URL) async throws -> Result {
        guard let link = Self.megaLink(url), let keyData = Self.base64URL(link.key), keyData.count == 32 else {
            throw Failure.unsupportedLink
        }
        let words = keyData.withUnsafeBytes { raw in (0..<8).map { UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
        let aesKey = Self.bytes([words[0] ^ words[4], words[1] ^ words[5], words[2] ^ words[6], words[3] ^ words[7]])
        let nonce = Self.bytes([words[4], words[5]])
        let metaMAC = Self.bytes([words[6], words[7]])

        var request = URLRequest(url: URL(string: "https://g.api.mega.co.nz/cs?id=\(Int.random(in: 0..<1_000_000))")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [["a": "g", "g": 1, "ssl": 2, "p": link.id]])
        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try JSONSerialization.jsonObject(with: data)
        if let code = (reply as? [Any])?.first as? Int ?? reply as? Int {
            if code == -17 || code == -18 { throw Failure.quota }
            throw Failure.gone("MEGA error \(code)")
        }
        guard let info = (reply as? [Any])?.first as? [String: Any],
              let downloadURL = (info["g"] as? String).flatMap(URL.init(string:)) else { throw Failure.gone("no download link") }
        let size = (info["s"] as? NSNumber)?.int64Value ?? 0
        var name = link.id
        if let attributes = (info["at"] as? String).flatMap(Self.base64URL),
           let plain = Self.aesCBC(attributes, key: aesKey),
           let json = String(data: plain, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0")),
           json.hasPrefix("MEGA{"),
           let object = try? JSONSerialization.jsonObject(with: Data(json.dropFirst(4).utf8)) as? [String: Any],
           let n = object["n"] as? String { name = n }

        let result = try await fetch(downloadURL, name: name, transform: { chunk, offset in
            Self.aesCTR(chunk, key: aesKey, nonce: nonce, offset: offset)
        }, size: size)
        guard try Self.megaMAC(of: result.file, key: aesKey, nonce: nonce) == metaMAC else {
            try? FileManager.default.removeItem(at: result.file)
            throw Failure.megaIntegrity
        }
        return Result(file: result.file, name: name, size: result.size, sha256: result.sha256)
    }

    private static func bytes(_ words: [UInt32]) -> Data {
        var data = Data()
        for word in words { withUnsafeBytes(of: word.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    private static func base64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: ",", with: "")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        return Data(base64Encoded: s)
    }

    private static func aesCBC(_ data: Data, key: Data, iv: Data = Data(count: 16), encrypt: Bool = false) -> Data? {
        var out = Data(count: data.count + 16)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in data.withUnsafeBytes { d in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                    k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, o.count, &moved)
        } } } }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// AES-CTR from `offset` bytes into the file (the counter is the nonce, then the block number).
    static func aesCTR(_ data: Data, key: Data, nonce: Data, offset: Int64) -> Data {
        let blockIndex = UInt64(offset / 16)
        let skip = Int(offset % 16)
        var counter = nonce
        withUnsafeBytes(of: blockIndex.bigEndian) { counter.append(contentsOf: $0) }
        var cryptor: CCCryptorRef?
        counter.withUnsafeBytes { c in key.withUnsafeBytes { k in
            _ = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), c.baseAddress, k.baseAddress, key.count, nil, 0, 0,
                                        CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
        } }
        defer { CCCryptorRelease(cryptor) }
        let input = Data(count: skip) + data
        var out = Data(count: input.count)
        var moved = 0
        out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in
            _ = CCCryptorUpdate(cryptor, i.baseAddress, input.count, o.baseAddress, o.count, &moved)
        } }
        return out.dropFirst(skip)
    }

    /// MEGA's condensed MAC: a CBC-MAC per chunk (128 KB, 256 KB, ... growing to 1 MB) seeded
    /// with the nonce twice, CBC-chained over the chunks, then folded to 8 bytes.
    static func megaMAC(of file: URL, key: Data, nonce: Data) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var fileMAC = Data(count: 16)
        var chunkSize = 128 * 1024
        let seed = nonce + nonce
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var padded = chunk
            if padded.count % 16 != 0 { padded.append(Data(count: 16 - padded.count % 16)) }
            // CBC-MAC: the last block of a CBC encryption seeded with the nonce.
            guard let encrypted = aesCBC(padded, key: key, iv: seed, encrypt: true) else { break }
            let chunkMAC = encrypted.subdata(in: (padded.count - 16)..<padded.count)
            let mixed = Data(zip(fileMAC, chunkMAC).map { $0 ^ $1 })
            fileMAC = aesCBC(mixed, key: key, encrypt: true)?.prefix(16) ?? fileMAC
            if chunkSize < 1024 * 1024 { chunkSize += 128 * 1024 }
        }
        let w = fileMAC.withUnsafeBytes { raw in (0..<4).map { UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) } }
        return bytes([w[0] ^ w[1], w[2] ^ w[3]])
    }
}
