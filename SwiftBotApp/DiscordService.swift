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
    private var socket: URLSessionWebSocketTask?
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
    private var ruleEngine: RuleEngine?
    private var voiceRuleStateStore = VoiceRuleStateStore()
    private var voiceChannelNamesByGuild: [String: [String: String]] = [:]
    private var channelTypeById: [String: Int] = [:]
    private var guildNamesById: [String: String] = [:]
    private var guildOwnerIdByGuild: [String: String] = [:]
    private lazy var aiService = DiscordAIService(session: session)
    private lazy var guildRESTClient = DiscordGuildRESTClient(session: session, restBase: restBase)
    private lazy var identityRESTClient = DiscordIdentityRESTClient(session: session, identitySession: identitySession, restBase: restBase)
    private lazy var interactionRESTClient = DiscordInteractionRESTClient(session: session, restBase: restBase)
    private lazy var messageRESTClient = DiscordMessageRESTClient(session: session, restBase: restBase)
    private lazy var ruleExecutionService = RuleExecutionService(
        aiService: aiService,
        dependencies: .init(
            sendMessage: { [unowned self] channelId, content, token in
                try await self.sendMessage(channelId: channelId, content: content, token: token)
            },
            sendPayloadMessage: { [unowned self] channelId, payload, token in
                _ = try await self.sendMessage(channelId: channelId, payload: payload, token: token)
            },
            sendDM: { [unowned self] userId, content in
                try await self.sendDM(userId: userId, content: content)
            },
            addReaction: { [unowned self] channelId, messageId, emoji, token in
                try await self.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
            },
            deleteMessage: { [unowned self] channelId, messageId, token in
                try await self.deleteMessage(channelId: channelId, messageId: messageId, token: token)
            },
            addRole: { [unowned self] guildId, userId, roleId, token in
                try await self.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
            },
            removeRole: { [unowned self] guildId, userId, roleId, token in
                try await self.removeRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
            },
            timeoutMember: { [unowned self] guildId, userId, durationSeconds, token in
                try await self.timeoutMember(guildId: guildId, userId: userId, durationSeconds: durationSeconds, token: token)
            },
            kickMember: { [unowned self] guildId, userId, reason, token in
                try await self.kickMember(guildId: guildId, userId: userId, reason: reason, token: token)
            },
            moveMember: { [unowned self] guildId, userId, channelId, token in
                try await self.moveMember(guildId: guildId, userId: userId, channelId: channelId, token: token)
            },
            createChannel: { [unowned self] guildId, name, token in
                try await self.createChannel(guildId: guildId, name: name, token: token)
            },
            sendWebhook: { [unowned self] url, content in
                try await self.sendWebhook(url: url, content: content)
            },
            updatePresence: { [unowned self] text in
                await self.updatePresence(text: text)
            },
            resolveChannelName: { [unowned self] guildId, channelId in
                await self.resolvedChannelName(guildId: guildId, channelId: channelId)
            },
            resolveGuildName: { [unowned self] guildId in
                await self.guildNamesById[guildId]
            },
            debugLog: { [discordLogger] message in
                discordLogger.debug("\(message, privacy: .public)")
            }
        )
    )
    private lazy var wikiLookupService = WikiLookupService(session: session)

    typealias HistoryProvider = @Sendable (MemoryScope) async -> [Message]
    private var historyProvider: HistoryProvider?

    private let session = URLSession(configuration: .default)

    /// Dedicated session for Discord identity probes (/users/@me, /oauth2/applications/@me).
    /// Short timeout, no caching — token never cached locally.
    private static let identitySessionConfig: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        return c
    }()
    private let identitySession = URLSession(configuration: DiscordService.identitySessionConfig)

    private struct DiscordMessageEnvelope: Decodable {
        let id: String
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

    func setRuleEngine(_ engine: RuleEngine) {
        ruleEngine = engine
    }

    func setHistoryProvider(_ provider: @escaping HistoryProvider) {
        historyProvider = provider
    }

    func configureLocalAIDMReplies(
        enabled: Bool,
        provider: AIProvider,
        preferredProvider: AIProviderPreference,
        endpoint: String,
        model: String,
        openAIAPIKey: String,
        openAIModel: String,
        systemPrompt: String
    ) async {
        await aiService.configureLocalAIDMReplies(
            enabled: enabled,
            provider: provider,
            preferredProvider: preferredProvider,
            endpoint: endpoint,
            model: model,
            openAIAPIKey: openAIAPIKey,
            openAIModel: openAIModel,
            systemPrompt: systemPrompt
        )
    }

    /// Checks if a message was already handled by rule actions (prevents duplicate AI replies)
    func wasMessageHandledByRules(messageId: String) -> Bool {
        ruleExecutionService.wasMessageHandledByRules(messageId: messageId)
    }

    /// Marks a message as handled by rule actions
    func markMessageHandledByRules(messageId: String) {
        ruleExecutionService.markMessageHandledByRules(messageId: messageId)
    }

    func detectOllamaModel(baseURL: String) async -> String? {
        await aiService.detectOllamaModel(baseURL: baseURL)
    }

    func currentAIStatus(ollamaBaseURL: String, ollamaModelHint: String?, openAIAPIKey: String) async -> (appleOnline: Bool, ollamaOnline: Bool, ollamaModel: String?, openAIOnline: Bool) {
        await aiService.currentAIStatus(
            ollamaBaseURL: ollamaBaseURL,
            ollamaModelHint: ollamaModelHint,
            openAIAPIKey: openAIAPIKey
        )
    }

    func generateSmartDMReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
    ) async -> String? {
        await aiService.generateSmartDMReply(
            messages: messages,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
    }

    /// Generates an AI-rewritten help response. Not gated by `localAIDMReplyEnabled` — the
    /// caller controls whether AI help is attempted via `HelpSettings.mode`.
    /// Tries primary → secondary provider; returns nil if both are unavailable (caller falls
    /// back to deterministic catalog text).
    func generateHelpReply(messages: [Message], systemPrompt: String) async -> String? {
        await aiService.generateHelpReply(messages: messages, systemPrompt: systemPrompt)
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        await wikiLookupService.lookupWiki(query: query, source: source)
    }

    func lookupFinalsWiki(query: String) async -> FinalsWikiLookupResult? {
        await wikiLookupService.lookupFinalsWiki(query: query)
    }

    func connect(token: String) async {
        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else {
            discordLogger.warning("Gateway connect called with empty token — aborting")
            await onConnectionState?(.stopped)
            return
        }
        discordLogger.info("Gateway connect initiated")
        userInitiatedDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempts = 0
        botToken = normalizedToken
        await openGatewayConnection(token: normalizedToken, isReconnect: false)
    }

    func disconnect() {
        discordLogger.info("Gateway disconnect requested (user-initiated)")
        userInitiatedDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        heartbeatTask?.cancel()
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        botToken = nil
        voiceRuleStateStore.clearAll()
        voiceChannelNamesByGuild.removeAll()
        channelTypeById.removeAll()
        Task { await onConnectionState?(.stopped) }
    }

    private func receiveLoop(token: String) async {
        while !Task.isCancelled, let socket {
            do {
                let message = try await socket.receive()
                if case .string(let text) = message,
                   let payload = try? JSONDecoder().decode(GatewayPayload.self, from: Data(text.utf8)) {
                    sequence = payload.s ?? sequence
                    await handleGatewayPayload(payload, token: token)
                    seedChannelTypesIfNeeded(payload)
                    seedGuildNameIfNeeded(payload)
                    seedVoiceChannelsIfNeeded(payload)
                    seedVoiceStateIfNeeded(payload)
                    await processRuleActionsIfNeeded(payload)
                    await onPayload?(payload)
                }
            } catch {
                // Capture Discord gateway close code (4004, 4014, etc.) before reconnect.
                let closeRawValue = socket.closeCode.rawValue
                if closeRawValue != 1000, closeRawValue > 0 {
                    await onGatewayClose?(closeRawValue)
                }
                await scheduleReconnect(
                    reason: "Gateway receive failed: \(error.localizedDescription)"
                )
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
                let latencyMs = max(1, Int((Date().timeIntervalSince(sent) * 1000).rounded()))
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

        let task = session.webSocketTask(with: gatewayURL)
        socket = task
        task.resume()
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
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
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
            TokenValidationResult(isValid: false, userId: nil, username: nil,
                                  discriminator: nil, avatarURL: nil,
                                  errorCategory: category, errorMessage: category.message)
        }
    }

    /// Validates a bot token against Discord's /users/@me endpoint.
    /// Returns a rich result including bot identity on success.
    /// Token is never logged; OSLog uses privacy: .private throughout.
    func validateBotTokenRich(_ token: String) async -> TokenValidationResult {
        let result = await identityRESTClient.validateBotTokenRich(token)
        if result.isValid {
            discordLogger.info("Token validation succeeded for user \(result.userId ?? "unknown", privacy: .private)")
            return result
        }

        switch result.errorCategory {
        case .invalidToken:
            discordLogger.warning("Token validation: 401 unauthorized")
        case .rateLimited:
            discordLogger.warning("Token validation: 429 rate limited")
        case .serverError(let statusCode):
            discordLogger.warning("Token validation: unexpected HTTP \(statusCode, privacy: .public)")
        case .networkFailure:
            discordLogger.warning("Token validation: network failure")
        case nil:
            discordLogger.warning("Token validation failed without an error category")
        }

        return result
    }

    /// Resolves the bot's application client_id via /oauth2/applications/@me.
    /// Falls back to the userId from token validation if the endpoint is unavailable.
    func resolveClientID(token: String, fallbackUserID: String?) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackUserID }

        if let appID = await identityRESTClient.resolveClientID(token: trimmed) {
            discordLogger.info("Resolved client_id from /oauth2/applications/@me")
            return appID
        }

        // Fallback: use the user ID from /users/@me (same value for bots).
        if let fallback = fallbackUserID {
            discordLogger.info("Using userId as client_id fallback")
            return fallback
        }
        return nil
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

    /// Runs a REST health probe against GET /users/@me.
    /// Returns: ok flag, HTTP status code, and the X-RateLimit-Remaining header value.
    func restHealthProbe(token: String) async -> (isOK: Bool, httpStatus: Int?, rateLimitRemaining: Int?) {
        await identityRESTClient.restHealthProbe(token: token)
    }

    func validateBotToken(_ token: String) async -> (isValid: Bool, message: String) {
        await identityRESTClient.validateBotToken(token)
    }

    /// Returns the guild owner_id for permission-sensitive commands.
    /// Uses an in-memory cache and falls back to GET /guilds/{guild.id} when needed.
    func guildOwnerID(guildID: String) async -> String? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty else { return nil }

        if let cached = guildOwnerIdByGuild[trimmedGuildID], !cached.isEmpty {
            return cached
        }

        guard let token = botToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        if let ownerID = await identityRESTClient.fetchGuildOwnerID(guildID: trimmedGuildID, token: token) {
            guildOwnerIdByGuild[trimmedGuildID] = ownerID
            return ownerID
        }
        return nil
    }

    /// Returns role IDs for a guild member using GET /guilds/{guild.id}/members/{user.id}.
    /// This is used as a fallback for permission checks when gateway payloads do not include `member`.
    func guildMemberRoleIDs(guildID: String, userID: String) async -> [String]? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedUserID.isEmpty else { return nil }

        guard let token = botToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        return await identityRESTClient.fetchGuildMemberRoleIDs(guildID: trimmedGuildID, userID: trimmedUserID, token: token)
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
        heartbeatSentAt = Date()
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

        // Intents:
        // - guilds (1), guild members (2), guild voice states (128), guild presences (256),
        // - guild messages (512), guild message reactions (1024), guild message typing (2048),
        // - direct messages (4096), direct message reactions (8192), message content (32768)
        let intents = 49_027

        let identify: [String: Any] = [
            "token": token,
            "intents": intents,
            "properties": ["$os": "macOS", "$browser": "SwiftBot", "$device": "SwiftBot"],
            "presence": presence
        ]
        await sendRaw(["op": 2, "d": identify])
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

    func fetchFinalsMetaFromSkycoach() async -> String? {
        await wikiLookupService.fetchFinalsMetaFromSkycoach()
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
        try await messageRESTClient.editMessage(channelId: channelId, messageId: messageId, content: content, token: token)
    }

    func fetchMessage(channelId: String, messageId: String, token: String) async throws -> [String: DiscordJSON] {
        try await messageRESTClient.fetchMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func fetchRecentMessages(channelId: String, limit: Int, token: String) async throws -> [[String: DiscordJSON]] {
        try await messageRESTClient.fetchRecentMessages(channelId: channelId, limit: limit, token: token)
    }

    func addReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        try await messageRESTClient.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        try await messageRESTClient.removeOwnReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: token)
    }

    func pinMessage(channelId: String, messageId: String, token: String) async throws {
        try await messageRESTClient.pinMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func unpinMessage(channelId: String, messageId: String, token: String) async throws {
        try await messageRESTClient.unpinMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String, token: String) async throws {
        try await messageRESTClient.createThreadFromMessage(channelId: channelId, messageId: messageId, name: name, token: token)
    }

    @discardableResult
    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        try await messageRESTClient.sendMessageWithImage(
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
        try await messageRESTClient.editMessageWithImage(
            channelId: channelId,
            messageId: messageId,
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    func generateOpenAIImage(prompt: String, apiKey: String, model: String) async -> Data? {
        await aiService.generateOpenAIImage(prompt: prompt, apiKey: apiKey, model: model)
    }

    /// Sends a typing indicator to the given channel. Fire-and-forget; errors are silently discarded.
    func triggerTyping(channelId: String, token: String) async {
        await messageRESTClient.triggerTyping(channelId: channelId, token: token)
    }

    private func seedGuildNameIfNeeded(_ payload: GatewayPayload) {
        guard payload.op == 0, payload.t == "GUILD_CREATE" else { return }
        guard case let .object(guildMap)? = payload.d,
              case let .string(guildId)? = guildMap["id"],
              case let .string(guildName)? = guildMap["name"]
        else { return }
        guildNamesById[guildId] = guildName
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

        var members: [VoiceRulePresenceSeed] = []
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            members.append(VoiceRulePresenceSeed(userID: userId, channelID: channelId))
        }

        voiceRuleStateStore.seedSnapshot(guildID: guildId, members: members, seededAt: Date())
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
        guard let token = botToken else { return }

        let channelId = try await messageRESTClient.createDirectMessageChannel(userId: userId, token: token)
        try await sendMessage(channelId: channelId, content: content, token: token)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        try await messageRESTClient.deleteMessage(channelId: channelId, messageId: messageId, token: token)
    }

    func addRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        try await guildRESTClient.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
    }

    func removeRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        try await guildRESTClient.removeRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
    }

    func timeoutMember(guildId: String, userId: String, durationSeconds: Int, token: String) async throws {
        try await guildRESTClient.timeoutMember(guildId: guildId, userId: userId, durationSeconds: durationSeconds, token: token)
    }

    func kickMember(guildId: String, userId: String, reason: String, token: String) async throws {
        try await guildRESTClient.kickMember(guildId: guildId, userId: userId, reason: reason, token: token)
    }

    func moveMember(guildId: String, userId: String, channelId: String, token: String) async throws {
        try await guildRESTClient.moveMember(guildId: guildId, userId: userId, channelId: channelId, token: token)
    }

    func createChannel(guildId: String, name: String, token: String) async throws {
        try await guildRESTClient.createChannel(guildId: guildId, name: name, token: token)
    }

    func sendWebhook(url: String, content: String) async throws {
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

    func execute(action: Action, for event: VoiceRuleEvent, context: inout PipelineContext) async {
        await ruleExecutionService.execute(action: action, for: event, context: &context, token: botToken)
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
