import Foundation

actor DiscordGatewayConnection {
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

    private let session: URLSession
    private let gatewayURL: URL
    private let dependencies: Dependencies

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

    private var onPayload: ((GatewayPayload) async -> Void)?
    private var onConnectionState: ((BotStatus) async -> Void)?
    private var onHeartbeatLatency: ((Int) async -> Void)?
    private var onGatewayClose: ((Int) async -> Void)?

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

    func connect(token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            await onConnectionState?(.stopped)
            return
        }

        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        botToken = normalizedToken
        await openGatewayConnection(token: normalizedToken, isReconnect: false)
    }

    func disconnect() async {
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        botToken = nil
        sequence = nil
        sessionId = nil
        await onConnectionState?(.stopped)
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
        await sendRaw(payload)
    }

    private func receiveLoop(token: String) async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                guard case .string(let text) = message,
                      let payload = dependencies.decodePayload(text)
                else { continue }

                sequence = payload.s ?? sequence
                if payload.t == "READY",
                   case let .object(readyMap)? = payload.d,
                   case let .string(readySessionId)? = readyMap["session_id"] {
                    sessionId = readySessionId
                }

                await handleGatewayPayload(payload, token: token)
                await onPayload?(payload)
            } catch {
                let closeRawValue = socket.closeCode.rawValue
                if closeRawValue != 1000, closeRawValue > 0 {
                    await onGatewayClose?(closeRawValue)
                }
                await scheduleReconnect(reason: "Gateway receive failed: \(error.localizedDescription)")
                break
            }
        }
    }

    private func handleGatewayPayload(_ payload: GatewayPayload, token: String) async {
        switch payload.op {
        case 10:
            if case let .object(hello)? = payload.d,
               case let .double(interval)? = hello["heartbeat_interval"] {
                heartbeatInterval = UInt64(interval * 1_000_000)
            }
            reconnectAttempts = 0
            reconnectTask?.cancel()
            reconnectTask = nil
            await identify(token: token)
            startHeartbeat()
            await onConnectionState?(.running)
        case 1:
            await sendHeartbeat()
        case 7:
            await scheduleReconnect(reason: "Gateway requested reconnect (op 7)")
        case 9:
            await identify(token: token)
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
            break
        }
    }

    private func openGatewayConnection(token: String, isReconnect: Bool) async {
        if isReconnect {
            await onConnectionState?(.reconnecting)
        } else {
            await onConnectionState?(.connecting)
        }

        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)

        let nextSocket = await dependencies.socketFactory(session, gatewayURL)
        socket = nextSocket
        nextSocket.resume()
        receiveTask = Task { await self.receiveLoop(token: token) }
    }

    private func scheduleReconnect(reason: String) async {
        guard !userInitiatedDisconnect else { return }
        guard reconnectTask == nil else { return }
        guard let token = botToken, !token.isEmpty else { return }

        reconnectAttempts += 1
        let delaySeconds = min(30, 1 << min(reconnectAttempts, 5))
        await onConnectionState?(.reconnecting)

        reconnectTask = Task { [weak self] in
            guard let self else { return }
            await self.dependencies.sleep(UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self.reconnectTaskDidFire(token: token)
        }
        _ = reason
    }

    private func reconnectTaskDidFire(token: String) async {
        reconnectTask = nil
        guard !userInitiatedDisconnect else { return }
        guard botToken == token else { return }
        await openGatewayConnection(token: token, isReconnect: true)
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
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
        await sendRaw(payload)
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
        await sendRaw(["op": 2, "d": identify])
    }

    private func sendRaw(_ dictionary: [String: Any]) async {
        guard let socket else { return }
        do {
            let data = try dependencies.encodeJSON(dictionary)
            if let text = String(data: data, encoding: .utf8) {
                try await socket.send(.string(text))
            }
        } catch {
            // noop, routed to reconnect by receive loop if needed.
        }
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
