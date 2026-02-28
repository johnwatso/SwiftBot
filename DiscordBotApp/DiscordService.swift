import Foundation

actor DiscordService {
    private let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private let restBase = URL(string: "https://discord.com/api/v10")!
    private var socket: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatInterval: UInt64 = 41_250_000_000
    private var sequence: Int?
    private var sessionId: String?

    private let session = URLSession(configuration: .default)

    var onPayload: ((GatewayPayload) async -> Void)?
    var onConnectionState: ((BotStatus) async -> Void)?

    func connect(token: String) async {
        await onConnectionState?(.connecting)
        let task = session.webSocketTask(with: gatewayURL)
        self.socket = task
        task.resume()
        receiveTask = Task { await self.receiveLoop(token: token) }
    }

    func disconnect() {
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        Task { await onConnectionState?(.stopped) }
    }

    private func receiveLoop(token: String) async {
        while let socket {
            do {
                let message = try await socket.receive()
                if case .string(let text) = message,
                   let payload = try? JSONDecoder().decode(GatewayPayload.self, from: Data(text.utf8)) {
                    sequence = payload.s ?? sequence
                    await handleGatewayPayload(payload, token: token)
                    await onPayload?(payload)
                }
            } catch {
                await onConnectionState?(.reconnecting)
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
            await identify(token: token)
            startHeartbeat()
            await onConnectionState?(.running)
        case 1:
            await sendHeartbeat()
        case 7:
            await onConnectionState?(.reconnecting)
        case 9:
            await identify(token: token)
        case 11:
            break
        default:
            break
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: heartbeatInterval)
                await sendHeartbeat()
            }
        }
    }

    private func sendHeartbeat() async {
        let payload: [String: Any?] = ["op": 1, "d": sequence]
        await sendRaw(payload)
    }

    private func identify(token: String) async {
        let identify: [String: Any] = [
            "token": token,
            "intents": 37_639,
            "properties": ["$os": "macOS", "$browser": "DiscordBotNative", "$device": "DiscordBotNative"]
        ]
        await sendRaw(["op": 2, "d": identify])
    }

    func sendMessage(channelId: String, content: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return }

        if http.statusCode == 429 {
            throw NSError(domain: "DiscordService", code: 429, userInfo: [NSLocalizedDescriptionKey: "Rate limited"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Failed to send message"])
        }
    }

    private func sendRaw(_ dictionary: [String: Any]) async {
        guard let socket else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            if let text = String(data: data, encoding: .utf8) {
                try await socket.send(.string(text))
            }
        } catch {
            // noop, routed to reconnect by receive loop if needed.
        }
    }
}
