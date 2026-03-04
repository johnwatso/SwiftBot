import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol AIEngine {
    func generate(messages: [Message]) async -> String?
}

private enum EngineMessageRole: String {
    case system
    case user
    case assistant
}

private struct EngineMessage {
    let role: EngineMessageRole
    let content: String
}

private extension Array where Element == Message {
    func toEngineMessages() -> [EngineMessage] {
        compactMap { message in
            let trimmed = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let role: EngineMessageRole
            switch message.role {
            case .system:
                role = .system
            case .assistant:
                role = .assistant
            case .user:
                role = .user
            }
            return EngineMessage(role: role, content: trimmed)
        }
    }
}

private func cleanOutput(_ raw: String) -> String {
    var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefixes = ["assistant:", "user:"]

    var shouldContinue = true
    while shouldContinue {
        shouldContinue = false
        let lowered = cleaned.lowercased()
        for prefix in prefixes where lowered.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            shouldContinue = true
            break
        }
    }

    return cleaned
}

struct AppleIntelligenceEngine: AIEngine {
    let defaultSystemPrompt: String

    func generate(messages: [Message]) async -> String? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability else { return nil }
            let engineMessages = messages.toEngineMessages()
            guard let lastUserIndex = engineMessages.lastIndex(where: { $0.role == .user }) else { return nil }

            let instructions = engineMessages
                .last(where: { $0.role == .system })?
                .content ?? defaultSystemPrompt
            let prompt = engineMessages[lastUserIndex].content
            guard !prompt.isEmpty else { return nil }

            var transcriptEntries: [Transcript.Entry] = [
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: instructions))],
                        toolDefinitions: []
                    )
                )
            ]
            for message in engineMessages.prefix(lastUserIndex) {
                switch message.role {
                case .system:
                    continue
                case .user:
                    transcriptEntries.append(
                        .prompt(
                            Transcript.Prompt(
                                segments: [.text(Transcript.TextSegment(content: message.content))]
                            )
                        )
                    )
                case .assistant:
                    transcriptEntries.append(
                        .response(
                            Transcript.Response(
                                assetIDs: [],
                                segments: [.text(Transcript.TextSegment(content: message.content))]
                            )
                        )
                    )
                }
            }

            let session = LanguageModelSession(
                model: model,
                transcript: Transcript(entries: transcriptEntries)
            )
            do {
                let response = try await session.respond(to: prompt)
                let content = cleanOutput(response.content)
                return content.isEmpty ? nil : content
            } catch {
                return nil
            }
        }
#endif
        return nil
    }
}

struct OllamaEngine: AIEngine {
    let baseURL: String
    let preferredModel: String?
    let session: URLSession

    private struct PayloadMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatPayload: Encodable {
        let model: String
        let stream: Bool
        let messages: [PayloadMessage]
    }

    func generate(messages: [Message]) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/chat") else { return nil }
        guard let model = await Self.resolveModel(baseURL: baseURL, preferredModel: preferredModel, session: session) else { return nil }

        let payloadMessages = messages.toEngineMessages().map { message in
            PayloadMessage(role: message.role.rawValue, content: message.content)
        }

        guard payloadMessages.contains(where: { $0.role == EngineMessageRole.user.rawValue }) else { return nil }

        let payload = ChatPayload(model: model, stream: false, messages: payloadMessages)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? String
            else { return nil }

            let cleaned = cleanOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    static func resolveModel(baseURL: String, preferredModel: String?, session: URLSession) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let models = object["models"] as? [[String: Any]],
                !models.isEmpty
            else { return nil }

            let names = models.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return nil }

            let preferred = preferredModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !preferred.isEmpty {
                if let exact = names.first(where: { $0 == preferred }) { return exact }
                if let starts = names.first(where: { $0.hasPrefix(preferred) }) { return starts }
            }
            return names.first
        } catch {
            return nil
        }
    }
}

