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
    private var botToken: String?
    private var ruleEngine: RuleEngine?
    private var voiceChannelByMemberKey: [String: String] = [:]
    private var voiceJoinTimeByMemberKey: [String: Date] = [:]

    private let session = URLSession(configuration: .default)

    var onPayload: ((GatewayPayload) async -> Void)?
    var onConnectionState: ((BotStatus) async -> Void)?

    func setOnPayload(_ handler: @escaping (GatewayPayload) async -> Void) {
        onPayload = handler
    }

    func setOnConnectionState(_ handler: @escaping (BotStatus) async -> Void) {
        onConnectionState = handler
    }

    func setRuleEngine(_ engine: RuleEngine) {
        ruleEngine = engine
    }

    func connect(token: String) async {
        botToken = token
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
        botToken = nil
        voiceChannelByMemberKey.removeAll()
        voiceJoinTimeByMemberKey.removeAll()
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
                    seedVoiceStateIfNeeded(payload)
                    await processRuleActionsIfNeeded(payload)
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
        let presence: [String: Any] = [
            "since": NSNull(),
            "activities": [[
                "name": "Hello! Ping me for help",
                "type": 0
            ]],
            "status": "online",
            "afk": false
        ]

        let identify: [String: Any] = [
            "token": token,
            "intents": 37_767,
            "properties": ["$os": "macOS", "$browser": "DiscordBotNative", "$device": "DiscordBotNative"],
            "presence": presence
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

    private func seedVoiceStateIfNeeded(_ payload: GatewayPayload) {
        guard payload.op == 0, payload.t == "GUILD_CREATE" else { return }
        guard case let .object(guildMap)? = payload.d,
              case let .string(guildId)? = guildMap["id"],
              case let .array(voiceStates)? = guildMap["voice_states"]
        else { return }

        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            let key = "\(guildId)-\(userId)"
            voiceChannelByMemberKey[key] = channelId
            voiceJoinTimeByMemberKey[key] = Date()
        }
    }

    private func processRuleActionsIfNeeded(_ payload: GatewayPayload) async {
        guard payload.op == 0, payload.t == "VOICE_STATE_UPDATE" else { return }
        guard let event = parseVoiceRuleEvent(from: payload.d) else { return }

        let engine = ruleEngine
        let actions = await MainActor.run {
            engine?.evaluate(event: event) ?? []
        }

        for action in actions {
            await execute(action: action, for: event)
        }
    }

    private func parseVoiceRuleEvent(from raw: DiscordJSON?) -> VoiceRuleEvent? {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(guildId)? = map["guild_id"]
        else { return nil }

        let now = Date()
        let memberKey = "\(guildId)-\(userId)"
        let previousChannel = voiceChannelByMemberKey[memberKey]
        let newChannel: String?
        if case let .string(cid)? = map["channel_id"] { newChannel = cid } else { newChannel = nil }

        let username = parseUsername(from: map, userId: userId)

        if let newChannel, previousChannel == nil {
            voiceChannelByMemberKey[memberKey] = newChannel
            voiceJoinTimeByMemberKey[memberKey] = now
            return VoiceRuleEvent(
                kind: .join,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: newChannel,
                fromChannelId: nil,
                toChannelId: newChannel,
                durationSeconds: nil
            )
        }

        if let newChannel, let previousChannel, previousChannel != newChannel {
            let joinedAt = voiceJoinTimeByMemberKey[memberKey] ?? now
            let durationSeconds = Int(now.timeIntervalSince(joinedAt))
            voiceChannelByMemberKey[memberKey] = newChannel
            voiceJoinTimeByMemberKey[memberKey] = now
            return VoiceRuleEvent(
                kind: .move,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: newChannel,
                fromChannelId: previousChannel,
                toChannelId: newChannel,
                durationSeconds: durationSeconds
            )
        }

        if newChannel == nil, let previousChannel {
            let joinedAt = voiceJoinTimeByMemberKey[memberKey] ?? now
            let durationSeconds = Int(now.timeIntervalSince(joinedAt))
            voiceChannelByMemberKey[memberKey] = nil
            voiceJoinTimeByMemberKey[memberKey] = nil
            return VoiceRuleEvent(
                kind: .leave,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: previousChannel,
                fromChannelId: previousChannel,
                toChannelId: nil,
                durationSeconds: durationSeconds
            )
        }

        return nil
    }

    private func parseUsername(from map: [String: DiscordJSON], userId: String) -> String {
        if case let .object(member)? = map["member"],
           case let .object(user)? = member["user"],
           case let .string(username)? = user["username"] {
            return username
        }
        return "User \(userId.suffix(4))"
    }

    private func execute(action: Action, for event: VoiceRuleEvent) async {
        switch action.type {
        case .sendMessage:
            guard let token = botToken, !action.channelId.isEmpty else { return }
            let rendered = renderMessage(template: action.message, event: event, mentionUser: action.mentionUser)
            try? await sendMessage(channelId: action.channelId, content: rendered, token: token)
        case .addLogEntry:
            return
        case .setStatus:
            guard !action.statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await updatePresence(text: action.statusText)
        }
    }

    private func renderMessage(template: String, event: VoiceRuleEvent, mentionUser: Bool) -> String {
        var output = template
            .replacingOccurrences(of: "{userId}", with: event.userId)
            .replacingOccurrences(of: "{username}", with: event.username)
            .replacingOccurrences(of: "{guildId}", with: event.guildId)
            .replacingOccurrences(of: "{guildName}", with: event.guildId)
            .replacingOccurrences(of: "{channelId}", with: event.channelId)
            .replacingOccurrences(of: "{channelName}", with: event.channelId)
            .replacingOccurrences(of: "{fromChannelId}", with: event.fromChannelId ?? event.channelId)
            .replacingOccurrences(of: "{toChannelId}", with: event.toChannelId ?? event.channelId)
            .replacingOccurrences(of: "{duration}", with: formatDuration(seconds: event.durationSeconds))

        if !mentionUser {
            output = output.replacingOccurrences(of: "<@\(event.userId)>", with: event.username)
        }

        return output
    }

    private func formatDuration(seconds: Int?) -> String {
        guard let seconds, seconds > 0 else { return "0s" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    private func updatePresence(text: String) async {
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
