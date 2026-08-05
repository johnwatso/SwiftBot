import Foundation
import OSLog
import libdave_swift

/// WebSocket connection to a Discord voice server. Handles the op 0/2/1/4
/// handshake plus heartbeats. Exposes callbacks at each state transition so a
/// higher-level service (`VoicePlaybackService`) can drive the UDP transport
/// and Opus pipeline.
actor VoiceGatewayConnection {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.gateway")
    private static let gatewayVersion = 8

    private let session: URLSession
    let server: VoiceServerInfo

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Invalidates receive/heartbeat work owned by a closed or superseded
    /// websocket. A late error from the old socket must not tear down a fresh
    /// resumed connection.
    private var socketGeneration: UInt64 = 0
    private var heartbeatIntervalMs: Int = 13_750
    private var heartbeatNonce: UInt64 = 0
    private var lastSequenceNumber: Int = -1
    private var advertisedEncryptionModes: Set<VoiceEncryptionMode> = []
    private var selectedEncryptionMode: VoiceEncryptionMode?
    /// Heartbeats sent since the last ack. A half-open socket (sleep/wake,
    /// Wi-Fi handoff, NAT rebind) can leave `receive()` hanging for minutes
    /// with no close frame; missing two acks in a row is treated as a dead
    /// connection so recovery starts in seconds instead.
    private var missedHeartbeatAcks: Int = 0
    /// Voice gateway v8 includes the echoed heartbeat nonce in Op 6. Keeping
    /// the small outstanding set prevents an old/stale ACK from making a
    /// half-open resumed socket look healthy.
    private var outstandingHeartbeatNonces: Set<UInt64> = []

    private var onReady: ((VoiceReadyInfo) async -> Void)?
    private var onSessionDescription: ((VoiceSessionKey) async -> Void)?
    private var onProtocolError: ((String) async -> Void)?
    private var onClose: ((Int) async -> Void)?
    private var onDebug: ((String) async -> Void)?
    private var onClientsConnect: (([String]) async -> Void)?
    private var onClientDisconnect: ((String) async -> Void)?
    private var onDavePrepareEpoch: ((UInt16, UInt64, UInt64) async -> Void)?
    private var onDavePrepareTransition: ((UInt16, UInt64) async -> Void)?
    private var onDaveExecuteTransition: ((UInt64) async -> Void)?
    private var onDaveMlsExternalSender: ((Data) async -> Void)?
    private var onDaveMlsProposals: ((Data) async -> Void)?
    private var onDaveMlsAnnounceCommit: ((Data, UInt64) async -> Void)?
    private var onDaveMlsWelcome: ((Data, UInt64) async -> Void)?
    private var onResumed: (() async -> Void)?

    init(session: URLSession, server: VoiceServerInfo) {
        self.session = session
        self.server = server
    }

    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void) { onReady = handler }
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void) { onSessionDescription = handler }
    func setOnProtocolError(_ handler: @escaping (String) async -> Void) { onProtocolError = handler }
    func setOnClose(_ handler: @escaping (Int) async -> Void) { onClose = handler }
    func setOnDebug(_ handler: @escaping (String) async -> Void) { onDebug = handler }
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void) { onClientsConnect = handler }
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void) { onClientDisconnect = handler }
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64, UInt64) async -> Void) { onDavePrepareEpoch = handler }
    func setOnDavePrepareTransition(_ handler: @escaping (UInt16, UInt64) async -> Void) { onDavePrepareTransition = handler }
    func setOnDaveExecuteTransition(_ handler: @escaping (UInt64) async -> Void) { onDaveExecuteTransition = handler }
    func setOnDaveMlsExternalSender(_ handler: @escaping (Data) async -> Void) { onDaveMlsExternalSender = handler }
    func setOnDaveMlsProposals(_ handler: @escaping (Data) async -> Void) { onDaveMlsProposals = handler }
    func setOnDaveMlsAnnounceCommit(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsAnnounceCommit = handler }
    func setOnDaveMlsWelcome(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsWelcome = handler }
    func setOnResumed(_ handler: @escaping () async -> Void) { onResumed = handler }

    func connect() async throws {
        let oldSocket = socket
        invalidateSocketTasks()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
        lastSequenceNumber = -1
        heartbeatNonce = 0
        outstandingHeartbeatNonces.removeAll()
        advertisedEncryptionModes.removeAll()
        selectedEncryptionMode = nil
        let url = try buildGatewayURL()
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        await debug("Voice websocket opened; sending identify.")
        try await sendIdentify()
        startReceiveLoop()
    }

    func disconnect() async {
        let oldSocket = socket
        invalidateSocketTasks()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        advertisedEncryptionModes.removeAll()
        selectedEncryptionMode = nil
    }

    /// Reopen the websocket for the same voice session and send RESUME (op 7)
    /// instead of IDENTIFY. On success Discord replies with RESUMED and the
    /// negotiated SSRC / UDP transport / encryption state all remain valid, so
    /// a brief WS drop doesn't need the full state-update + DAVE re-handshake.
    func resume() async throws {
        let oldSocket = socket
        invalidateSocketTasks()
        oldSocket?.cancel(with: .normalClosure, reason: nil)
        let url = try buildGatewayURL()
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        await debug("Voice websocket reopened; resuming session (seq_ack \(lastSequenceNumber)).")
        try await sendResume()
        startReceiveLoop()
    }

    /// Once `discoverAddress` has run, send the Select Protocol payload that
    /// tells Discord our external IP/port and chosen encryption mode.
    func sendSelectProtocol(address: VoiceUDPTransport.DiscoveredAddress, mode: VoiceEncryptionMode) async throws {
        guard advertisedEncryptionModes.contains(mode) else {
            throw VoicePipelineError.invalidTransportEncryption(
                "attempted to select \(mode.rawValue), which the current voice server did not advertise"
            )
        }
        let payload: [String: Any] = [
            "op": VoiceOpcode.selectProtocol.rawValue,
            "d": [
                "protocol": "udp",
                "data": [
                    "address": address.ip,
                    "port": Int(address.port),
                    "mode": mode.rawValue
                ]
            ]
        ]
        try await sendJSON(payload)
        selectedEncryptionMode = mode
    }

    func sendSpeaking(_ speaking: Bool, ssrc: UInt32) async throws {
        let flags = speaking ? 1 : 0
        let payload: [String: Any] = [
            "op": VoiceOpcode.speaking.rawValue,
            "d": [
                "speaking": flags,
                "delay": 0,
                "ssrc": Int(ssrc)
            ]
        ]
        try await sendJSON(payload)
    }

    func sendTransitionReady(transitionId: UInt64) async throws {
        try await sendJSON(
            VoiceGatewayOutgoingPayload(
                op: VoiceOpcode.daveTransitionReady.rawValue,
                data: VoiceTransitionIDPayload(transitionID: transitionId)
            )
        )
    }

    func sendMlsKeyPackage(_ package: Data) async throws {
        try await sendBinary(opcode: .daveMlsKeyPackage, payload: package)
    }

    func sendMlsCommitWelcome(_ payload: Data) async throws {
        try await sendBinary(opcode: .daveMlsCommitWelcome, payload: payload)
    }

    func sendInvalidCommitWelcome(transitionId: UInt64) async throws {
        try await sendJSON(
            VoiceGatewayOutgoingPayload(
                op: VoiceOpcode.daveMlsInvalidCommitWelcome.rawValue,
                data: VoiceTransitionIDPayload(transitionID: transitionId)
            )
        )
    }

    // MARK: - Private

    private func buildGatewayURL() throws -> URL {
        let host = server.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "wss://\(host)/?v=\(Self.gatewayVersion)") else {
            throw VoicePipelineError.invalidEndpoint(server.endpoint)
        }
        return url
    }

    private func sendIdentify() async throws {
        let payload: [String: Any] = [
            "op": VoiceOpcode.identify.rawValue,
            "d": [
                "server_id": server.guildID,
                "user_id": server.userID,
                "session_id": server.sessionID,
                "token": server.token,
                "max_dave_protocol_version": Int(DaveSession.maxSupportedProtocolVersion)
            ]
        ]
        try await sendJSON(payload)
    }

    private func sendResume() async throws {
        let payload: [String: Any] = [
            "op": VoiceOpcode.resume.rawValue,
            "d": [
                "server_id": server.guildID,
                "session_id": server.sessionID,
                "token": server.token,
                "seq_ack": lastSequenceNumber
            ]
        ]
        try await sendJSON(payload)
    }

    private func sendJSON(_ dictionary: [String: Any]) async throws {
        let generation = socketGeneration
        guard let socket else { throw VoicePipelineError.socketClosed }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoicePipelineError.unexpectedPayload("non-utf8 outgoing payload")
        }
        try await socket.send(.string(text))
        guard generation == socketGeneration, socket === self.socket else {
            throw VoicePipelineError.socketClosed
        }
    }

    private func sendJSON<Payload: Encodable>(_ payload: Payload) async throws {
        let generation = socketGeneration
        guard let socket else { throw VoicePipelineError.socketClosed }
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoicePipelineError.unexpectedPayload("non-utf8 outgoing payload")
        }
        try await socket.send(.string(text))
        guard generation == socketGeneration, socket === self.socket else {
            throw VoicePipelineError.socketClosed
        }
    }

    private func sendBinary(opcode: VoiceOpcode, payload: Data = Data()) async throws {
        let generation = socketGeneration
        guard let socket else { throw VoicePipelineError.socketClosed }
        try await socket.send(.data(VoiceBinaryFrame.encodeClientFrame(opcode: opcode, payload: payload)))
        guard generation == socketGeneration, socket === self.socket else {
            throw VoicePipelineError.socketClosed
        }
    }

    private func receiveLoop(generation: UInt64) async {
        while !Task.isCancelled {
            guard generation == socketGeneration, let currentSocket = socket else { return }
            do {
                let message = try await currentSocket.receive()
                guard !Task.isCancelled, generation == socketGeneration else { return }
                switch message {
                case .string(let text):
                    await handle(text: text, generation: generation)
                case .data(let data):
                    await handle(binary: data, generation: generation)
                @unknown default:
                    break
                }
            } catch {
                guard !Task.isCancelled, generation == socketGeneration else { return }
                Self.logger.warning("voice WS receive error: \(error.localizedDescription)")
                let code = currentSocket.closeCode.rawValue
                if code == 4020 {
                    await debug("Voice gateway closed with 4020 Bad Request; Discord rejected a malformed voice payload.")
                }
                guard generation == socketGeneration else { return }
                await onClose?(code)
                return
            }
        }
    }

    private func handle(text: String, generation: UInt64) async {
        guard generation == socketGeneration else { return }
        guard let data = text.data(using: .utf8) else {
            await protocolError("voice gateway text payload was not UTF-8", generation: generation)
            return
        }

        let envelope: VoiceGatewayIncomingEnvelope
        do {
            envelope = try JSONDecoder().decode(VoiceGatewayIncomingEnvelope.self, from: data)
        } catch {
            await protocolError("unreadable voice gateway payload: \(error.localizedDescription)", generation: generation)
            return
        }
        guard generation == socketGeneration else { return }
        if let sequence = envelope.sequence {
            lastSequenceNumber = sequence
        }
        #if DEBUG
        let opName = VoiceOpcode(rawValue: envelope.opcode).map { String(describing: $0) } ?? "unknown"
        await debug("🔍 voice gw ← op \(envelope.opcode) (\(opName))")
        #endif
        guard generation == socketGeneration else { return }

        switch VoiceOpcode(rawValue: envelope.opcode) {
        case .hello:
            guard let payload = await decodePayload(VoiceGatewayHello.self, from: data, opcode: .hello, generation: generation) else { return }
            guard (1...3_600_000).contains(payload.data.heartbeatInterval) else {
                await protocolError("invalid heartbeat interval \(payload.data.heartbeatInterval)", generation: generation)
                return
            }
            heartbeatIntervalMs = payload.data.heartbeatInterval
            missedHeartbeatAcks = 0
            outstandingHeartbeatNonces.removeAll()
            await debug("Voice gateway hello received; heartbeat every \(heartbeatIntervalMs) ms.")
            guard generation == socketGeneration else { return }
            startHeartbeat(generation: generation)

        case .ready:
            guard let payload = await decodePayload(VoiceGatewayReady.self, from: data, opcode: .ready, generation: generation) else { return }
            guard !payload.data.ip.isEmpty else {
                await protocolError("voice ready payload contains an empty IP address", generation: generation)
                return
            }
            let modes = payload.data.modes
            advertisedEncryptionModes = Set(modes.compactMap(VoiceEncryptionMode.init(rawValue:)))
            guard !advertisedEncryptionModes.isEmpty else {
                await protocolError("voice server advertised no supported transport encryption mode", generation: generation)
                return
            }
            let info = VoiceReadyInfo(
                ssrc: payload.data.ssrc,
                ip: payload.data.ip,
                port: payload.data.port,
                modes: modes
            )
            await debug("Voice gateway ready; starting UDP discovery.")
            guard generation == socketGeneration else { return }
            await onReady?(info)

        case .sessionDescription:
            guard let payload = await decodePayload(VoiceGatewaySessionDescription.self, from: data, opcode: .sessionDescription, generation: generation) else { return }
            guard let mode = VoiceEncryptionMode(rawValue: payload.data.mode) else {
                await protocolError("voice server selected unsupported encryption mode \(payload.data.mode)", generation: generation)
                return
            }
            guard payload.data.secretKey.count == VoiceSessionKey.secretKeyByteCount else {
                await protocolError(
                    "voice session description contains a \(payload.data.secretKey.count)-byte secret key (expected \(VoiceSessionKey.secretKeyByteCount))",
                    generation: generation
                )
                return
            }
            guard let selectedEncryptionMode else {
                await protocolError("voice session description arrived before Select Protocol", generation: generation)
                return
            }
            guard mode == selectedEncryptionMode else {
                await protocolError(
                    "voice server returned \(mode.rawValue) after \(selectedEncryptionMode.rawValue) was selected",
                    generation: generation
                )
                return
            }
            let daveVersion = payload.data.daveProtocolVersion?.value
            let key = VoiceSessionKey(
                secretKey: Data(payload.data.secretKey),
                mode: mode,
                daveProtocolVersion: daveVersion
            )
            await debug("Voice session description received; DAVE version \(daveVersion.map(String.init) ?? "none").")
            guard generation == socketGeneration else { return }
            await onSessionDescription?(key)

        case .clientsConnect:
            guard let payload = await decodePayload(VoiceGatewayClientsConnect.self, from: data, opcode: .clientsConnect, generation: generation) else { return }
            guard generation == socketGeneration else { return }
            await onClientsConnect?(payload.data.userIds)

        case .clientDisconnect:
            guard let payload = await decodePayload(VoiceGatewayClientDisconnect.self, from: data, opcode: .clientDisconnect, generation: generation) else { return }
            guard generation == socketGeneration else { return }
            await onClientDisconnect?(payload.data.userId)

        case .davePrepareTransition:
            guard let payload = await decodePayload(VoiceGatewayPrepareTransition.self, from: data, opcode: .davePrepareTransition, generation: generation) else { return }
            let transitionId = payload.data.transitionID.value
            let version = payload.data.protocolVersion.value
            await debug("DAVE prepare transition received (id \(transitionId), protocol version \(version)).")
            guard generation == socketGeneration else { return }
            await onDavePrepareTransition?(version, transitionId)

        case .daveExecuteTransition:
            guard let payload = await decodePayload(VoiceGatewayExecuteTransition.self, from: data, opcode: .daveExecuteTransition, generation: generation) else { return }
            guard generation == socketGeneration else { return }
            await onDaveExecuteTransition?(payload.data.transitionID.value)

        case .davePrepareEpoch:
            guard let payload = await decodePayload(VoiceGatewayPrepareEpoch.self, from: data, opcode: .davePrepareEpoch, generation: generation) else { return }
            guard generation == socketGeneration else { return }
            await onDavePrepareEpoch?(
                payload.data.protocolVersion.value,
                payload.data.epoch.value,
                payload.data.transitionID.value
            )

        case .heartbeatAck:
            guard let payload = await decodePayload(
                VoiceGatewayHeartbeatAck.self,
                from: data,
                opcode: .heartbeatAck,
                generation: generation
            ) else { return }
            let nonce = payload.nonce
            guard outstandingHeartbeatNonces.remove(nonce) != nil else {
                await debug("Voice gateway ignored heartbeat ACK for an unknown nonce.")
                return
            }
            missedHeartbeatAcks = outstandingHeartbeatNonces.count

        case .resumed:
            await debug("Voice gateway session resumed.")
            guard generation == socketGeneration else { return }
            missedHeartbeatAcks = 0
            outstandingHeartbeatNonces.removeAll()
            // A new websocket normally sends Hello before Resumed. Starting a
            // fresh loop here too covers gateway implementations that omit a
            // second Hello, while `startHeartbeat` replaces rather than leaks
            // an existing task.
            startHeartbeat(generation: generation)
            await onResumed?()

        default:
            await debug("Voice gateway ignored opcode \(envelope.opcode).")
        }
    }

    private func handle(binary data: Data, generation: UInt64) async {
        guard generation == socketGeneration, let frame = VoiceBinaryFrame.decodeServerFrame(data) else { return }
        lastSequenceNumber = Int(frame.sequence)
        #if DEBUG
        await debug("🔍 voice gw ← binary op \(frame.opcode.rawValue) (\(String(describing: frame.opcode)), \(frame.payload.count) bytes)")
        #endif
        guard generation == socketGeneration else { return }
        switch frame.opcode {
        case .mlsExternalSenderPackage:
            await onDaveMlsExternalSender?(frame.payload)
        case .daveMlsProposals:
            await onDaveMlsProposals?(frame.payload)
        case .daveMlsAnnounceCommitTransition:
            guard let transitionId = VoiceBinaryFrame.uint16BigEndian(from: frame.payload) else {
                await protocolError("DAVE commit transition payload is missing its transition id", generation: generation)
                return
            }
            await onDaveMlsAnnounceCommit?(Data(frame.payload.dropFirst(2)), UInt64(transitionId))
        case .daveMlsWelcome:
            guard let transitionId = VoiceBinaryFrame.uint16BigEndian(from: frame.payload) else {
                await protocolError("DAVE welcome payload is missing its transition id", generation: generation)
                return
            }
            await onDaveMlsWelcome?(Data(frame.payload.dropFirst(2)), UInt64(transitionId))
        default:
            await debug("Voice gateway ignored binary opcode \(frame.opcode.rawValue).")
        }
    }

    private func decodePayload<Payload: Decodable>(
        _ type: Payload.Type,
        from data: Data,
        opcode: VoiceOpcode,
        generation: UInt64
    ) async -> Payload? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            await protocolError(
                "invalid \(String(describing: opcode)) payload: \(error.localizedDescription)",
                generation: generation
            )
            return nil
        }
    }

    private func protocolError(_ reason: String, generation: UInt64) async {
        guard generation == socketGeneration else { return }
        await debug("Voice gateway protocol error: \(reason)")
        guard generation == socketGeneration else { return }
        await onProtocolError?(reason)
    }

    private func invalidateSocketTasks() {
        socketGeneration &+= 1
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        missedHeartbeatAcks = 0
        outstandingHeartbeatNonces.removeAll()
    }

    private func startReceiveLoop() {
        let generation = socketGeneration
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(generation: generation)
        }
    }

    private func startHeartbeat(generation: UInt64) {
        guard generation == socketGeneration else { return }
        heartbeatTask?.cancel()
        missedHeartbeatAcks = 0
        outstandingHeartbeatNonces.removeAll()
        let intervalNs = UInt64(heartbeatIntervalMs) * 1_000_000
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat(generation: generation)
            }
        }
    }

    private func sendHeartbeat(generation: UInt64) async {
        guard generation == socketGeneration else { return }
        if outstandingHeartbeatNonces.count >= 2 {
            await debug("Voice gateway missed \(missedHeartbeatAcks) heartbeat acks; treating the socket as dead.")
            guard generation == socketGeneration else { return }
            heartbeatTask?.cancel()
            heartbeatTask = nil
            // Force the pending receive() to fail so the close is reported
            // through the normal onClose path (as an abnormal closure).
            socket?.cancel(with: .abnormalClosure, reason: nil)
            return
        }
        heartbeatNonce &+= 1
        let nonce = heartbeatNonce & 0x7fff_ffff_ffff_ffff
        let heartbeat = VoiceHeartbeatPayload(
            nonce: nonce,
            sequenceAck: lastSequenceNumber
        )
        do {
            try await sendJSON(
                VoiceGatewayOutgoingPayload(op: VoiceOpcode.heartbeat.rawValue, data: heartbeat)
            )
        } catch {
            await debug("Voice gateway heartbeat send failed: \(error.localizedDescription)")
            socket?.cancel(with: .abnormalClosure, reason: nil)
            return
        }
        outstandingHeartbeatNonces.insert(nonce)
        missedHeartbeatAcks = outstandingHeartbeatNonces.count
    }

    private func debug(_ message: String) async {
        Self.logger.info("\(message, privacy: .public)")
        await onDebug?(message)
    }
}

