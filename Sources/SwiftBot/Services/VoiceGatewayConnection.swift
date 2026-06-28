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
    private var heartbeatIntervalMs: Int = 13_750
    private var heartbeatNonce: UInt64 = 0
    private var lastSequenceNumber: Int = -1

    private var onReady: ((VoiceReadyInfo) async -> Void)?
    private var onSessionDescription: ((VoiceSessionKey) async -> Void)?
    private var onClose: ((Int) async -> Void)?
    private var onDebug: ((String) async -> Void)?
    private var onClientsConnect: (([String]) async -> Void)?
    private var onClientDisconnect: ((String) async -> Void)?
    private var onDavePrepareEpoch: ((UInt16, UInt64) async -> Void)?
    private var onDaveExecuteTransition: ((UInt64) async -> Void)?
    private var onDaveMlsExternalSender: ((Data) async -> Void)?
    private var onDaveMlsProposals: ((Data) async -> Void)?
    private var onDaveMlsAnnounceCommit: ((Data, UInt64) async -> Void)?
    private var onDaveMlsWelcome: ((Data, UInt64) async -> Void)?

    init(session: URLSession, server: VoiceServerInfo) {
        self.session = session
        self.server = server
    }

    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void) { onReady = handler }
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void) { onSessionDescription = handler }
    func setOnClose(_ handler: @escaping (Int) async -> Void) { onClose = handler }
    func setOnDebug(_ handler: @escaping (String) async -> Void) { onDebug = handler }
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void) { onClientsConnect = handler }
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void) { onClientDisconnect = handler }
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64) async -> Void) { onDavePrepareEpoch = handler }
    func setOnDaveExecuteTransition(_ handler: @escaping (UInt64) async -> Void) { onDaveExecuteTransition = handler }
    func setOnDaveMlsExternalSender(_ handler: @escaping (Data) async -> Void) { onDaveMlsExternalSender = handler }
    func setOnDaveMlsProposals(_ handler: @escaping (Data) async -> Void) { onDaveMlsProposals = handler }
    func setOnDaveMlsAnnounceCommit(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsAnnounceCommit = handler }
    func setOnDaveMlsWelcome(_ handler: @escaping (Data, UInt64) async -> Void) { onDaveMlsWelcome = handler }

    func connect() async throws {
        let url = try buildGatewayURL()
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
        await debug("Voice websocket opened; sending identify.")
        try await sendIdentify()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    /// Once `discoverAddress` has run, send the Select Protocol payload that
    /// tells Discord our external IP/port and chosen encryption mode.
    func sendSelectProtocol(address: VoiceUDPTransport.DiscoveredAddress, mode: VoiceEncryptionMode) async throws {
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
        let payload: [String: Any] = [
            "op": VoiceOpcode.daveTransitionReady.rawValue,
            "d": [
                "transition_id": Int(clamping: transitionId)
            ]
        ]
        try await sendJSON(payload)
    }

    func sendMlsKeyPackage(_ package: Data) async throws {
        try await sendBinary(opcode: .daveMlsKeyPackage, payload: package)
    }

    func sendMlsCommitWelcome(_ payload: Data) async throws {
        try await sendBinary(opcode: .daveMlsCommitWelcome, payload: payload)
    }

    func sendInvalidCommitWelcome(transitionId: UInt64) async throws {
        let payload: [String: Any] = [
            "op": VoiceOpcode.daveMlsInvalidCommitWelcome.rawValue,
            "d": [
                "transition_id": Int(clamping: transitionId)
            ]
        ]
        try await sendJSON(payload)
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

    private func sendJSON(_ dictionary: [String: Any]) async throws {
        guard let socket else { throw VoicePipelineError.socketClosed }
        let data = try JSONSerialization.data(withJSONObject: dictionary)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoicePipelineError.unexpectedPayload("non-utf8 outgoing payload")
        }
        try await socket.send(.string(text))
    }

    private func sendBinary(opcode: VoiceOpcode, payload: Data = Data()) async throws {
        guard let socket else { throw VoicePipelineError.socketClosed }
        try await socket.send(.data(VoiceBinaryFrame.encodeClientFrame(opcode: opcode, payload: payload)))
    }

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    await handle(text: text)
                case .data(let data):
                    await handle(binary: data)
                @unknown default:
                    break
                }
            } catch {
                Self.logger.warning("voice WS receive error: \(error.localizedDescription)")
                let code = (socket.closeCode.rawValue)
                if code == 4020 {
                    await debug("Voice gateway closed with 4020 Bad Request; Discord rejected a malformed voice payload.")
                }
                await onClose?(code)
                return
            }
        }
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else {
            await debug("Voice gateway sent unreadable text payload.")
            return
        }
        if let sequence = json["seq"] as? Int {
            lastSequenceNumber = sequence
        }
        let payload = json["d"] as? [String: Any] ?? [:]
        #if DEBUG
        let opName = VoiceOpcode(rawValue: op).map { String(describing: $0) } ?? "unknown"
        await debug("🔍 voice gw ← op \(op) (\(opName))")
        #endif
        switch VoiceOpcode(rawValue: op) {
        case .hello:
            if let interval = payload["heartbeat_interval"] as? Double {
                heartbeatIntervalMs = Int(interval)
            } else if let intervalInt = payload["heartbeat_interval"] as? Int {
                heartbeatIntervalMs = intervalInt
            }
            await debug("Voice gateway hello received; heartbeat every \(heartbeatIntervalMs) ms.")
            startHeartbeat()
        case .ready:
            guard let ssrc = (payload["ssrc"] as? Int).map(UInt32.init),
                  let ip = payload["ip"] as? String,
                  let portRaw = payload["port"] as? Int,
                  let modes = payload["modes"] as? [String] else {
                return
            }
            let info = VoiceReadyInfo(ssrc: ssrc, ip: ip, port: UInt16(portRaw), modes: modes)
            await debug("Voice gateway ready; starting UDP discovery.")
            await onReady?(info)
        case .sessionDescription:
            guard let modeString = payload["mode"] as? String,
                  let mode = VoiceEncryptionMode(rawValue: modeString),
                  let keyArray = payload["secret_key"] as? [Int] else {
                return
            }
            let keyBytes = keyArray.map { UInt8(clamping: $0) }
            let daveVersion = (payload["dave_protocol_version"] as? Int).map { UInt16($0) }
            let key = VoiceSessionKey(secretKey: Data(keyBytes), mode: mode, daveProtocolVersion: daveVersion)
            await debug("Voice session description received; DAVE version \(daveVersion.map(String.init) ?? "none").")
            await onSessionDescription?(key)
        case .clientsConnect:
            if let ids = payload["user_ids"] as? [String] {
                await onClientsConnect?(ids)
            }
        case .clientDisconnect:
            if let id = payload["user_id"] as? String {
                await onClientDisconnect?(id)
            }
        case .davePrepareTransition:
            let transitionId = transitionId(from: payload)
            let version = protocolVersion(from: payload)
            if version == 0 {
                await debug("DAVE prepare transition (id \(transitionId)): downgrade to unencrypted (protocol version 0); acknowledging.")
                try? await sendTransitionReady(transitionId: transitionId)
            } else {
                await debug("DAVE prepare transition received (id \(transitionId), protocol version \(version)).")
            }
        case .daveExecuteTransition:
            await onDaveExecuteTransition?(transitionId(from: payload))
        case .davePrepareEpoch:
            await onDavePrepareEpoch?(protocolVersion(from: payload), epoch(from: payload))
        case .heartbeatAck:
            break
        default:
            await debug("Voice gateway ignored opcode \(op).")
            break
        }
    }

    private func handle(binary data: Data) async {
        guard let frame = VoiceBinaryFrame.decodeServerFrame(data) else { return }
        lastSequenceNumber = Int(frame.sequence)
        #if DEBUG
        await debug("🔍 voice gw ← binary op \(frame.opcode.rawValue) (\(String(describing: frame.opcode)), \(frame.payload.count) bytes)")
        #endif
        switch frame.opcode {
        case .mlsExternalSenderPackage:
            await onDaveMlsExternalSender?(frame.payload)
        case .daveMlsProposals:
            await onDaveMlsProposals?(frame.payload)
        case .daveMlsAnnounceCommitTransition:
            guard let transitionId = VoiceBinaryFrame.uint16BigEndian(from: frame.payload) else { return }
            await onDaveMlsAnnounceCommit?(Data(frame.payload.dropFirst(2)), UInt64(transitionId))
        case .daveMlsWelcome:
            guard let transitionId = VoiceBinaryFrame.uint16BigEndian(from: frame.payload) else { return }
            await onDaveMlsWelcome?(Data(frame.payload.dropFirst(2)), UInt64(transitionId))
        default:
            await debug("Voice gateway ignored binary opcode \(frame.opcode.rawValue).")
            break
        }
    }

    private func transitionId(from payload: [String: Any]) -> UInt64 {
        integerValue(for: "transition_id", in: payload)
    }

    private func protocolVersion(from payload: [String: Any]) -> UInt16 {
        UInt16(clamping: integerValue(for: "protocol_version", in: payload))
    }

    private func epoch(from payload: [String: Any]) -> UInt64 {
        integerValue(for: "epoch", in: payload)
    }

    private func integerValue(for key: String, in payload: [String: Any]) -> UInt64 {
        if let string = payload[key] as? String { return UInt64(string) ?? 0 }
        if let int = payload[key] as? Int { return UInt64(int) }
        if let uint = payload[key] as? UInt64 { return uint }
        if let double = payload[key] as? Double { return UInt64(double) }
        return 0
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        let intervalNs = UInt64(heartbeatIntervalMs) * 1_000_000
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard !Task.isCancelled else { return }
                await self?.sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        heartbeatNonce &+= 1
        let heartbeatData: [String: Any] = [
            "t": Int(heartbeatNonce & 0x7fff_ffff_ffff_ffff),
            "seq_ack": lastSequenceNumber
        ]
        let payload: [String: Any] = [
            "op": VoiceOpcode.heartbeat.rawValue,
            "d": heartbeatData
        ]
        try? await sendJSON(payload)
    }

    private func debug(_ message: String) async {
        Self.logger.info("\(message, privacy: .public)")
        await onDebug?(message)
    }
}
