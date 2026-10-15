import Foundation
import SwiftProtobuf

/// One WebSocket connection to a CM server.
///
/// Requests that expect a reply are sent as jobs: the packet gets a fresh `jobid_source`
/// and the reply carries it back as `jobid_target`. Everything else the server sends
/// (license list, logged-off notices, ...) is delivered through `unsolicited`.
actor CMConnection {
    let server: CMServer
    nonisolated let unsolicited: AsyncStream<Packet>

    /// Set once `ClientLogOnResponse` succeeds; stamped on every outgoing header.
    var steamID: UInt64 = 0
    var sessionID: Int32 = 0

    private let task: URLSessionWebSocketTask
    private let unsolicitedContinuation: AsyncStream<Packet>.Continuation
    private var jobIDs = JobIDGenerator()
    private var pending: [UInt64: PendingJob] = [:]
    private var receiveLoop: Task<Void, Never>?
    private(set) var isClosed = false

    private struct PendingJob {
        /// Matches replies that come back without a job id (keyed by EMsg instead).
        var replyEMsg: UInt32?
        var replies: [Packet] = []
        var isComplete: @Sendable (Packet) -> Bool
        var continuation: CheckedContinuation<[Packet], Error>
    }

    init(server: CMServer, urlSession: URLSession) {
        self.server = server
        task = urlSession.webSocketTask(with: server.url)
        task.maximumMessageSize = 64 * 1024 * 1024
        (unsolicited, unsolicitedContinuation) = AsyncStream.makeStream()
    }

    /// Opens the socket and says hello. Errors surface when the first send fails.
    func open() async throws {
        task.resume()
        receiveLoop = Task { [weak self, task] in
            while !Task.isCancelled {
                do {
                    let message = try await task.receive()
                    await self?.handle(message)
                } catch {
                    await self?.close()
                    return
                }
            }
        }
        var hello = CMsgClientHello()
        hello.protocolVersion = currentProtocol
        try await send(Packet(emsg: .kEmsgClientHello, message: hello))
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        receiveLoop?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        for job in pending.values { job.continuation.resume(throwing: SteamError.disconnected) }
        pending.removeAll()
        unsolicitedContinuation.finish()
    }

    func send(_ packet: Packet) async throws {
        guard !isClosed else { throw SteamError.disconnected }
        var packet = packet
        packet.header.steamid = steamID
        packet.header.clientSessionid = sessionID
        do {
            try await task.send(.data(packet.encoded()))
        } catch {
            close()
            throw SteamError.disconnected
        }
    }

    /// Sends a packet as a job and collects replies until `isComplete` returns true.
    func call(
        _ packet: Packet,
        replyEMsg: EMsg? = nil,
        timeout: Duration = .seconds(30),
        isComplete: @escaping @Sendable (Packet) -> Bool = { _ in true }
    ) async throws -> [Packet] {
        guard !isClosed else { throw SteamError.disconnected }
        let jobID = jobIDs.next()
        var packet = packet
        packet.header.jobidSource = jobID

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.fail(jobID: jobID, with: SteamError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            pending[jobID] = PendingJob(
                replyEMsg: replyEMsg.map { UInt32($0.rawValue) },
                isComplete: isComplete,
                continuation: continuation
            )
            Task { [packet] in
                do { try await self.send(packet) } catch { self.fail(jobID: jobID, with: error) }
            }
        }
    }

    /// Calls a unified-service method, e.g. `Authentication.BeginAuthSessionViaQR#1`.
    func callService<Response: SwiftProtobuf.Message>(
        _ method: String,
        _ request: some SwiftProtobuf.Message,
        authenticated: Bool,
        timeout: Duration = .seconds(30),
        as _: Response.Type = Response.self
    ) async throws -> Response {
        let packet = try Self.servicePacket(method, request, authenticated: authenticated)
        let replies = try await call(packet, timeout: timeout)
        let reply = replies[0]
        guard reply.eresult == .ok else { throw SteamError.serviceCallFailed(method: method, result: reply.eresult) }
        return try reply.decode()
    }

    /// A unified-service call as it goes on the wire, before the job id is stamped on.
    static func servicePacket(_ method: String, _ request: some SwiftProtobuf.Message, authenticated: Bool) throws -> Packet {
        var header = CMsgProtoBufHeader()
        header.targetJobName = method
        let emsg: EMsg = authenticated ? .kEmsgServiceMethodCallFromClient : .kEmsgServiceMethodCallFromClientNonAuthed
        return try Packet(emsg: emsg, header: header, message: request)
    }

    /// Sends a unified-service notification, which has no reply.
    func notifyService(_ method: String, _ notification: some SwiftProtobuf.Message) async throws {
        var header = CMsgProtoBufHeader()
        header.targetJobName = method
        try await send(Packet(emsg: .kEmsgServiceMethodCallFromClient, header: header, message: notification))
    }

    private func fail(jobID: UInt64, with error: Error) {
        pending.removeValue(forKey: jobID)?.continuation.resume(throwing: error)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case let .data(data) = message else { return }
        let packets: [Packet]
        do {
            guard let packet = try Packet.decode(data) else { return }
            packets = try Packet.unpack(packet)
        } catch {
            return // Malformed frame: drop it rather than tear down the session.
        }
        for packet in packets { route(packet) }
    }

    private func route(_ packet: Packet) {
        let target = packet.header.hasJobidTarget ? packet.header.jobidTarget : nil
        let jobID = target.flatMap { pending[$0] != nil ? $0 : nil }
            ?? pending.first { $0.value.replyEMsg == packet.emsg }?.key

        guard let jobID, var job = pending[jobID] else {
            unsolicitedContinuation.yield(packet)
            return
        }
        job.replies.append(packet)
        if job.isComplete(packet) {
            pending.removeValue(forKey: jobID)
            job.continuation.resume(returning: job.replies)
        } else {
            pending[jobID] = job
        }
    }
}