// MARK: - Strict Voice Gateway Payloads

/// Decode numerical gateway fields through concrete integer types instead of
/// `JSONSerialization`'s `Double`/`NSNumber` bridge. Voice sequence numbers,
/// epochs, and transition ids are protocol values—not floating point values—so
/// malformed, negative, fractional, or out-of-range values must never be
/// rounded, clamped, or changed into the sentinel value zero.
struct VoiceGatewayIncomingEnvelope: Decodable {
    let opcode: Int
    let sequence: Int?

    enum CodingKeys: String, CodingKey {
        case opcode = "op"
        case sequence = "seq"
    }
}

private struct VoiceGatewayHello: Decodable {
    struct Body: Decodable {
        let heartbeatInterval: Int

        enum CodingKeys: String, CodingKey {
            case heartbeatInterval = "heartbeat_interval"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

/// Voice gateway v8 sends the original heartbeat nonce back in Op 6. Earlier
/// gateway versions used the bare number, so accept both documented shapes
/// while decoding the nonce exactly (never through `Double`).
private struct VoiceGatewayHeartbeatAck: Decodable {
    private struct ObjectPayload: Decodable {
        let nonce: VoiceExactUInt64

        enum CodingKeys: String, CodingKey {
            case nonce = "t"
        }
    }

