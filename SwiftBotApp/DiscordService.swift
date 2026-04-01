import Foundation
import OSLog

actor DiscordService {

    /// Secondary safety guard — set by AppModel based on SwiftMesh cluster role.
    /// When `false`, all outbound Discord sends are blocked at the actor level.
    /// The primary gate is `ActionDispatcher`; this is a final backstop.
    private(set) var outputAllowed: Bool = true

    func setOutputAllowed(_ allowed: Bool) {
        outputAllowed = allowed
    }

    private let discordLogger = Logger(subsystem: "com.swiftbot", category: "discord")

    private let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private let restBase = URL(string: "https://discord.com/api/v10")!
    private let session: URLSession
    private let identitySession: URLSession
    private var botToken: String?
    private var ruleEngine: RuleEngine?
    private var voiceRuleStateStore = VoiceRuleStateStore()
    private var voiceChannelNamesByGuild: [String: [String: String]] = [:]
    private var channelTypeById: [String: Int] = [:]
    private var guildNamesById: [String: String] = [:]
    private let aiService: DiscordAIService
    private lazy var guildRESTClient = DiscordGuildRESTClient(session: session, restBase: restBase)
    private lazy var identityRESTClient = DiscordIdentityRESTClient(session: session, identitySession: identitySession, restBase: restBase)
    private lazy var interactionRESTClient = DiscordInteractionRESTClient(session: session, restBase: restBase)
    private lazy var messageRESTClient = DiscordMessageRESTClient(session: session, restBase: restBase)
    private lazy var ruleExecutionService = RuleExecutionService(
        aiService: aiService,
        dependencies: .init(
            sendMessage: { [weak self] channelId, content, token in
                try await self?.sendMessage(channelId: channelId, content: content, token: token)
            },
            sendPayloadMessage: { [weak self] channelId, payload, token in
                _ = try await self?.sendMessage(channelId: channelId, payload: payload, token: token)
            },
            sendDM: { [weak self] userId, content in
                try await self?.sendDM(userId: userId, content: content)
            },
            addReaction: { [weak self] channelId, messageId, emoji, token in
                try await self?.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
            },
            deleteMessage: { [weak self] channelId, messageId, token in
                try await self?.deleteMessage(channelId: channelId, messageId: messageId, token: token)
            },
            addRole: { [weak self] guildId, userId, roleId, token in
                try await self?.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
            },
            removeRole: { [weak self] guildId, userId, roleId, token in
                try await self?.removeRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
            },
            timeoutMember: { [weak self] guildId, userId, durationSeconds, token in
                try await self?.timeoutMember(guildId: guildId, userId: userId, durationSeconds: durationSeconds, token: token)
            },
            kickMember: { [weak self] guildId, userId, reason, token in
                try await self?.kickMember(guildId: guildId, userId: userId, reason: reason, token: token)
            },
            moveMember: { [weak self] guildId, userId, channelId, token in
                try await self?.moveMember(guildId: guildId, userId: userId, channelId: channelId, token: token)
            },
            createChannel: { [weak self] guildId, name, token in
                try await self?.createChannel(guildId: guildId, name: name, token: token)
            },
            sendWebhook: { [weak self] url, content in
                try await self?.sendWebhook(url: url, content: content)
            },
            updatePresence: { [weak self] text in
                await self?.updatePresence(text: text)
            },
            resolveChannelName: { [weak self] guildId, channelId in
                await self?.resolvedChannelName(guildId: guildId, channelId: channelId) ?? "Unknown"
            },
            resolveGuildName: { [weak self] guildId in
                await self?.guildNamesById[guildId]
            },
            debugLog: { [discordLogger] message in
                discordLogger.debug("\(message, privacy: .public)")
            }
        )
    )
    private let wikiLookupService: WikiLookupService
    private lazy var gatewayConnection = DiscordGatewayConnection(session: session, gatewayURL: gatewayURL)
    private var gatewayCallbacksConfigured = false

    typealias HistoryProvider = @Sendable (MemoryScope) async -> [Message]
    typealias ActiveVoiceJoinDateProvider = @Sendable (_ guildId: String, _ userId: String) async -> Date?
    private var historyProvider: HistoryProvider?
    private var activeVoiceJoinDateProvider: ActiveVoiceJoinDateProvider?

    private static func makeDefaultIdentitySession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }

    init(
        session: URLSession = URLSession(configuration: .default),
        identitySession: URLSession = DiscordService.makeDefaultIdentitySession(),
        aiService: DiscordAIService? = nil,
        wikiLookupService: WikiLookupService? = nil
    ) {
        self.session = session
        self.identitySession = identitySession
        self.aiService = aiService ?? DiscordAIService(session: session)
        self.wikiLookupService = wikiLookupService ?? WikiLookupService(session: session)
    }

    var onPayload: ((GatewayPayload) async -> Void)?
    var onConnectionState: ((BotStatus) async -> Void)?
    /// Called each time a heartbeat ACK (op 11) is received; value is round-trip ms.
    var onHeartbeatLatency: ((Int) async -> Void)?
    /// Called when the WebSocket closes with a non-normal code; value is the close code integer.
    var onGatewayClose: ((Int) async -> Void)?

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

    private func ensureGatewayCallbacksConfigured() async {
        guard !gatewayCallbacksConfigured else { return }

        await gatewayConnection.setOnPayload { [weak self] payload in
            guard let self else { return }
            await self.handleInboundGatewayPayload(payload)
        }
        await gatewayConnection.setOnConnectionState { [weak self] state in
            await self?.onConnectionState?(state)
        }
        await gatewayConnection.setOnHeartbeatLatency { [weak self] latencyMs in
            await self?.onHeartbeatLatency?(latencyMs)
        }
        await gatewayConnection.setOnGatewayClose { [weak self] code in
            await self?.onGatewayClose?(code)
        }
        gatewayCallbacksConfigured = true
    }

    private func handleInboundGatewayPayload(_ payload: GatewayPayload) async {
        // Run independent seed operations in parallel for faster gateway event processing.
        // These operate on disjoint state, so no synchronization is needed.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.seedChannelTypesIfNeeded(payload) }
            group.addTask { await self.seedGuildNameIfNeeded(payload) }
            group.addTask { await self.seedVoiceChannelsIfNeeded(payload) }
            group.addTask { await self.seedVoiceStateIfNeeded(payload) }
        }
        await processRuleActionsIfNeeded(payload)
        await onPayload?(payload)
    }

    func setRuleEngine(_ engine: RuleEngine) {
        ruleEngine = engine
    }

    func setHistoryProvider(_ provider: @escaping HistoryProvider) {
        historyProvider = provider
    }

    func setActiveVoiceJoinDateProvider(_ provider: @escaping ActiveVoiceJoinDateProvider) {
        activeVoiceJoinDateProvider = provider
    }

    /// Checks if a message was already handled by rule actions (prevents duplicate AI replies)
    func wasMessageHandledByRules(messageId: String) async -> Bool {
        await ruleExecutionService.wasMessageHandledByRules(messageId: messageId)
    }

    func connect(token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            discordLogger.warning("Gateway connect called with empty token — aborting")
            await onConnectionState?(.stopped)
            return
        }
        discordLogger.info("Gateway connect initiated")
        botToken = normalizedToken
        await ensureGatewayCallbacksConfigured()
        await gatewayConnection.connect(token: normalizedToken)
    }

    func disconnect() async {
        discordLogger.info("Gateway disconnect requested (user-initiated)")
        await ensureGatewayCallbacksConfigured()
        await gatewayConnection.disconnect()
        botToken = nil
        voiceRuleStateStore.clearAll()
        voiceChannelNamesByGuild.removeAll()
        channelTypeById.removeAll()
    }

    // MARK: - Onboarding: Token Validation & Invite Generation

    /// Categorized token validation errors with human-readable message and remediation hint.
    enum TokenValidationError {
        case invalidToken
        case rateLimited
        case networkFailure
        case serverError(Int)

        var message: String {
            switch self {
            case .invalidToken:   return "Token is invalid or revoked."
            case .rateLimited:    return "Rate limited by Discord. Wait a moment and try again."
            case .networkFailure: return "Network request failed. Check your internet connection."
            case .serverError(let code): return "Discord server error (HTTP \(code)). Try again shortly."
            }
        }

        var remediation: String {
            switch self {
            case .invalidToken:   return "Use Clear API Key in Settings to enter a new token."
            case .rateLimited:    return "Reduce request frequency; Discord will reset the limit automatically."
            case .networkFailure: return "Check your connection, then try connecting again."
            case .serverError:    return "Discord may be experiencing an outage. Check status.discord.com."
            }
        }
    }

    /// Rich result from token validation including bot identity fields.
    struct TokenValidationResult {
        let isValid: Bool
        let userId: String?
        let username: String?
        let discriminator: String?
        let avatarURL: URL?
        let errorCategory: TokenValidationError?
        let errorMessage: String

        static func failure(_ category: TokenValidationError) -> TokenValidationResult {
            TokenValidationResult(
                isValid: false,
                userId: nil,
                username: nil,
                discriminator: nil,
                avatarURL: nil,
                errorCategory: category,
                errorMessage: category.message
            )
        }

    }

    /// Generates a Discord OAuth2 bot invite URL using URLComponents (no manual string concatenation).
    /// - Parameters:
    ///   - clientId: The bot's application ID.
    ///   - includeSlashCommands: When true, appends `applications.commands` scope.
    /// - Returns: The invite URL string, or nil if clientId is empty or URL construction fails.
    func generateInviteURL(clientId: String, includeSlashCommands: Bool) -> String? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "discord.com"
        components.path = "/oauth2/authorize"

        var scope = "bot"
        if includeSlashCommands { scope += " applications.commands" }

        // Manually construct the encoded query to ensure space -> + for scope.
        let encodedScope = scope.replacingOccurrences(of: " ", with: "+")
        let query = "client_id=\(trimmed)&permissions=274877991936&scope=\(encodedScope)"
        components.percentEncodedQuery = query

        return components.url?.absoluteString
    }

    func sendMessage(channelId: String, content: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.sendMessage(channelId: channelId, content: content, token: token)
    }

    func registerGlobalApplicationCommands(
        applicationID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        try await interactionRESTClient.registerGlobalApplicationCommands(
            applicationID: applicationID,
            commands: commands,
            token: token
        )
    }

    func registerGuildApplicationCommands(
        applicationID: String,
        guildID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        try await interactionRESTClient.registerGuildApplicationCommands(
            applicationID: applicationID,
            guildID: guildID,
            commands: commands,
            token: token
        )
    }

    func respondToInteraction(
        interactionID: String,
        interactionToken: String,
        payload: [String: Any]
    ) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: respondToInteraction blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await interactionRESTClient.respondToInteraction(
            interactionID: interactionID,
            interactionToken: interactionToken,
            payload: payload
        )
    }

    func editOriginalInteractionResponse(
        applicationID: String,
        interactionToken: String,
        content: String
    ) async throws {
        try await editOriginalInteractionResponse(
            applicationID: applicationID,
            interactionToken: interactionToken,
            payload: ["content": content]
        )
    }

    func editOriginalInteractionResponse(
        applicationID: String,
        interactionToken: String,
        payload: [String: Any]
    ) async throws {
        try await interactionRESTClient.editOriginalInteractionResponse(
            applicationID: applicationID,
            interactionToken: interactionToken,
            payload: payload
        )
    }

    func sendMessageReturningID(channelId: String, content: String, token: String) async throws -> String {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        return try await messageRESTClient.sendMessageReturningID(channelId: channelId, content: content, token: token)
    }

    @discardableResult
    func sendMessage(channelId: String, payload: [String: Any], token: String) async throws -> (statusCode: Int, responseBody: String) {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        return try await messageRESTClient.sendMessage(channelId: channelId, payload: payload, token: token)
    }

    func editMessage(channelId: String, messageId: String, content: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: editMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.editMessage(channelId: channelId, messageId: messageId, content: content, token: token)
    }

    func editMessage(channelId: String, messageId: String, payload: [String: Any], token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: editMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.editMessage(channelId: channelId, messageId: messageId, payload: payload, token: token)
    }

    func fetchChannel(channelId: String, token: String) async throws -> [String: DiscordJSON] {
        try await messageRESTClient.fetchChannel(channelId: channelId, token: token)
    }

    func addReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: addReaction blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: removeOwnReaction blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.removeOwnReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
    }

    func pinMessage(channelId: String, messageId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: pinMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.pinMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func unpinMessage(channelId: String, messageId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: unpinMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.unpinMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String, token: String) async throws -> String {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: createThreadFromMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        return try await messageRESTClient.createThreadFromMessage(channelId: channelId, messageId: messageId, name: name, token: token)
    }

    @discardableResult
    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendMessageWithImage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        return try await messageRESTClient.sendMessageWithImage(
            channelId: channelId,
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    func editMessageWithImage(
        channelId: String,
        messageId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: editMessageWithImage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.editMessageWithImage(
            channelId: channelId,
            messageId: messageId,
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    /// Sends a typing indicator to the given channel. Fire-and-forget; errors are silently discarded.
    func triggerTyping(channelId: String, token: String) async {
        await messageRESTClient.triggerTyping(channelId: channelId, token: token)
    }

    private func seedGuildNameIfNeeded(_ payload: GatewayPayload) async {
        guard payload.op == 0, payload.t == "GUILD_CREATE" else { return }
        guard case let .object(guildMap)? = payload.d,
              case let .string(guildId)? = guildMap["id"],
              case let .string(guildName)? = guildMap["name"]
        else { return }
        guildNamesById[guildId] = guildName
    }

    private func seedVoiceChannelsIfNeeded(_ payload: GatewayPayload) async {
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

    private func seedChannelTypesIfNeeded(_ payload: GatewayPayload) async {
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

    private func seedVoiceStateIfNeeded(_ payload: GatewayPayload) async {
        guard payload.op == 0, payload.t == "GUILD_CREATE" else { return }
        guard case let .object(guildMap)? = payload.d,
              case let .string(guildId)? = guildMap["id"],
              case let .array(voiceStates)? = guildMap["voice_states"]
        else { return }

        var members: [VoiceRulePresenceSeed] = []
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            let joinedAt = await activeVoiceJoinDateProvider?(guildId, userId)
            members.append(VoiceRulePresenceSeed(userID: userId, channelID: channelId, joinedAt: joinedAt))
        }

        voiceRuleStateStore.seedSnapshot(guildID: guildId, members: members, seededAt: Date())
    }

    private func processRuleActionsIfNeeded(_ payload: GatewayPayload) async {
        guard payload.op == 0 else { return }

        // Prevent standby nodes from executing rule actions
        guard outputAllowed else { return }

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
        let ruleActions = await MainActor.run {
            engine?.evaluateRules(event: event).map { (isDM: event.isDirectMessage, actions: $0.processedActions) } ?? []
        }

        for ruleResult in ruleActions {
            _ = await executeRulePipeline(actions: ruleResult.actions, for: event, isDirectMessage: ruleResult.isDM)
        }
    }

    func executeRulePipeline(
        actions: [Action],
        for event: VoiceRuleEvent,
        isDirectMessage: Bool
    ) async -> PipelineContext {
        await ruleExecutionService.executeRulePipeline(
            actions: actions,
            for: event,
            isDirectMessage: isDirectMessage,
            token: botToken
        )
    }

    private func parseVoiceRuleEvent(from raw: DiscordJSON?) -> VoiceRuleEvent? {
        guard case let .object(map)? = raw,
              case let .string(userId)? = map["user_id"],
              case let .string(guildId)? = map["guild_id"]
        else { return nil }

        let now = Date()
        let newChannel: String?
        if case let .string(cid)? = map["channel_id"] { newChannel = cid } else { newChannel = nil }

        let username = parseUsername(from: map, userId: userId)
        let transition = voiceRuleStateStore.applyEvent(guildID: guildId, userID: userId, channelID: newChannel, at: now)

        switch transition {
        case .ignored:
            return nil
        case .joined(let channelID):
            return VoiceRuleEvent(
                kind: .join,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: channelID,
                fromChannelId: nil,
                toChannelId: channelID,
                durationSeconds: nil,
                messageContent: nil,
                messageId: nil,
                mediaFileName: nil,
                mediaRelativePath: nil,
                mediaSourceName: nil,
                mediaNodeName: nil,
                triggerMessageId: nil,
                triggerChannelId: nil,
                triggerGuildId: guildId,
                triggerUserId: userId,
                isDirectMessage: false,
                authorIsBot: nil,
                joinedAt: nil
            )
        case .moved(let fromChannelID, let toChannelID, let durationSeconds):
            return VoiceRuleEvent(
                kind: .move,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: toChannelID,
                fromChannelId: fromChannelID,
                toChannelId: toChannelID,
                durationSeconds: durationSeconds,
                messageContent: nil,
                messageId: nil,
                mediaFileName: nil,
                mediaRelativePath: nil,
                mediaSourceName: nil,
                mediaNodeName: nil,
                triggerMessageId: nil,
                triggerChannelId: nil,
                triggerGuildId: guildId,
                triggerUserId: userId,
                isDirectMessage: false,
                authorIsBot: nil,
                joinedAt: nil
            )
        case .left(let channelID, let durationSeconds):
            return VoiceRuleEvent(
                kind: .leave,
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: channelID,
                fromChannelId: channelID,
                toChannelId: nil,
                durationSeconds: durationSeconds,
                messageContent: nil,
                messageId: nil,
                mediaFileName: nil,
                mediaRelativePath: nil,
                mediaSourceName: nil,
                mediaNodeName: nil,
                triggerMessageId: nil,
                triggerChannelId: nil,
                triggerGuildId: guildId,
                triggerUserId: userId,
                isDirectMessage: false,
                authorIsBot: nil,
                joinedAt: nil
            )
        }
    }

    private func parseMessageRuleEvent(from raw: DiscordJSON?) -> VoiceRuleEvent? {
        guard case let .object(map)? = raw,
              case let .string(messageId)? = map["id"],
              case let .object(author)? = map["author"],
              case let .string(userId)? = author["id"],
              case let .string(username)? = author["username"],
              case let .string(content)? = map["content"],
              case let .string(channelId)? = map["channel_id"]
        else { return nil }

        let authorIsBot: Bool = {
            if case let .bool(isBot)? = author["bot"] { return isBot }
            return false
        }()

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
            messageId: messageId,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: messageId,
            triggerChannelId: channelId,
            triggerGuildId: guildId,
            triggerUserId: userId,
            isDirectMessage: isDirectMessage,
            authorIsBot: authorIsBot,
            joinedAt: nil
        )
    }

    private func resolvedMessageChannelType(from map: [String: DiscordJSON], channelId: String) -> Int? {
        if case let .int(type)? = map["channel_type"] {
            return type
        }
        return channelTypeById[channelId]
    }

    func sendDM(userId: String, content: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendDM blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        guard let token = botToken else { return }

        let channelId = try await messageRESTClient.createDirectMessageChannel(userId: userId, token: token)
        try await sendMessage(channelId: channelId, content: content, token: token)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: deleteMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.deleteMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func addRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: addRole blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
    }

    func removeRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: removeRole blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.removeRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
    }

    func timeoutMember(guildId: String, userId: String, durationSeconds: Int, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: timeoutMember blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.timeoutMember(guildId: guildId, userId: userId, durationSeconds: durationSeconds, token: token)
    }

    func kickMember(guildId: String, userId: String, reason: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: kickMember blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.kickMember(guildId: guildId, userId: userId, reason: reason, token: token)
    }

    func moveMember(guildId: String, userId: String, channelId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: moveMember blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.moveMember(guildId: guildId, userId: userId, channelId: channelId, token: token)
    }

    func createChannel(guildId: String, name: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: createChannel blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.createChannel(guildId: guildId, name: name, token: token)
    }

    func sendWebhook(url: String, content: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendWebhook blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await interactionRESTClient.sendWebhook(url: url, content: content)
    }

    private func parseUsername(from map: [String: DiscordJSON], userId: String) -> String {
        if case let .object(member)? = map["member"],
           case let .object(user)? = member["user"],
           case let .string(username)? = user["username"] {
            return username
        }
        return "User \(userId.suffix(4))"
    }

    private func resolvedChannelName(guildId: String, channelId: String) -> String {
        if let name = voiceChannelNamesByGuild[guildId]?[channelId], !name.isEmpty {
            return name
        }
        return "Channel \(channelId.suffix(5))"
    }

    private func updatePresence(text: String) async {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: updatePresence blocked — outputAllowed is false (node is not Primary).")
            return
        }
        await ensureGatewayCallbacksConfigured()
        await gatewayConnection.sendPresence(text: text)
    }
}