actor DiscordService {
    private let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private let restBase = URL(string: "https://discord.com/api/v10")!
    private let finalsWikiAPI = URL(string: "https://www.thefinals.wiki/api.php")!
    private let duckDuckGoHTML = URL(string: "https://duckduckgo.com/html/")!
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
    private var voiceChannelNamesByGuild: [String: [String: String]] = [:]
    private var channelTypeById: [String: Int] = [:]

    private var localAIDMReplyEnabled = false
    private var localAIProvider: AIProvider = .appleIntelligence
    private var localPreferredAIProvider: AIProviderPreference = .apple
    private var localAIEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
    private var localAIModel = "local-model"
    private var localAISystemPrompt = ""

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

    func configureLocalAIDMReplies(
        enabled: Bool,
        provider: AIProvider,
        preferredProvider: AIProviderPreference,
        endpoint: String,
        model: String,
        systemPrompt: String
    ) {
        localAIDMReplyEnabled = enabled
        localAIProvider = provider
        localPreferredAIProvider = preferredProvider
        localAIEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        localAIModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        localAISystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectOllamaModel(baseURL: String) async -> String? {
        await detectOllamaModel(baseURL: baseURL, preferredModel: nil)
    }

    func currentAIStatus(ollamaBaseURL: String, ollamaModelHint: String?) async -> (appleOnline: Bool, ollamaOnline: Bool, ollamaModel: String?) {
        let appleOnline = isAppleIntelligenceAvailable()
        let normalized = normalizedOllamaBaseURL(ollamaBaseURL)
        let model = await detectOllamaModel(baseURL: normalized, preferredModel: ollamaModelHint)
        return (appleOnline, model != nil, model)
    }

    func generateSmartDMReply(messages: [Message]) async -> String? {
        await generateLocalAIDMReply(messages: messages)
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        let isFinalsSource = source.baseURL.lowercased().contains("thefinals.wiki")
        if isFinalsSource, let finalsResult = await lookupFinalsWiki(query: query) {
            return finalsResult
        }
        return await lookupGenericMediaWiki(query: query, source: source)
    }

    func lookupFinalsWiki(query: String) async -> FinalsWikiLookupResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        if let direct = await fetchDirectFinalsWikiPage(query: trimmedQuery) {
            return direct
        }

        if let title = await searchFinalsWikiTitle(query: trimmedQuery) {
            if let pageResult = await fetchFinalsWikiPage(forTitle: title),
               pageResult.weaponStats != nil {
                return pageResult
            }

            if let result = await fetchFinalsWikiSummary(title: title) {
                return result
            }
        }

        if let result = await searchFinalsWikiViaSiteSearch(query: trimmedQuery) {
            return result
        }

        return await searchFinalsWikiViaWeb(query: trimmedQuery)
    }

    private func lookupGenericMediaWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        guard
            let baseURL = normalizedWikiBaseURL(from: source.baseURL),
            let apiURL = mediaWikiAPIURL(baseURL: baseURL, apiPath: source.apiPath)
        else {
            return nil
        }

        if let direct = await fetchGenericWikiPage(baseURL: baseURL, query: trimmedQuery) {
            return direct
        }

        guard let title = await searchMediaWikiTitle(query: trimmedQuery, apiURL: apiURL) else {
            return nil
        }
        return await fetchMediaWikiSummary(title: title, apiURL: apiURL, baseURL: baseURL)
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
        voiceChannelNamesByGuild.removeAll()
        channelTypeById.removeAll()
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
                    seedChannelTypesIfNeeded(payload)
                    seedVoiceChannelsIfNeeded(payload)
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

        let identify: [String: Any] = [
            "token": token,
            "intents": 37_767,
            "properties": ["$os": "macOS", "$browser": "SwiftBot", "$device": "SwiftBot"],
            "presence": presence
        ]
        await sendRaw(["op": 2, "d": identify])
    }

    func sendMessage(channelId: String, content: String, token: String) async throws {
        _ = try await sendMessage(channelId: channelId, payload: ["content": content], token: token)
    }

    @discardableResult
    func sendMessage(channelId: String, payload: [String: Any], token: String) async throws -> (statusCode: Int, responseBody: String) {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "DiscordService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response",
                    "statusCode": -1,
                    "responseBody": ""
                ]
            )
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 429 {
            throw NSError(
                domain: "DiscordService",
                code: 429,
                userInfo: [
                    NSLocalizedDescriptionKey: "Rate limited",
                    "statusCode": http.statusCode,
                    "responseBody": responseBody
                ]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to send message",
                    "statusCode": http.statusCode,
                    "responseBody": responseBody
                ]
            )
        }
        return (http.statusCode, responseBody)
    }

    private func seedVoiceChannelsIfNeeded(_ payload: GatewayPayload) {
        guard payload.op == 0, payload.t == "GUILD_CREATE" else { return }
        guard case let .object(guildMap)? = payload.d,
              case let .string(guildId)? = guildMap["id"],
              case let .array(channels)? = guildMap["channels"]
        else { return }

        var names: [String: String] = [:]
        for channel in channels {
            guard case let .object(channelMap) = channel,
                  case let .string(channelId)? = channelMap["id"],
                  case let .string(channelName)? = channelMap["name"],
                  case let .int(type)? = channelMap["type"]
            else { continue }

            // Discord voice = 2, stage = 13
            if type == 2 || type == 13 {
                names[channelId] = channelName
            }
        }

        if !names.isEmpty {
            voiceChannelNamesByGuild[guildId] = names
        }
    }

    private func seedChannelTypesIfNeeded(_ payload: GatewayPayload) {
        guard payload.op == 0 else { return }
        switch payload.t {
        case "GUILD_CREATE":
            guard case let .object(guildMap)? = payload.d,
                  case let .array(channels)? = guildMap["channels"]
            else { return }
            for channel in channels {
                guard case let .object(channelMap) = channel,
                      case let .string(channelId)? = channelMap["id"],
                      case let .int(type)? = channelMap["type"]
                else { continue }
                channelTypeById[channelId] = type
            }
        case "CHANNEL_CREATE", "CHANNEL_UPDATE":
            guard case let .object(map)? = payload.d,
                  case let .string(channelId)? = map["id"],
                  case let .int(type)? = map["type"]
            else { return }
            channelTypeById[channelId] = type
        case "CHANNEL_DELETE":
            guard case let .object(map)? = payload.d,
                  case let .string(channelId)? = map["id"]
            else { return }
            channelTypeById[channelId] = nil
        case "MESSAGE_CREATE":
            guard case let .object(map)? = payload.d,
                  case let .string(channelId)? = map["channel_id"],
                  case let .int(type)? = map["channel_type"]
            else { return }
            channelTypeById[channelId] = type
        default:
            break
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
        guard payload.op == 0 else { return }

        let event: VoiceRuleEvent?
        switch payload.t {
        case "VOICE_STATE_UPDATE":
            event = parseVoiceRuleEvent(from: payload.d)
        case "MESSAGE_CREATE":
            event = parseMessageRuleEvent(from: payload.d)
        default:
            event = nil
        }

        guard let event else { return }

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
                durationSeconds: nil,
                messageContent: nil,
                isDirectMessage: false
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
                durationSeconds: durationSeconds,
                messageContent: nil,
                isDirectMessage: false
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
                durationSeconds: durationSeconds,
                messageContent: nil,
                isDirectMessage: false
            )
        }

        return nil
    }

    private func parseMessageRuleEvent(from raw: DiscordJSON?) -> VoiceRuleEvent? {
        guard case let .object(map)? = raw,
              case let .object(author)? = map["author"],
              case let .string(userId)? = author["id"],
              case let .string(username)? = author["username"],
              case let .string(content)? = map["content"],
              case let .string(channelId)? = map["channel_id"]
        else { return nil }

        if case let .bool(isBot)? = author["bot"], isBot {
            return nil
        }

        let guildId: String = {
            if case let .string(gid)? = map["guild_id"] { return gid }
            return ""
        }()
        let channelType = resolvedMessageChannelType(from: map, channelId: channelId)
        let isDirectMessage = (channelType == 1 || channelType == 3)

        return VoiceRuleEvent(
            kind: .message,
            guildId: guildId,
            userId: userId,
            username: username,
            channelId: channelId,
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: content,
            isDirectMessage: isDirectMessage
        )
    }

    private func resolvedMessageChannelType(from map: [String: DiscordJSON], channelId: String) -> Int? {
        if case let .int(type)? = map["channel_type"] {
            return type
        }
        return channelTypeById[channelId]
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
            guard let token = botToken else { return }
            let targetChannelId = (event.kind == .message) ? event.channelId : action.channelId
            guard !targetChannelId.isEmpty else { return }

            let rendered: String
            if event.kind == .message,
               event.isDirectMessage,
               localAIDMReplyEnabled,
               let userMessage = event.messageContent,
               let aiReply = await generateLocalAIDMReply(messages: [
                    Message(
                        channelID: event.channelId,
                        userID: "system",
                        username: "System",
                        content: localAISystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "You are a friendly Discord assistant. Reply briefly and naturally."
                            : localAISystemPrompt,
                        role: .system
                    ),
                    Message(
                        channelID: event.channelId,
                        userID: event.userId,
                        username: event.username,
                        content: userMessage,
                        role: .user
                    )
               ]) {
                rendered = aiReply
            } else {
                rendered = renderMessage(template: action.message, event: event, mentionUser: action.mentionUser)
            }

            try? await sendMessage(channelId: targetChannelId, content: rendered, token: token)
        case .addLogEntry:
            return
        case .setStatus:
            guard !action.statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await updatePresence(text: action.statusText)
        }
    }

    private func renderMessage(template: String, event: VoiceRuleEvent, mentionUser: Bool) -> String {
        let channelId = event.channelId
        let fromChannelId = event.fromChannelId ?? channelId
        let toChannelId = event.toChannelId ?? channelId

        let channelName = resolvedChannelName(guildId: event.guildId, channelId: channelId)
        let fromChannelName = resolvedChannelName(guildId: event.guildId, channelId: fromChannelId)
        let toChannelName = resolvedChannelName(guildId: event.guildId, channelId: toChannelId)

        var output = template
            .replacingOccurrences(of: "<#{channelId}>", with: channelName)
            .replacingOccurrences(of: "<#{fromChannelId}>", with: fromChannelName)
            .replacingOccurrences(of: "<#{toChannelId}>", with: toChannelName)
            .replacingOccurrences(of: "{userId}", with: event.userId)
            .replacingOccurrences(of: "{username}", with: event.username)
            .replacingOccurrences(of: "{guildId}", with: event.guildId)
            .replacingOccurrences(of: "{guildName}", with: event.guildId)
            .replacingOccurrences(of: "{channelId}", with: channelId)
            .replacingOccurrences(of: "{channelName}", with: channelName)
            .replacingOccurrences(of: "{fromChannelId}", with: fromChannelId)
            .replacingOccurrences(of: "{toChannelId}", with: toChannelId)
            .replacingOccurrences(of: "{duration}", with: formatDuration(seconds: event.durationSeconds))

        if !mentionUser {
            output = output.replacingOccurrences(of: "<@\(event.userId)>", with: event.username)
        }

        return output
    }

    private func resolvedChannelName(guildId: String, channelId: String) -> String {
        if let name = voiceChannelNamesByGuild[guildId]?[channelId], !name.isEmpty {
            return name
        }
        return "Channel \(channelId.suffix(5))"
    }

    private func generateLocalAIDMReply(messages: [Message]) async -> String? {
        guard localAIDMReplyEnabled else { return nil }

        let systemPrompt = localAISystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "You are a friendly Discord assistant. Reply briefly and naturally."
            : localAISystemPrompt
        let cleanedMessages = messages.filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard cleanedMessages.contains(where: { $0.role == .user }) else { return nil }

        let appleEngine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let ollamaEngine = OllamaEngine(
            baseURL: normalizedOllamaBaseURL(localAIEndpoint),
            preferredModel: localAIModel,
            session: session
        )

        let preferred = localPreferredAIProvider
        if preferred == .apple {
            if let reply = await appleEngine.generate(messages: cleanedMessages) {
                let cleaned = cleanOutput(reply)
                return cleaned.isEmpty ? nil : cleaned
            }
            if let reply = await ollamaEngine.generate(messages: cleanedMessages) {
                let cleaned = cleanOutput(reply)
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        } else {
            if let reply = await ollamaEngine.generate(messages: cleanedMessages) {
                let cleaned = cleanOutput(reply)
                return cleaned.isEmpty ? nil : cleaned
            }
            if let reply = await appleEngine.generate(messages: cleanedMessages) {
                let cleaned = cleanOutput(reply)
                return cleaned.isEmpty ? nil : cleaned
            }
            return nil
        }
    }

    private func detectOllamaModel(baseURL: String, preferredModel: String?) async -> String? {
        await OllamaEngine.resolveModel(baseURL: baseURL, preferredModel: preferredModel, session: session)
    }

    private func normalizedOllamaBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "http://localhost:11434" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed)"
    }

    private func isAppleIntelligenceAvailable() -> Bool {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                return true
            }
        }