    let nonce: UInt64

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let object = try? container.decode(ObjectPayload.self, forKey: .data) {
            nonce = object.nonce.value
        } else {
            nonce = try container.decode(VoiceExactUInt64.self, forKey: .data).value
        }
    }
}

private struct VoiceGatewayReady: Decodable {
    struct Body: Decodable {
        let ssrc: UInt32
        let ip: String
        let port: UInt16
        let modes: [String]
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

private struct VoiceGatewaySessionDescription: Decodable {
    struct Body: Decodable {
        let mode: String
        let secretKey: [UInt8]
        let daveProtocolVersion: VoiceExactUInt16?

        enum CodingKeys: String, CodingKey {
            case mode
            case secretKey = "secret_key"
            case daveProtocolVersion = "dave_protocol_version"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

private struct VoiceGatewayClientsConnect: Decodable {
    struct Body: Decodable {
        let userIds: [String]

        enum CodingKeys: String, CodingKey {
            case userIds = "user_ids"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

private struct VoiceGatewayClientDisconnect: Decodable {
    struct Body: Decodable {
        let userId: String

        enum CodingKeys: String, CodingKey {
            case userId = "user_id"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

struct VoiceGatewayPrepareTransition: Decodable {
    struct Body: Decodable {
        let transitionID: VoiceExactUInt64
        let protocolVersion: VoiceExactUInt16

