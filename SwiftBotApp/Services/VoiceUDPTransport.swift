import Foundation
import Network
import OSLog

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
    private var ready: Bool = false
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []

    init(host: String, port: UInt16) {
        self.queue = DispatchQueue(label: "com.swiftbot.voice.udp")
        let nwHost = NWEndpoint.Host(host)
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        self.connection = NWConnection(host: nwHost, port: nwPort, using: .udp)
    }

    func start() async throws {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleStateChange(state) }
        }
        connection.start(queue: queue)
        try await awaitReady()
    }

    func stop() {
        connection.cancel()
        ready = false
        let waiters = readyWaiters
        readyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: VoicePipelineError.socketClosed)
        }
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Private

    private func handleStateChange(_ state: NWConnection.State) {
        switch state {
        case .ready:
            ready = true
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        case .failed(let error):
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: error) }
        case .cancelled:
            let waiters = readyWaiters
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: VoicePipelineError.socketClosed) }
        default:
            break
        }
    }

    private func awaitReady() async throws {
        if ready { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyWaiters.append(continuation)
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
