import Foundation
import Network
import OSLog

/// A one-shot bridge around an `NWConnection.send` completion. Network's
/// callback can arrive after task cancellation (or not arrive at all when a
/// UDP connection wedges), so the bridge owns the continuation and guarantees
/// exactly one resume.
private final class VoiceUDPSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    /// Returns false when cancellation or a connection completion won the
    /// race before the caller finished installing its continuation.
    @discardableResult
    func install(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        let completedResult = result
        if completedResult == nil {
            self.continuation = continuation
        }
        lock.unlock()

        if let completedResult {
            continuation.resume(with: completedResult)
            return false
        }
        return true
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }
}

/// UDP transport for Discord voice. Owns an `NWConnection`, handles the
/// initial IP discovery handshake, and sends RTP packets.
actor VoiceUDPTransport {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.udp")

    struct DiscoveredAddress: Sendable, Equatable {
        let ip: String
        let port: UInt16
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let pathMonitorQueue: DispatchQueue
    private var ready: Bool = false
    private var isStopped = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    /// Every `NWConnection.send` continuation currently waiting for Network.
    /// `stop()` resolves all of these itself so no structured caller remains
    /// stranded if Network fails to call a content-processed completion.
    private var pendingSends: [UUID: VoiceUDPSendCompletion] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastObservedPath: NWPath?
    private var onNetworkPathChange: (@Sendable (VoiceNetworkPathSnapshot, VoiceNetworkPathSnapshot) async -> Void)?

    init(host: String, port: UInt16) {
        self.queue = DispatchQueue(label: "com.swiftbot.voice.udp")
        self.pathMonitorQueue = DispatchQueue(label: "com.swiftbot.voice.udp.path")
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.connection = NWConnection(host: nwHost, port: nwPort, using: .udp)
    }

    func start() async throws {
        guard !isStopped else { throw VoicePipelineError.socketClosed }
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateChange(state) }
        }
        startPathMonitor()
        connection.start(queue: queue)
        try await awaitReady()
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        // Drop handlers before cancelling so any in-flight dispatch_source
        // timers / completions don't reach back into a deallocated actor and
        // trip a PAC failure on Apple Silicon.
        connection.stateUpdateHandler = nil
        stopPathMonitor()
        ready = false
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: VoicePipelineError.socketClosed)
        }
        resolvePendingSends(with: VoicePipelineError.socketClosed)
        connection.cancel()
    }

    /// Perform the 74-byte IP discovery handshake. Returns the bot's
    /// externally-visible IP/port as observed by Discord.
    func discoverAddress(ssrc: UInt32) async throws -> DiscoveredAddress {
        var probe = Data(count: 74)
        // type = 0x0001 (request), length = 70
        probe[0] = 0x00
        probe[1] = 0x01
        probe[2] = 0x00
        probe[3] = 0x46
        probe[4] = UInt8((ssrc >> 24) & 0xff)
        probe[5] = UInt8((ssrc >> 16) & 0xff)
        probe[6] = UInt8((ssrc >> 8) & 0xff)
        probe[7] = UInt8(ssrc & 0xff)

        // Kick off the receive BEFORE the send so we don't race the response.
        async let response: Data = receiveDiscoveryReply()
        Self.logger.info("UDP probe sending ssrc=\(ssrc) (\(probe.count) bytes)")
        try await send(probe)
        let data = try await response
        Self.logger.info("UDP probe got reply (\(data.count) bytes)")
        guard data.count >= 8 else {
            throw VoicePipelineError.ipDiscoveryFailed("response too short: \(data.count) bytes (hex: \(data.map { String(format: "%02x", $0) }.joined()))")
        }
        // Some Discord regions return a different-length response. Parse
        // defensively: address bytes are everything between offset 8 and the
        // last 2 bytes (which are the port, big-endian).
        let portOffset = data.count - 2
        let ipBytes = data[8..<portOffset]
        let ipString = String(bytes: ipBytes.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        let port = (UInt16(data[portOffset]) << 8) | UInt16(data[portOffset + 1])
        guard !ipString.isEmpty else {
            throw VoicePipelineError.ipDiscoveryFailed("empty IP in \(data.count)-byte response")
        }
        Self.logger.info("UDP discovery → \(ipString):\(port)")
        return DiscoveredAddress(ip: ipString, port: port)
    }

    func send(_ data: Data) async throws {
        guard !isStopped else { throw VoicePipelineError.socketClosed }
        let id = UUID()
        let completion = VoiceUDPSendCompletion()
        pendingSends[id] = completion
        defer { pendingSends[id] = nil }

        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Cancellation may have already run before the continuation
                // was installed. In that case, do not issue a stale datagram.
                guard completion.install(continuation), !completion.isResolved else { return }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        completion.resolve(.failure(error))
                    } else {
                        completion.resolve(.success(()))
                    }
                })
            }
        } onCancel: {
            // Resuming first makes caller cancellation a real escape hatch;
            // the actor task below tears down the underlying socket and wakes
            // any sibling UDP sends that Network has also left pending.
            completion.resolve(.failure(CancellationError()))
            Task { [weak self] in
                await self?.abortAfterCancelledSend()
            }
        }
    }

    func setOnNetworkPathChange(
        _ handler: @escaping @Sendable (VoiceNetworkPathSnapshot, VoiceNetworkPathSnapshot) async -> Void
    ) {
        onNetworkPathChange = handler
    }

    // MARK: - Private

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !isStopped else { return }
            ready = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        case .failed(let error):
            terminate(with: error)
        case .cancelled:
            terminate(with: VoicePipelineError.socketClosed)
        default:
            break
        }
    }

    private func awaitReady() async throws {
        if ready { return }
        if isStopped { throw VoicePipelineError.socketClosed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(continuation)
        }
    }

    /// A cancelled send means this one-shot UDP transport is no longer trusted.
    /// Cancelling it also makes a stuck Network continuation harmless because
    /// `stop()` synchronously resolves every registered send.
    private func abortAfterCancelledSend() {
        guard !isStopped else { return }
        Self.logger.warning("Cancelling UDP transport after a cancelled datagram send.")
        stop()
    }

    private func terminate(with error: Error) {
        guard !isStopped else { return }
        isStopped = true
        ready = false
        stopPathMonitor()
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters { waiter.resume(throwing: error) }
        resolvePendingSends(with: error)
    }

    private func resolvePendingSends(with error: Error) {
        let pending = Array(pendingSends.values)
        pendingSends.removeAll()
        for completion in pending {
            completion.resolve(.failure(error))
        }
    }

    // MARK: - Network path monitoring

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.handlePathUpdate(path) }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func stopPathMonitor() {
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastObservedPath = nil
        onNetworkPathChange = nil
    }

    /// Treat the monitor's initial callback as an observation, not a fault.
    /// Later callbacks are compared as full `NWPath` values so normal repeated
    /// notifications do not cause voice recovery, while a genuine route change
    /// (including a network transition that keeps the same interface type) is
    /// still surfaced to the owning playback session.
    private func handlePathUpdate(_ path: NWPath) async {
        guard !isStopped else { return }
        guard let previous = lastObservedPath else {
            lastObservedPath = path
            return
        }
        guard previous != path else { return }
        lastObservedPath = path
        guard let onNetworkPathChange else { return }
        await onNetworkPathChange(
            Self.pathSnapshot(for: previous),
            Self.pathSnapshot(for: path)
        )
    }

    private static func pathSnapshot(for path: NWPath) -> VoiceNetworkPathSnapshot {
        let interfaceTypes: [(NWInterface.InterfaceType, VoiceNetworkPathSnapshot.InterfaceType)] = [
            (.other, .other),
            (.wifi, .wifi),
            (.cellular, .cellular),
            (.wiredEthernet, .wiredEthernet),
            (.loopback, .loopback)
        ]
        let activeInterfaceTypes = interfaceTypes.compactMap { networkType, snapshotType in
            path.usesInterfaceType(networkType) ? snapshotType : nil
        }
        return VoiceNetworkPathSnapshot(
            status: pathStatus(for: path.status),
            activeInterfaceTypes: activeInterfaceTypes,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS
        )
    }

    private static func pathStatus(for status: NWPath.Status) -> VoiceNetworkPathSnapshot.Status {
        switch status {
        case .satisfied:
            return .satisfied
        case .unsatisfied:
            return .unsatisfied
        case .requiresConnection:
            return .requiresConnection
        @unknown default:
            return .unknown
        }
    }

    private func receiveDiscoveryReply() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receiveMessage { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: VoicePipelineError.ipDiscoveryFailed("empty response"))
                }
            }
        }
    }
}