        enum CodingKeys: String, CodingKey {
            case transitionID = "transition_id"
            case protocolVersion = "protocol_version"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

private struct VoiceGatewayExecuteTransition: Decodable {
    struct Body: Decodable {
        let transitionID: VoiceExactUInt64

        enum CodingKeys: String, CodingKey {
            case transitionID = "transition_id"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

struct VoiceGatewayPrepareEpoch: Decodable {
    struct Body: Decodable {
        let protocolVersion: VoiceExactUInt16
        let epoch: VoiceExactUInt64
        let transitionID: VoiceExactUInt64

        enum CodingKeys: String, CodingKey {
            case protocolVersion = "protocol_version"
            case epoch
            case transitionID = "transition_id"
        }
    }

    let data: Body

    enum CodingKeys: String, CodingKey {
        case data = "d"
    }
}

/// A protocol integer may arrive as a JSON integer or a decimal string. The
/// accepted string form is deliberately digits-only; decimal points, signs,
/// and whitespace are rejected rather than converted or truncated.
struct VoiceExactUInt64: Decodable {
    let value: UInt64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            guard !string.isEmpty,
                  string.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }),
                  let value = UInt64(string) else {
                throw VoiceGatewayPayloadError.invalidUnsignedInteger(string)
            }
            self.value = value
            return
        }
        self.value = try container.decode(UInt64.self)
    }
}

struct VoiceExactUInt16: Decodable {
    let value: UInt16

