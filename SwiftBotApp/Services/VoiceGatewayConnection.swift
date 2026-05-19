import Foundation
import OSLog

/// WebSocket connection to a Discord voice server. Handles the op 0/2/1/4
/// handshake plus heartbeats. Exposes callbacks at each state transition so a
/// higher-level service (`VoicePlaybackService`) can drive the UDP transport
/// and Opus pipeline.
actor VoiceGatewayConnection {
    private static let logger = Logger(subsystem: "com.swiftbot", category: "voice.gateway")
    private static let gatewayVersion = 8

    private let session: URLSession
    private let server: VoiceServerInfo

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatIntervalMs: Int = 13_750
    private var heartbeatNonce: UInt64 = 0

    private var onReady: ((VoiceReadyInfo) async -> Void)?
    private var onSessionDescription: ((VoiceSessionKey) async -> Void)?
    private var onClose: ((Int) async -> Void)?

    init(session: URLSession, server: VoiceServerInfo) {
        self.session = session
        self.server = server
    }

    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void) { onReady = handler }
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void) { onSessionDescription = handler }
    func setOnClose(_ handler: @escaping (Int) async -> Void) { onClose = handler }

    func connect() async throws {
        let url = try buildGatewayURL()
        let task = session.webSocketTask(with: url)
        socket = task
        task.resume()
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
                "token": server.token
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

    private func receiveLoop() async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                switch message {
                case .string(let text):
                    await handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handle(text: text)
                    }
                @unknown default:
                    break
                }
            } catch {
                Self.logger.warning("voice WS receive error: \(error.localizedDescription)")
                let code = (socket.closeCode.rawValue)
                await onClose?(code)
                return
            }
        }
    }

    private func handle(text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int,
              let payload = json["d"] as? [String: Any] else {
            return
        }
        switch VoiceOpcode(rawValue: op) {
        case .hello:
            if let interval = payload["heartbeat_interval"] as? Double {
                heartbeatIntervalMs = Int(interval)
            } else if let intervalInt = payload["heartbeat_interval"] as? Int {
                heartbeatIntervalMs = intervalInt
            }
            startHeartbeat()
        case .ready:
            guard let ssrc = (payload["ssrc"] as? Int).map(UInt32.init),
                  let ip = payload["ip"] as? String,
                  let portRaw = payload["port"] as? Int,
                  let modes = payload["modes"] as? [String] else {
                return
            }
            let info = VoiceReadyInfo(ssrc: ssrc, ip: ip, port: UInt16(portRaw), modes: modes)
            await onReady?(info)
        case .sessionDescription:
            guard let modeString = payload["mode"] as? String,
                  let mode = VoiceEncryptionMode(rawValue: modeString),
                  let keyArray = payload["secret_key"] as? [Int] else {
                return
            }
            let keyBytes = keyArray.map { UInt8(clamping: $0) }
            let key = VoiceSessionKey(secretKey: Data(keyBytes), mode: mode)
            await onSessionDescription?(key)
        case .heartbeatAck:
            break
        default:
            break
        }
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
        let payload: [String: Any] = [
            "op": VoiceOpcode.heartbeat.rawValue,
            "d": Int(heartbeatNonce & 0x7fff_ffff_ffff_ffff)
        ]
        try? await sendJSON(payload)
    }
}
