import CryptoKit
import Foundation

/// The result of re-hashing an install against its manifests.
public struct VerifyReport: Equatable, Sendable {
    public enum Problem: Equatable, Sendable {
        case missing
        case wrongSize(expected: UInt64, actual: UInt64)
        /// Content differs from Steam's (expected after patching `base/` directly).
        case modified
    }

    public var checkedFiles: Int
    public var checkedBytes: UInt64
    /// Relative path → what's wrong, for every file that doesn't match.
    public var problems: [String: Problem]
    /// Files under the root that no manifest lists.
    public var extraFiles: [String]

    public var isClean: Bool { problems.isEmpty }
}

public struct VerifyProgress: Equatable, Sendable {
    public var totalBytes: UInt64
    public var checkedBytes: UInt64
    public var fraction: Double { totalBytes == 0 ? 0 : Double(checkedBytes) / Double(totalBytes) }
}

extension DepotInstall {
    public enum VerifyError: Error, Equatable {
        /// There is no finished install to compare against.
        case notInstalled
    }

    /// Re-hashes every installed file chunk by chunk with SHA-1 against the saved manifests and
    /// reports what differs. Never changes anything on disk. Works offline.
    public func verify(progress: @escaping @Sendable (VerifyProgress) -> Void = { _ in }) async throws -> VerifyReport {
        guard let depots = installedDepots else { throw VerifyError.notInstalled }
        let manifests = try depots.map { depot in
            guard let manifest = loadManifest(depot) else { throw VerifyError.notInstalled }
            return manifest
        }
        let files = manifests.flatMap(\.files).filter { !$0.isDirectory && !$0.isSymlink }
        let total = files.reduce(0) { $0 + $1.size }

        var report = VerifyReport(checkedFiles: 0, checkedBytes: 0, problems: [:], extraFiles: [])
        var lastReport = ContinuousClock.now
        for file in files {
            try Task.checkCancellation()
            report.checkedFiles += 1
            defer {
                report.checkedBytes += file.size
                let now = ContinuousClock.now
                if now - lastReport >= .milliseconds(250) {
                    lastReport = now
                    progress(VerifyProgress(totalBytes: total, checkedBytes: report.checkedBytes))
                }
            }
            let url = try fileURL(for: file.name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else {
                report.problems[file.name] = .missing
                continue
            }
            let size = attributes[.size] as? UInt64 ?? 0
            guard size == file.size else {
                report.problems[file.name] = .wrongSize(expected: file.size, actual: size)
                continue
            }
            if try !Self.chunksMatch(file, at: url) { report.problems[file.name] = .modified }
        }
        progress(VerifyProgress(totalBytes: total, checkedBytes: total))

        let listed = Set(manifests.flatMap(\.files).map { $0.name.lowercased() })
        report.extraFiles = Self.relativeFiles(under: root).filter { !listed.contains($0.lowercased()) }.sorted()
        return report
    }

    private static func chunksMatch(_ file: DepotManifest.File, at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        for chunk in file.chunks {
            try handle.seek(toOffset: chunk.offset)
            let data = try handle.read(upToCount: Int(chunk.uncompressedLength)) ?? Data()
            guard data.count == Int(chunk.uncompressedLength), Data(Insecure.SHA1.hash(data: data)) == chunk.id else {
                return false
            }
        }
        return true
    }

    private static func relativeFiles(under root: URL) -> [String] {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { continue }
            paths.append(String(path.dropFirst(rootPath.count + 1)))
        }
        return paths
    }
}
