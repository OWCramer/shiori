import Foundation

/// Lays out the files of one or more depot manifests under the install root and fills them
/// chunk by chunk. A chunk shared by several files is fetched once. Finished chunks are
/// appended to a journal so a paused or interrupted download picks up where it stopped.
struct DepotWriter {
    let install: DepotInstall
    let jobs: [DepotJob]
    let cdn: CDNClient
    let progress: @Sendable (DownloadProgress) -> Void

    /// One unique chunk of a depot and everywhere it lands.
    struct Work: Sendable {
        var depotIndex: Int
        var chunk: DepotManifest.Chunk
        var destinations: [(path: String, offset: UInt64)]
        var bytesOnDisk: UInt64 { UInt64(chunk.uncompressedLength) * UInt64(destinations.count) }
    }

    func run() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: install.root, withIntermediateDirectories: true)

        var work: [Work] = []
        var journals: [Journal] = []
        var total: UInt64 = 0
        var completed: UInt64 = 0

        for (depotIndex, job) in jobs.enumerated() {
            let journal = try Journal(url: install.journalURL(job.depot))
            journals.append(journal)
            var done = journal.loadedIDs
            var byID: [Data: Work] = [:]
            var order: [Data] = []

            for file in job.manifest.files {
                let url = try install.fileURL(for: file.name)
                if file.isDirectory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    continue
                }
                if file.isSymlink { continue } // Created at the end, once targets exist.
                total += file.size
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if try Self.prepareFile(at: url, size: file.size) {
                    // The file was missing or the wrong size, so the journal can't vouch for it.
                    for chunk in file.chunks { done.remove(chunk.id) }
                }
                for chunk in file.chunks {
                    if byID[chunk.id] == nil {
                        byID[chunk.id] = Work(depotIndex: depotIndex, chunk: chunk, destinations: [])
                        order.append(chunk.id)
                    }
                    byID[chunk.id]!.destinations.append((url.path, chunk.offset))
                }
            }
            for id in order {
                let item = byID[id]!
                if done.contains(id) { completed += item.bytesOnDisk } else { work.append(item) }
            }
        }

        let counter = ProgressCounter(total: total, completed: completed, report: progress)
        await counter.report(.downloading, force: true)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            func addNext() -> Bool {
                guard let item = iterator.next() else { return false }
                let job = jobs[item.depotIndex]
                let journal = journals[item.depotIndex]
                group.addTask {
                    try Task.checkCancellation()
                    let compressed = try await cdn.chunk(depotID: job.depot.depotID, chunk: item.chunk)
                    let data = try Self.decode(compressed, chunk: item.chunk, key: job.key)
                    for destination in item.destinations {
                        try Self.write(data, toPath: destination.path, at: destination.offset)
                    }
                    try await journal.append(item.chunk.id)
                    await counter.add(completed: item.bytesOnDisk, downloaded: UInt64(compressed.count))
                }
                return true
            }
            for _ in 0 ..< CDNClient.maxConcurrentRequests where addNext() {}
            while try await group.next() != nil {
                _ = addNext()
            }
        }
        for journal in journals { await journal.close() }

        await counter.report(.finishing, force: true)
        for job in jobs {
            for file in job.manifest.files where file.isSymlink {
                guard let target = file.linkTarget else { continue }
                let url = try install.fileURL(for: file.name)
                try? fm.removeItem(at: url)
                try fm.createSymbolicLink(atPath: url.path, withDestinationPath: target)
            }
        }
    }

    /// A chunk that decodes cleanly but whose SHA-1 differs from its id is treated as corrupt.
    static func decode(_ compressed: Data, chunk: DepotManifest.Chunk, key: Data) throws -> Data {
        let data = try DepotChunk.process(
            compressed, key: key,
            uncompressedLength: Int(chunk.uncompressedLength), checksum: chunk.checksum
        )
        guard DepotChunk.sha1(data) == chunk.id else { throw DepotChunk.Error.checksumMismatch }
        return data
    }

    /// Creates the file at its final size if needed. Returns true if it had to be created or resized.
    static func prepareFile(at url: URL, size: UInt64) throws -> Bool {
        let path = url.path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let existing = attributes?[.size] as? UInt64, attributes?[.type] as? FileAttributeType == .typeRegular, existing == size {
            return false
        }
        if attributes != nil, attributes?[.type] as? FileAttributeType != .typeRegular {
            try FileManager.default.removeItem(atPath: path)
        }
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return true
    }

    static func write(_ data: Data, toPath path: String, at offset: UInt64) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let result = pwrite(fd, bytes.baseAddress! + written, bytes.count - written, off_t(offset) + off_t(written))
                guard result > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += result
            }
        }
    }
}

/// Append-only list of finished chunk ids (20 bytes each) for one depot manifest.
actor Journal {
    nonisolated let loadedIDs: Set<Data>
    private let handle: FileHandle

    init(url: URL) throws {
        let existing = (try? Data(contentsOf: url)) ?? Data()
        let whole = existing.count - existing.count % 20 // Ignore a torn final write.
        loadedIDs = Set(stride(from: 0, to: whole, by: 20).map { existing.subdata(in: $0 ..< $0 + 20) })
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(whole))
        try handle.seekToEnd()
    }

    func append(_ id: Data) throws {
        try handle.write(contentsOf: id)
    }

    func close() {
        try? handle.close()
    }
}

/// Totals for progress reports, throttled to a few per second.
actor ProgressCounter {
    private let total: UInt64
    private var completed: UInt64
    private var downloaded: UInt64 = 0
    private var lastReport = ContinuousClock.now - .seconds(1)
    private let sink: @Sendable (DownloadProgress) -> Void

    init(total: UInt64, completed: UInt64, report: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.completed = completed
        sink = report
    }

    func add(completed bytes: UInt64, downloaded compressed: UInt64) {
        completed += bytes
        downloaded += compressed
        report(.downloading, force: false)
    }

    func report(_ phase: DownloadProgress.Phase, force: Bool) {
        let now = ContinuousClock.now
        guard force || now - lastReport >= .milliseconds(250) else { return }
        lastReport = now
        sink(DownloadProgress(phase: phase, totalBytes: total, completedBytes: completed, downloadedBytes: downloaded))
    }
}