    init(from decoder: Decoder) throws {
        let raw = try VoiceExactUInt64(from: decoder).value
        guard let value = UInt16(exactly: raw) else {
            throw VoiceGatewayPayloadError.integerOutOfRange(raw, type: "UInt16")
        }
        self.value = value
    }
}

private enum VoiceGatewayPayloadError: LocalizedError {
    case invalidUnsignedInteger(String)
    case integerOutOfRange(UInt64, type: String)

    var errorDescription: String? {
        switch self {
        case .invalidUnsignedInteger(let value):
            return "expected an unsigned decimal integer, got \(value)"
        case .integerOutOfRange(let value, let type):
            return "\(value) is outside the valid \(type) range"
        }
    }
}

private struct VoiceGatewayOutgoingPayload<Body: Encodable>: Encodable {
    let op: Int
    let data: Body

    enum CodingKeys: String, CodingKey {
        case op
        case data = "d"
    }
}

private struct VoiceTransitionIDPayload: Encodable {
    let transitionID: UInt64

    enum CodingKeys: String, CodingKey {
        case transitionID = "transition_id"
    }
}

private struct VoiceHeartbeatPayload: Encodable {
    let nonce: UInt64
    let sequenceAck: Int

    enum CodingKeys: String, CodingKey {
        case nonce = "t"
        case sequenceAck = "seq_ack"
    }
}