#endif
        return false
    }

    private func normalizedWikiBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")) ? trimmed : "https://\(trimmed)"
        return URL(string: candidate)
    }

    private func mediaWikiAPIURL(baseURL: URL, apiPath: String) -> URL? {
        let trimmedPath = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmedPath.isEmpty ? "/api.php" : (trimmedPath.hasPrefix("/") ? trimmedPath : "/\(trimmedPath)")
        return URL(string: normalizedPath, relativeTo: baseURL)?.absoluteURL
    }

    private func searchMediaWikiTitle(query: String, apiURL: URL) async -> String? {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "origin", value: "*")
        ]

        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(MediaWikiSearchResponse.self, from: data)
            return decoded.query?.search.first?.title
        } catch {
            return nil
        }
    }

    private func fetchMediaWikiSummary(title: String, apiURL: URL, baseURL: URL) async -> FinalsWikiLookupResult? {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "origin", value: "*")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(MediaWikiPageResponse.self, from: data)
            guard let page = decoded.query?.pages.values.first,
                  page.missing == nil else { return nil }

            let summary = page.extract?
                .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fallbackURL = baseURL
                .appendingPathComponent("wiki")
                .appendingPathComponent(title.replacingOccurrences(of: " ", with: "_"))
                .absoluteString

            return FinalsWikiLookupResult(
                title: page.title,
                extract: summary,
                url: page.fullurl ?? fallbackURL,
                weaponStats: nil
            )
        } catch {
            return nil
        }
    }

    private func fetchGenericWikiPage(baseURL: URL, query: String) async -> FinalsWikiLookupResult? {
        let slug = query
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard !slug.isEmpty else { return nil }

        let pageURL = baseURL
            .appendingPathComponent("wiki")
            .appendingPathComponent(slug)

        do {
            var request = URLRequest(url: pageURL)
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let title = extractHTMLTitle(from: html) ?? query
            let extract = extractSummaryParagraph(from: html)
            let resolvedURL = extractCanonicalWikiPageURL(from: html)?.absoluteString ?? pageURL.absoluteString

            return FinalsWikiLookupResult(
                title: title,
                extract: extract,
                url: resolvedURL,
                weaponStats: nil
            )
        } catch {
            return nil
        }
    }

    private func searchFinalsWikiTitle(query: String) async -> String? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "origin", value: "*")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(MediaWikiSearchResponse.self, from: data)
            return decoded.query?.search.first?.title
        } catch {
            return nil
        }
    }

    private func fetchFinalsWikiSummary(title: String) async -> FinalsWikiLookupResult? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "origin", value: "*")
        ]

        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(MediaWikiPageResponse.self, from: data)
            guard let page = decoded.query?.pages.values.first,
                  page.missing == nil else { return nil }

            let summary = page.extract?
                .replacingOccurrences(of: "\n+", with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let fallbackURL = "https://www.thefinals.wiki/wiki/" + title.replacingOccurrences(of: " ", with: "_")
            return FinalsWikiLookupResult(
                title: page.title,
                extract: summary,
                url: page.fullurl ?? fallbackURL,
                weaponStats: nil
            )
        } catch {
            return nil
        }
    }

    private func fetchDirectFinalsWikiPage(query: String) async -> FinalsWikiLookupResult? {
        for candidate in directFinalsWikiCandidateURLs(for: query) {
            if let result = await fetchFinalsWikiPage(at: candidate) {
                return result
            }
        }
        return nil
    }

    private func fetchFinalsWikiPage(forTitle title: String) async -> FinalsWikiLookupResult? {
        let slug = title
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard !slug.isEmpty,
              let url = URL(string: "https://www.thefinals.wiki/wiki/\(slug)") else { return nil }
        return await fetchFinalsWikiPage(at: url)
    }

    private func directFinalsWikiCandidateURLs(for query: String) -> [URL] {
        let cleaned = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let variants = [
            cleaned,
            cleaned.localizedCapitalized,
            cleaned.uppercased(),
            cleaned.lowercased()
        ]

        var urls: [URL] = []
        var seen: Set<String> = []
        for variant in variants {
            let slug = variant
                .replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            guard !slug.isEmpty else { continue }
            let absolute = "https://www.thefinals.wiki/wiki/\(slug)"
            if seen.insert(absolute).inserted, let url = URL(string: absolute) {
                urls.append(url)
            }
        }
        return urls
    }

    private func fetchFinalsWikiPage(at pageURL: URL) async -> FinalsWikiLookupResult? {
        do {
            var request = URLRequest(url: pageURL)
            request.setValue("SwiftBot/1.0 (+https://www.thefinals.wiki/wiki/Main_Page)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let title = extractHTMLTitle(from: html)
            if let title, !isMeaningfulFinalsWikiTitle(title) {
                return nil
            }

            let extract = extractSummaryParagraph(from: html)
            let resolvedURL = extractCanonicalWikiPageURL(from: html) ?? pageURL
            let weaponStats = extractWeaponStats(from: html)
            return FinalsWikiLookupResult(
                title: title ?? resolvedURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                extract: extract,
                url: resolvedURL.absoluteString,
                weaponStats: weaponStats
            )
        } catch {
            return nil
        }
    }

    private func searchFinalsWikiViaSiteSearch(query: String) async -> FinalsWikiLookupResult? {
        var components = URLComponents(string: "https://www.thefinals.wiki/wiki/Special:Search")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query)
        ]

        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let hrefMatches = html.matches(for: "href=\\\"(/wiki/[^\\\"#?]+)\\\"")
            for href in hrefMatches {
                guard let pageURL = URL(string: "https://www.thefinals.wiki\(href)"),
                      isAcceptableFinalsWikiPage(pageURL),
                      let result = await fetchFinalsWikiPage(at: pageURL) else { continue }
                return result
            }
        } catch {
            return nil
        }

        return nil
    }

    private func searchFinalsWikiViaWeb(query: String) async -> FinalsWikiLookupResult? {
        guard let pageURL = await searchFinalsWikiPageURL(query: query) else { return nil }
        return await fetchFinalsWikiPage(at: pageURL)
    }

    private func searchFinalsWikiPageURL(query: String) async -> URL? {
        var components = URLComponents(url: duckDuckGoHTML, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: "site:thefinals.wiki/wiki \(query)")
        ]

        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let matches = html.matches(for: #"https?%3A%2F%2Fwww\.thefinals\.wiki%2Fwiki%2F[^"&<]+"#)
            for encoded in matches {
                let decoded = encoded.removingPercentEncoding ?? encoded
                if let url = URL(string: decoded),
                   isAcceptableFinalsWikiPage(url) {
                    return url
                }
            }

            let directMatches = html.matches(for: #"https://www\.thefinals\.wiki/wiki/[^"'&< ]+"#)
            for match in directMatches {
                if let url = URL(string: match),
                   isAcceptableFinalsWikiPage(url) {
                    return url
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func isAcceptableFinalsWikiPage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if !path.hasPrefix("/wiki/") { return false }
        if path.contains("special:") || path.contains("/file:") || path.hasSuffix("/main_page") {
            return false
        }
        return true
    }

    private func extractHTMLTitle(from html: String) -> String? {
        guard let rawTitle = html.firstMatch(for: #"<title>(.*?)</title>"#) else { return nil }
        let cleaned = decodeHTMLEntities(rawTitle)
            .replacingOccurrences(of: " - THE FINALS Wiki", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func isMeaningfulFinalsWikiTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return !lowered.contains("search results") &&
            !lowered.contains("create the page") &&
            !lowered.contains("main page")
    }

    private func extractCanonicalWikiPageURL(from html: String) -> URL? {
        guard let canonical = html.firstMatch(for: #"<link[^>]+rel=\"canonical\"[^>]+href=\"([^\"]+)\""#) else {
            return nil
        }
        return URL(string: decodeHTMLEntities(canonical))
    }

    private func extractSummaryParagraph(from html: String) -> String {
        let paragraphs = html.matches(for: #"<p\b[^>]*>(.*?)</p>"#)
        for paragraph in paragraphs {
            let stripped = stripHTML(paragraph)
                .replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if stripped.count >= 40,
               !stripped.lowercased().contains("retrieved from"),
               !stripped.lowercased().hasPrefix("main page:") {
                return stripped
            }
        }

        return ""
    }

    private func extractWeaponStats(from html: String) -> FinalsWeaponStats? {
        if let parsedFromText = extractWeaponStatsFromText(html: html) {
            return parsedFromText
        }

        if let parsedFromNormalizedText = extractWeaponStatsFromNormalizedText(html: html) {
            return parsedFromNormalizedText
        }

        let profileSection = extractSectionHTML(named: "Profile", from: html)
        let damageSection = extractSectionHTML(named: "Damage", from: html)
        let falloffSection = extractSectionHTML(named: "Damage Falloff", from: html)
        let technicalSection = extractSectionHTML(named: "Technical", from: html)

        let type = profileSection.flatMap { extractTableValue(label: "Type", from: $0) }
        let bodyDamage = damageSection.flatMap { extractTableValue(label: "Body", from: $0) }
        let headshotDamage = damageSection.flatMap { extractTableValue(label: "Head", from: $0) }
        let fireRate = technicalSection.flatMap {
            extractTableValue(label: "RPM", from: $0) ?? extractTableValue(label: "Fire Rate", from: $0)
        }
        let dropoffStart = falloffSection.flatMap {
            extractTableValue(label: "Min Range", from: $0) ?? extractTableValue(label: "Dropoff Start", from: $0)
        }
        let dropoffEnd = falloffSection.flatMap {
            extractTableValue(label: "Max Range", from: $0) ?? extractTableValue(label: "Dropoff End", from: $0)
        }
        let minimumDamage = computeMinimumDamage(
            bodyDamage: bodyDamage,
            multiplier: falloffSection.flatMap {
                extractTableValue(label: "Multiplier", from: $0) ?? extractTableValue(label: "Min Damage Multiplier", from: $0)
            }
        )
        let magazineSize = technicalSection.flatMap {
            extractTableValue(label: "Magazine", from: $0) ?? extractTableValue(label: "Mag Size", from: $0)
        }
        let shortReload = technicalSection.flatMap {
            extractTableValue(label: "Tactical Reload", from: $0) ?? extractTableValue(label: "Short Reload", from: $0)
        }
        let longReload = technicalSection.flatMap {
            extractTableValue(label: "Empty Reload", from: $0) ?? extractTableValue(label: "Long Reload", from: $0)
        }

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(minimumDamage),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.headshotDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.shortReload,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func extractWeaponStatsFromText(html: String) -> FinalsWeaponStats? {
        let rawLines = readableTextLines(from: html)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let profileIndex = rawLines.firstIndex { normalizedLabel($0) == "profile" } ?? 0
        let slice = Array(rawLines[profileIndex...])

        let type = value(in: slice, labels: ["Type"])
        let bodyDamage = value(in: slice, labels: ["Body"])
        let fireRate = value(in: slice, labels: ["RPM", "Fire Rate"])
        let dropoffStart = value(in: slice, labels: ["Min Range", "Dropoff Start"])
        let dropoffEnd = value(in: slice, labels: ["Max Range", "Dropoff End"])
        let multiplier = value(in: slice, labels: ["Multiplier", "Min Damage Multiplier"])
        let magazineSize = value(in: slice, labels: ["Magazine", "Mag Size"])
        let longReload = value(in: slice, labels: ["Empty Reload", "Long Reload"])
        let shortReload = value(in: slice, labels: ["Tactical Reload", "Short Reload"])

        let headshotDamage: String?
        if let explicitHead = value(in: slice, labels: ["Head", "Critical Hit", "Headshot"]) {
            headshotDamage = explicitHead
        } else if slice.contains(where: { $0.localizedCaseInsensitiveContains("No Critical Hit") }) ||
                    slice.contains(where: { $0.localizedCaseInsensitiveContains("does not critically hit") }) {
            headshotDamage = "No critical hit"
        } else {
            headshotDamage = nil
        }

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computeMinimumDamage(bodyDamage: bodyDamage, multiplier: multiplier)),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func extractWeaponStatsFromNormalizedText(html: String) -> FinalsWeaponStats? {
        let normalized = stripHTML(html)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let profileText = sectionText(in: normalized, heading: "Profile", nextHeadings: ["Damage", "Stats", "Usage", "Technical"])
        let damageText = sectionText(in: normalized, heading: "Damage", nextHeadings: ["Damage Falloff", "Technical", "Stats", "Usage"])
        let falloffText = sectionText(in: normalized, heading: "Damage Falloff", nextHeadings: ["Technical", "Stats", "Usage"])
        let technicalText = sectionText(in: normalized, heading: "Technical", nextHeadings: ["Usage", "Stats", "Controls", "Properties"])
        let propertiesText = sectionText(in: normalized, heading: "Properties", nextHeadings: ["Item Mastery", "Weapon Skins", "Trivia", "History"])

        let type = firstCapturedValue(
            in: profileText,
            patterns: [
                #"Type\s*:?\s*(.+?)(?=\s+Unlock\b|\s+Damage\b|\s+Build\b|$)"#
            ]
        )

        let bodyDamage = firstCapturedValue(
            in: damageText,
            patterns: [
                #"Body\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*[x×]\s*[0-9]+(?:\.[0-9]+)?)?)(?=\s+Environmental\b|\s+Damage Falloff\b|\s+Technical\b|$)"#
            ]
        )

        let fireRate = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"RPM\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Magazine\b|\s+Empty Reload\b|\s+Tactical Reload\b|$)"#,
                #"Fire Rate\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*RPM)?)(?=\s+Magazine\b|\s+Reload\b|$)"#
            ]
        )

        let dropoffStart = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Min Range\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Max Range\b|\s+Multiplier\b|$)"#,
                #"Dropoff Start\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Dropoff End\b|\s+Multiplier\b|$)"#
            ]
        )

        let dropoffEnd = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Max Range\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Multiplier\b|\s+Technical\b|$)"#,
                #"Dropoff End\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Multiplier\b|\s+Technical\b|$)"#
            ]
        )

        let multiplier = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Multiplier\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Technical\b|\s+Usage\b|$)"#,
                #"Min Damage Multiplier\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Technical\b|\s+Usage\b|$)"#
            ]
        )

        let magazineSize = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Magazine\s*:?\s*([0-9]+)(?=\s+Empty Reload\b|\s+Tactical Reload\b|\s+Controls\b|$)"#,
                #"Mag Size\s*:?\s*([0-9]+)(?=\s+Reload\b|\s+Controls\b|$)"#
            ]
        )

        let shortReload = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Tactical Reload\s*:?\s*(Segmented|[0-9]+(?:\.[0-9]+)?s)(?=\s+Controls\b|\s+Usage\b|$)"#,
                #"Short Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Long Reload\b|\s+Controls\b|$)"#
            ]
        )

        let longReload = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Empty Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Tactical Reload\b|\s+Controls\b|\s+Usage\b|$)"#,
                #"Long Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Short Reload\b|\s+Controls\b|$)"#
            ]
        )

        let headshotDamage: String?
        if propertiesText.localizedCaseInsensitiveContains("No Critical Hit") ||
            normalized.localizedCaseInsensitiveContains("No Critical Hit") {
            headshotDamage = "No critical hit"
        } else {
            headshotDamage = firstCapturedValue(
                in: damageText,
                patterns: [
                    #"Head\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*[x×]\s*[0-9]+(?:\.[0-9]+)?)?)(?=\s+Environmental\b|\s+Damage Falloff\b|\s+Technical\b|$)"#
                ]
            )
        }

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computeMinimumDamage(bodyDamage: bodyDamage, multiplier: multiplier)),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func readableTextLines(from html: String) -> [String] {
        let blockSeparated = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</(p|div|section|article|header|footer|li|tr|td|th|h1|h2|h3|h4|h5|h6|figcaption|caption|dd|dt)>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(p|div|section|article|header|footer|li|tr|td|th|h1|h2|h3|h4|h5|h6|figcaption|caption|dd|dt)\b[^>]*>"#, with: "\n", options: .regularExpression)

        let text = stripHTML(blockSeparated)
        return text.components(separatedBy: .newlines)
    }

    private func sectionText(in normalized: String, heading: String, nextHeadings: [String]) -> String {
        guard let range = normalized.range(of: heading, options: [.caseInsensitive]) else {
            return normalized
        }

        let tail = String(normalized[range.lowerBound...])
        var endIndex = tail.endIndex

        for nextHeading in nextHeadings {
            if let nextRange = tail.range(of: nextHeading, options: [.caseInsensitive]),
               nextRange.lowerBound > tail.startIndex,
               nextRange.lowerBound < endIndex {
                endIndex = nextRange.lowerBound
            }
        }

        return String(tail[..<endIndex])
    }

    private func firstCapturedValue(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let value = text.firstMatch(for: pattern) {
                let cleaned = value
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func value(in lines: [String], labels: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            for label in labels {
                if let inlineValue = inlineValue(in: line, label: label) {
                    return inlineValue
                }

                if normalizedLabel(line) == normalizedLabel(label),
                   let nextValue = nextValue(in: lines, after: index) {
                    return nextValue
                }
            }
        }
        return nil
    }

    private func inlineValue(in line: String, label: String) -> String? {
        let candidates = [
            label + " ",
            label + ": ",
            label + "\t",
            label
        ]

        for candidate in candidates where line.hasPrefix(candidate) {
            let value = String(line.dropFirst(candidate.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func nextValue(in lines: [String], after index: Int) -> String? {
        guard index + 1 < lines.count else { return nil }

        for candidate in lines[(index + 1)...] {
            if candidate.hasSuffix(":") {
                continue
            }

            let normalized = normalizedLabel(candidate)
            if normalized == "profile" || normalized == "damage" || normalized == "damage falloff" || normalized == "technical" {
                return nil
            }

            if !candidate.isEmpty {
                return candidate
            }
        }

        return nil
    }

    private func normalizedLabel(_ text: String) -> String {
        text
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func extractSectionHTML(named sectionName: String, from html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: sectionName)
        let pattern = #"(?is)<h[2-4][^>]*>\s*.*?"# + escaped + #".*?</h[2-4]>(.*?)(?=<h[2-4][^>]*>|$)"#
        return html.firstMatch(for: pattern)
    }

    private func extractTableValue(label: String, from html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        let rowPatterns = [
            #"(?is)<tr[^>]*>\s*<t[hd][^>]*>\s*"# + escaped + #"\s*</t[hd]>\s*<t[hd][^>]*>(.*?)</t[hd]>\s*</tr>"#,
            #"(?is)"# + escaped + #"</[^>]+>\s*<[^>]+>(.*?)</[^>]+>"#
        ]

        for pattern in rowPatterns {
            if let value = html.firstMatch(for: pattern) {
                let cleaned = stripHTML(value)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func cleanedStatValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func computeMinimumDamage(bodyDamage: String?, multiplier: String?) -> String? {
        guard let bodyDamage, let multiplier,
              let multiplierValue = firstNumericValue(in: multiplier) else { return nil }

        let numbers = bodyDamage.matches(for: #"[0-9]+(?:\.[0-9]+)?"#)
        guard let first = numbers.first, let baseDamage = Double(first) else { return nil }

        let scaled = formatDamageValue(baseDamage * multiplierValue)
        if bodyDamage.contains("×") || bodyDamage.contains("x") || bodyDamage.contains("X") {
            if numbers.count >= 2 {
                return "\(scaled)×\(numbers[1])"
            }
            return "\(scaled)×?"
        }

        return scaled
    }

    private func firstNumericValue(in text: String) -> Double? {
        text.matches(for: #"[0-9]+(?:\.[0-9]+)?"#).first.flatMap(Double.init)
    }

    private func formatDamageValue(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    private func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else {
            return text
        }
        return attributed.string
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

private extension String {
    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: self) else { return nil }
            return String(self[range])
        }
    }

    func firstMatch(for pattern: String) -> String? {
        matches(for: pattern).first
    }
}

private struct MediaWikiSearchResponse: Decodable {
    let query: SearchQuery?

    struct SearchQuery: Decodable {
        let search: [SearchHit]
    }

    struct SearchHit: Decodable {
        let title: String
    }
}

private struct MediaWikiPageResponse: Decodable {
    let query: PageQuery?

    struct PageQuery: Decodable {
        let pages: [String: Page]
    }

    struct Page: Decodable {
        let title: String
        let extract: String?
        let fullurl: String?
        let missing: String?
    }
}
