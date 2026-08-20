import Foundation
import OSLog

actor DiscordGatewayConnection {
    struct ReconnectDiagnostic: Sendable, Equatable {
        let at: Date
        let generation: Int
        let delaySeconds: Int
        let closeCode: Int?
        let reason: String
    }

    protocol Socket: AnyObject, Sendable {
        var closeCode: URLSessionWebSocketTask.CloseCode { get }
        func resume()
        func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
        func receive() async throws -> URLSessionWebSocketTask.Message
        func send(_ message: URLSessionWebSocketTask.Message) async throws
    }

    struct Dependencies {
        var socketFactory: @Sendable (URLSession, URL) async -> any Socket = { session, url in
            URLSessionGatewaySocket(task: session.webSocketTask(with: url))
        }
        var decodePayload: @Sendable (String) -> GatewayPayload? = { text in
            try? JSONDecoder().decode(GatewayPayload.self, from: Data(text.utf8))
        }
        var encodeJSON: @Sendable ([String: Any]) throws -> Data = { dictionary in
            try JSONSerialization.data(withJSONObject: dictionary)
        }
        var dateProvider: @Sendable () -> Date = { Date() }
        var sleep: @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    }

    private static let logger = Logger(subsystem: "com.swiftbot", category: "discord.gateway")

    private let session: URLSession
    private let gatewayURL: URL
    private let dependencies: Dependencies

    /// Codes for a socket that ended cleanly: 1000 is a normal close, and 1001
    /// ("going away") is what Discord sends whenever it cycles a gateway host.
    /// Neither says anything is wrong with this bot.
    private static let cleanCloseCodes: Set<Int> = [1000, 1001]

    private var socket: (any Socket)?
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatSentAt: Date?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var heartbeatInterval: UInt64 = 41_250_000_000
    private var sequence: Int?
    private var sessionId: String?
    private var botToken: String?
    private var reconnectAttempts = 0
    private var userInitiatedDisconnect = false
    private var connectionGeneration = 0
    /// Set only for a replacement socket that can preserve the prior Discord
    /// session. A successful RESUME keeps the bot's voice state intact, so
    /// users do not see a leave/join notification during a brief WS drop.
    private var resumeOnHelloGeneration: Int?

    private var onPayload: ((GatewayPayload) async -> Void)?
    private var onConnectionState: ((BotStatus) async -> Void)?
    private var onHeartbeatLatency: ((Int) async -> Void)?
    private var onGatewayClose: ((Int) async -> Void)?
    private var onReconnectDiagnostic: ((ReconnectDiagnostic) async -> Void)?

    init(
        session: URLSession,
        gatewayURL: URL,
        dependencies: Dependencies = Dependencies()
    ) {
        self.session = session
        self.gatewayURL = gatewayURL
        self.dependencies = dependencies
    }

    func setOnPayload(_ handler: @escaping (GatewayPayload) async -> Void) {
        onPayload = handler
    }

    func setOnConnectionState(_ handler: @escaping (BotStatus) async -> Void) {
        onConnectionState = handler
    }

    func setOnHeartbeatLatency(_ handler: @escaping (Int) async -> Void) {
        onHeartbeatLatency = handler
    }

    func setOnGatewayClose(_ handler: @escaping (Int) async -> Void) {
        onGatewayClose = handler
    }

    func setOnReconnectDiagnostic(_ handler: @escaping (ReconnectDiagnostic) async -> Void) {
        onReconnectDiagnostic = handler
    }

    func connect(token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            await onConnectionState?(.stopped)
            return
        }

        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        _ = await reconnectTask?.value
        reconnectTask = nil
        reconnectAttempts = 0
        botToken = normalizedToken
        sequence = nil
        sessionId = nil
        resumeOnHelloGeneration = nil
        Self.logger.info("Gateway connect initiated")
        await openGatewayConnection(token: normalizedToken, isReconnect: false)
    }

    func disconnect() async {
        Self.logger.info("Gateway disconnect requested (user-initiated)")
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        _ = await reconnectTask?.value
        reconnectTask = nil
        heartbeatTask?.cancel()
        _ = await heartbeatTask?.value
        heartbeatTask = nil
        receiveTask?.cancel()
        _ = await receiveTask?.value
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        botToken = nil
        sequence = nil
        sessionId = nil
        resumeOnHelloGeneration = nil
        await onConnectionState?(.stopped)
    }

    /// Send Voice State Update (op 4) to join or leave a voice channel.
    /// Pass `channelID: nil` to leave the current voice channel.
    func sendVoiceStateUpdate(guildID: String, channelID: String?, selfMute: Bool = false, selfDeaf: Bool = true) async -> Bool {
        let payload: [String: Any] = [
            "op": 4,
            "d": [
                "guild_id": guildID,
                "channel_id": channelID as Any? ?? NSNull(),
                "self_mute": selfMute,
                "self_deaf": selfDeaf
            ]
        ]
        return await sendRaw(payload)
    }

    func sendPresence(text: String) async {
        let payload: [String: Any] = [
            "op": 3,
            "d": [
                "since": NSNull(),
                "activities": [["name": text, "type": 0]],
                "status": "online",
                "afk": false
            ]
        ]
        _ = await sendRaw(payload)
    }

    private func receiveLoop(token: String, generation: Int) async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let payload = dependencies.decodePayload(text)
                else { continue }

                guard generation == connectionGeneration else {
                    Self.logger.debug("Ignoring message for stale generation \(generation)")
                    break
                }

                sequence = payload.s ?? sequence
                if payload.t == "READY",
                   case let .object(readyMap)? = payload.d,
                   case let .string(readySessionId)? = readyMap["session_id"] {
                    sessionId = readySessionId
                }

                await handleGatewayPayload(payload, token: token, generation: generation)
                await onPayload?(payload)
            } catch {
                let closeRawValue = socket.closeCode.rawValue
                if generation == connectionGeneration {
                    // Only a live socket's close says anything about the bot's health.
                    // A stale generation is a socket we replaced ourselves, and it always
                    // reports "going away" — surfacing that pinned the dashboard to
                    // "Action Required" for the rest of the process lifetime.
                    if closeRawValue > 0, !Self.cleanCloseCodes.contains(closeRawValue) {
                        await onGatewayClose?(closeRawValue)
                    }
                    await scheduleReconnect(
                        reason: "Gateway receive failed: \(error.localizedDescription)",
                        closeCode: closeRawValue > 0 ? closeRawValue : nil
                    )
                } else {
                    Self.logger.debug("Old receive loop error ignored (generation \(generation) != current \(self.connectionGeneration))")
                }
                break
            }
        }
    }

    private func handleGatewayPayload(_ payload: GatewayPayload, token: String, generation: Int) async {
        guard generation == connectionGeneration else {
            Self.logger.debug("Ignoring payload for stale generation \(generation)")
            return
        }

        switch payload.op {
        case 10:
            if case let .object(hello)? = payload.d,
               case let .double(interval)? = hello["heartbeat_interval"] {
                heartbeatInterval = UInt64(interval * 1_000_000)
            }
            reconnectAttempts = 0
            reconnectTask?.cancel()
            _ = await reconnectTask?.value
            reconnectTask = nil
            if resumeOnHelloGeneration == generation,
               let sessionId,
               let sequence {
                let didSendResume = await resume(token: token, sessionId: sessionId, sequence: sequence)
                if !didSendResume {
                    await scheduleReconnect(reason: "Gateway RESUME send failed")
                    return
                }
            } else {
                await identify(token: token)
                await onConnectionState?(.running)
            }
            await startHeartbeat()
        case 1:
            await sendHeartbeat()
        case 7:
            await scheduleReconnect(reason: "Gateway requested reconnect (op 7)")
        case 9:
            // Discord rejected the resumable session. The next IDENTIFY must
            // be fresh; retaining its sequence/session ID would make every
            // following reconnect retry the same invalid resume.
            resumeOnHelloGeneration = nil
            sequence = nil
            sessionId = nil
            await identify(token: token)
            await onConnectionState?(.running)
        case 11:
            if let sent = heartbeatSentAt {
                let latencyMs = max(
                    1,
                    Int((dependencies.dateProvider().timeIntervalSince(sent) * 1000).rounded())
                )
                heartbeatSentAt = nil
                await onHeartbeatLatency?(latencyMs)
            }
        default:
            if payload.t == "RESUMED" {
                resumeOnHelloGeneration = nil
                reconnectAttempts = 0
                await onConnectionState?(.running)
            }
        }
    }

    private func openGatewayConnection(token: String, isReconnect: Bool) async {
        connectionGeneration += 1
        let generation = connectionGeneration
        resumeOnHelloGeneration = isReconnect && sessionId != nil && sequence != nil
            ? generation
            : nil

        Self.logger.info("Opening gateway connection (generation \(generation), reconnect: \(isReconnect))")

        if isReconnect {
            await onConnectionState?(.reconnecting)
        } else {
            await onConnectionState?(.connecting)
        }

        // Cancel and await old tasks to prevent overlapping sockets and CFNetwork races
        heartbeatTask?.cancel()
        _ = await heartbeatTask?.value
        heartbeatTask = nil

        receiveTask?.cancel()
        _ = await receiveTask?.value
        receiveTask = nil

        if let oldSocket = socket {
            Self.logger.debug("Cancelling old socket (generation \(generation - 1))")
            oldSocket.cancel(with: .goingAway, reason: nil)
            socket = nil
        }

        let nextSocket = await dependencies.socketFactory(session, gatewayURL)
        socket = nextSocket
        nextSocket.resume()
        Self.logger.debug("New socket resumed (generation \(generation))")
        receiveTask = Task { [generation] in
            await self.receiveLoop(token: token, generation: generation)
        }
    }

    private func scheduleReconnect(reason: String, closeCode: Int? = nil) async {
        guard !userInitiatedDisconnect else { return }
        guard reconnectTask == nil else { return }
        guard let token = botToken, !token.isEmpty else { return }

        reconnectAttempts += 1
        let delaySeconds = min(30, 1 << min(reconnectAttempts, 5))
        let generation = connectionGeneration
        await onConnectionState?(.reconnecting)
        await onReconnectDiagnostic?(ReconnectDiagnostic(
            at: dependencies.dateProvider(),
            generation: generation,
            delaySeconds: delaySeconds,
            closeCode: closeCode,
            reason: reason
        ))

        Self.logger.info("Scheduling reconnect in \(delaySeconds)s (generation \(generation), reason: \(reason))")

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.sleep(UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else {
                Self.logger.debug("Reconnect task cancelled (generation \(generation))")
                return
            }
            await self.reconnectTaskDidFire(token: token, generation: generation)
        }
    }

    private func reconnectTaskDidFire(token: String, generation: Int) async {
        reconnectTask = nil
        guard !userInitiatedDisconnect else { return }
        guard botToken == token else { return }
        guard generation == connectionGeneration else {
            Self.logger.info("Stale reconnect dropped (generation \(generation) != current \(self.connectionGeneration))")
            return
        }
        Self.logger.info("Reconnect firing (generation \(generation))")
        await openGatewayConnection(token: token, isReconnect: true)
    }

    private func startHeartbeat() async {
        heartbeatTask?.cancel()
        _ = await heartbeatTask?.value
        heartbeatTask = Task {
            while !Task.isCancelled {
                await dependencies.sleep(heartbeatInterval)
                guard !Task.isCancelled else { return }
                await sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        heartbeatSentAt = dependencies.dateProvider()
        let payload: [String: Any] = ["op": 1, "d": sequence as Any]
        _ = await sendRaw(payload)
    }

    private func identify(token: String) async {
        let presence: [String: Any] = [
            "since": NSNull(),
            "activities": [[
                "name": "Hello! Ping me for help",
                "type": 0
            ]],
            "status": "online",
            "afk": false
        ]

        let intents = 49_027
        let identify: [String: Any] = [
            "token": token,
            "intents": intents,
            "properties": ["$os": "macOS", "$browser": "SwiftBot", "$device": "SwiftBot"],
            "presence": presence
        ]
        _ = await sendRaw(["op": 2, "d": identify])
    }

    @discardableResult
    private func resume(token: String, sessionId: String, sequence: Int) async -> Bool {
        await sendRaw([
            "op": 6,
            "d": [
                "token": token,
                "session_id": sessionId,
                "seq": sequence
            ]
        ])
    }

    @discardableResult
    private func sendRaw(_ dictionary: [String: Any]) async -> Bool {
        guard let socket else {
            Self.logger.warning("Gateway send skipped: socket is not connected")
            return false
        }
        do {
            let data = try dependencies.encodeJSON(dictionary)
            if let text = String(data: data, encoding: .utf8) {
                try await socket.send(.string(text))
                return true
            }
        } catch {
            Self.logger.warning("Gateway send failed: \(error.localizedDescription)")
        }
        return false
    }
}

final class URLSessionGatewaySocket: DiscordGatewayConnection.Socket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    var closeCode: URLSessionWebSocketTask.CloseCode {
        task.closeCode
    }

    func resume() {
        task.resume()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }
}
