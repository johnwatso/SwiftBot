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

    /// Channel/role display names (id → name), refreshed from `DiscordCache` so
    /// `humanizeContent` can resolve `<#id>` / `<@&id>` mentions to real names.
    private var channelNamesByID: [String: String] = [:]
    private var roleNamesByID: [String: String] = [:]

    func setNameCaches(channels: [String: String], roles: [String: String]) {
        channelNamesByID = channels
        roleNamesByID = roles
    }

    #if DEBUG
    func setBotTokenForTesting(_ token: String) {
        botToken = token
    }
    #endif

    private let discordLogger = Logger(subsystem: "com.swiftbot", category: "discord")

    private let gatewayURL = URL(string: "wss://gateway.discord.gg/?v=10&encoding=json")!
    private let restBase = URL(string: "https://discord.com/api/v10")!
    private let session: URLSession
    private let identitySession: URLSession
    private var botToken: String?
    private var automationService: AutomationService?
    private var automationSnapshotProvider: (@Sendable () async -> [Automations.Rule])?
    private var voiceRuleStateStore = VoiceRuleStateStore()
    private var voiceChannelNamesByGuild: [String: [String: String]] = [:]
    private var channelTypeById: [String: Int] = [:]
    private var guildNamesById: [String: String] = [:]
    private let aiService: DiscordAIService
    private lazy var guildRESTClient = DiscordGuildRESTClient(session: session, restBase: restBase)
    private lazy var identityRESTClient = DiscordIdentityRESTClient(session: session, identitySession: identitySession, restBase: restBase)
    private lazy var interactionRESTClient = DiscordInteractionRESTClient(session: session, restBase: restBase)
    private lazy var messageRESTClient = DiscordMessageRESTClient(session: session, restBase: restBase)
    private let wikiLookupService: WikiLookupService
    private lazy var gatewayConnection = DiscordGatewayConnection(session: session, gatewayURL: gatewayURL)
    private var gatewayCallbacksConfigured = false

    /// Send VOICE_STATE_UPDATE on the main gateway to join (or leave, if
    /// `channelID == nil`) a voice channel. Used by the Voice tab to drive
    /// `VoicePlaybackService`.
    func sendVoiceStateUpdate(guildID: String, channelID: String?) async -> Bool {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Voice state update blocked — outputAllowed is false.")
            return false
        }
        return await gatewayConnection.sendVoiceStateUpdate(guildID: guildID, channelID: channelID)
    }

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

    var onPayload: (@Sendable (GatewayPayload) async -> Void)?
    var onConnectionState: (@Sendable (BotStatus) async -> Void)?
    /// Called each time a heartbeat ACK (op 11) is received; value is round-trip ms.
    var onHeartbeatLatency: (@Sendable (Int) async -> Void)?
    /// Called when the WebSocket closes with a non-normal code; value is the close code integer.
    var onGatewayClose: (@Sendable (Int) async -> Void)?

    func setOnPayload(_ handler: @escaping @Sendable (GatewayPayload) async -> Void) {
        onPayload = handler
    }

    func setOnConnectionState(_ handler: @escaping @Sendable (BotStatus) async -> Void) {
        onConnectionState = handler
    }

    func setOnHeartbeatLatency(_ handler: @escaping @Sendable (Int) async -> Void) {
        onHeartbeatLatency = handler
    }

    func setOnGatewayClose(_ handler: @escaping @Sendable (Int) async -> Void) {
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

    func setAutomationService(_ engine: AutomationService, store: AutomationStore) {
        automationService = engine
        automationSnapshotProvider = { @Sendable in await store.snapshot() }
    }

    func setHistoryProvider(_ provider: @escaping HistoryProvider) {
        historyProvider = provider
    }

    func setActiveVoiceJoinDateProvider(_ provider: @escaping ActiveVoiceJoinDateProvider) {
        activeVoiceJoinDateProvider = provider
    }

    /// Checks if a message was already handled by rule actions (prevents duplicate AI replies)
    func wasMessageHandledByRules(messageId: String) async -> Bool {
        guard let engine = automationService else { return false }
        return await engine.wasMessageHandledByRules(messageId: messageId)
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
    func generateInviteURL(clientId: String, includeSlashCommands: Bool, codeGrantRedirectURI: String? = nil) -> String? {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Plain bot-install URL. Do NOT append response_type=code/redirect_uri
        // even if a redirect is configured: combining `scope=bot` with
        // `response_type=code` flips Discord into a user-OAuth code grant flow
        // and the bot never actually gets installed. The "Requires OAuth2 Code
        // Grant" toggle this used to work around is deprecated.
        _ = codeGrantRedirectURI

        var components = URLComponents()
        components.scheme = "https"
        components.host = "discord.com"
        components.path = "/oauth2/authorize"

        var scope = "bot"
        if includeSlashCommands { scope += " applications.commands" }
        let encodedScope = scope.replacingOccurrences(of: " ", with: "+")

        // Pull the permission bitfield from DiscordPermissionCatalog so this
        // invite path stays in sync with the Bot Permissions sheet. The
        // previous hardcoded value (274877991936) was stale and silently
        // omitted Manage Messages, which made every "Open Invite Link" install
        // the bot without the perm it needs for destructive Sweep actions.
        let permissions = DiscordPermissionCatalog.desiredBitfield
        let query = "client_id=\(trimmed)&permissions=\(permissions)&scope=\(encodedScope)"
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
        nonisolated(unsafe) let safeCommands = commands
        try await interactionRESTClient.registerGlobalApplicationCommands(
            applicationID: applicationID,
            commands: safeCommands,
            token: token
        )
    }

    func registerGuildApplicationCommands(
        applicationID: String,
        guildID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        nonisolated(unsafe) let safeCommands = commands
        try await interactionRESTClient.registerGuildApplicationCommands(
            applicationID: applicationID,
            guildID: guildID,
            commands: safeCommands,
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
        nonisolated(unsafe) let safePayload = payload
        try await interactionRESTClient.respondToInteraction(
            interactionID: interactionID,
            interactionToken: interactionToken,
            payload: safePayload
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
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: editOriginalInteractionResponse blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        nonisolated(unsafe) let safePayload = payload
        try await interactionRESTClient.editOriginalInteractionResponse(
            applicationID: applicationID,
            interactionToken: interactionToken,
            payload: safePayload
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
        let payloadData = try Self.encodeDiscordPayload(payload)
        return try await messageRESTClient.sendMessage(channelId: channelId, payloadData: payloadData, token: token)
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
        let payloadData = try Self.encodeDiscordPayload(payload)
        try await messageRESTClient.editMessage(channelId: channelId, messageId: messageId, payloadData: payloadData, token: token)
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

    @discardableResult
    func sendMessageWithEmbedImage(
        channelId: String,
        payload: [String: Any],
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendMessageWithEmbedImage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        nonisolated(unsafe) let safePayload = payload
        return try await messageRESTClient.sendMessageWithEmbedImage(
            channelId: channelId,
            payload: safePayload,
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

        // VOICE_STATE_UPDATE rules stay here because parsing requires a
        // stateful diff against `voiceRuleStateStore` — the rule event encodes
        // join/move/leave transitions that can't be recovered from the raw
        // payload alone. MESSAGE_CREATE rules moved to
        // `processMessageRuleEvent(event:channelType:)`, called from AppModel
        // with the already-parsed `GatewayMessageCreateEvent`.
        guard payload.t == "VOICE_STATE_UPDATE",
              let event = parseVoiceRuleEvent(from: payload.d) else { return }

        await fireRules(for: event)
    }

    /// Evaluate and execute MESSAGE_CREATE rules against an already-parsed
    /// gateway event. Callers (AppModel) supply the resolved channel type so
    /// rules see the same `isDirectMessage` value as the surrounding handler.
    /// Lifted out of the gateway re-parse path to keep MESSAGE_CREATE on a
    /// single JSON pass.
    func processMessageRuleEvent(
        event: GatewayMessageCreateEvent,
        channelType: Int?
    ) async {
        guard outputAllowed else { return }
        let ruleEvent = makeMessageRuleEvent(from: event, channelType: channelType)
        await fireRules(for: ruleEvent)
    }

    private func fireRules(for event: SwiftBotEvent) async {
        guard let engine = automationService,
              let provider = automationSnapshotProvider else { return }

        let snapshot = await provider()
        let matches = engine.evaluate(event: event, in: snapshot)
        for rule in matches {
            await engine.execute(rule: rule, event: event, token: botToken)
        }
    }

    private func makeMessageRuleEvent(
        from event: GatewayMessageCreateEvent,
        channelType: Int?
    ) -> SwiftBotEvent {
        let guildId = event.guildID ?? ""
        let authorIsBot: Bool = {
            if case let .bool(isBot)? = event.author["bot"] { return isBot }
            return false
        }()
        let isDirectMessage = (channelType == 1 || channelType == 3)

        return SwiftBotEvent.message(
            SwiftBotEvent.MessagePayload(
                guildId: guildId,
                userId: event.userID,
                username: event.username,
                roleIds: event.memberRoleIDs,
                channelId: event.channelID,
                messageId: event.messageID,
                content: event.content,
                isDirectMessage: isDirectMessage,
                authorIsBot: authorIsBot
            )
        )
    }

    private func parseVoiceRuleEvent(from raw: DiscordJSON?) -> SwiftBotEvent? {
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
            return SwiftBotEvent.join(
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: channelID
            )
        case .moved(let fromChannelID, let toChannelID, let durationSeconds):
            return SwiftBotEvent.move(
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: toChannelID,
                fromChannelId: fromChannelID,
                toChannelId: toChannelID,
                durationSeconds: durationSeconds
            )
        case .left(let channelID, let durationSeconds):
            return SwiftBotEvent.leave(
                guildId: guildId,
                userId: userId,
                username: username,
                channelId: channelID,
                durationSeconds: durationSeconds
            )
        }
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

    /// Send a DM using a Discord embed payload (e.g. for richer welcome / status messages).
    func sendDMEmbed(
        userId: String,
        embed: [String: Any],
        components: [[String: Any]] = []
    ) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: sendDMEmbed blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        guard let token = botToken else { return }

        var payload: [String: Any] = ["embeds": [embed]]
        if !components.isEmpty {
            payload["components"] = components
        }
        let payloadData = try Self.encodeDiscordPayload(payload)
        let channelId = try await messageRESTClient.createDirectMessageChannel(userId: userId, token: token)
        _ = try await messageRESTClient.sendMessage(channelId: channelId, payloadData: payloadData, token: token)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: deleteMessage blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await messageRESTClient.deleteMessage(channelId: channelId, messageId: messageId, token: token)
    }

    // MARK: Sweep helpers

    /// Sweep entry point — fetch recent messages, using the cached bot token.
    /// Read-only; not gated by `outputAllowed`.
    ///
    /// For `limit > 100` this paginates via the `before` cursor with a short
    /// inter-page delay so we don't burst the API.
    func sweepFetchRecentMessages(channelId: String, limit: Int) async throws -> [SweepFetchedMessage] {
        guard let token = botToken, !token.isEmpty else {
            // Custom code so callers can distinguish "bot offline" from "Discord rejected the token".
            throw NSError(domain: "DiscordService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Bot is not connected."])
        }
        let target = max(1, limit)
        var collected: [[String: DiscordJSON]] = []
        var before: String? = nil
        while collected.count < target {
            let pageLimit = min(100, target - collected.count)
            let page = try await messageRESTClient.fetchRecentMessages(
                channelId: channelId,
                limit: pageLimit,
                token: token,
                before: before
            )
            if page.isEmpty { break }
            collected.append(contentsOf: page)
            // Discord returns messages newest-first; advance the cursor with the oldest one we got.
            if case let .string(id)? = page.last?["id"] {
                before = id
            } else {
                break
            }
            // Stop early if Discord returned less than a full page.
            if page.count < pageLimit { break }
            // Inter-page stagger to stay polite with the API.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return collected.compactMap { self.mapSweepMessage(from: $0) }
    }

    /// Sweep entry point — delete a message using the cached bot token.
    /// Gated by `outputAllowed` so only Primary nodes can execute.
    func sweepDeleteMessage(channelId: String, messageId: String) async throws {
        guard let token = botToken, !token.isEmpty else {
            throw NSError(domain: "DiscordService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sweep delete failed: no bot token."])
        }
        try await deleteMessage(channelId: channelId, messageId: messageId, token: token)
    }

    /// Sweep entry point — delete many messages efficiently. Uses Discord's
    /// bulk-delete (≤100/request) for messages younger than 14 days and falls
    /// back to individual deletes for older ones (Discord forbids bulk on those).
    /// Honours 429 `retry_after` with bounded retries. Returns the number of
    /// messages actually deleted. Gated by `outputAllowed`.
    @discardableResult
    func sweepDeleteMessages(channelId: String, messageIds: [String]) async -> Int {
        guard outputAllowed, let token = botToken, !token.isEmpty, !messageIds.isEmpty else { return 0 }

        // Snowflake age cutoff. Use a margin below Discord's hard 14-day bulk
        // limit so a message that crosses the boundary mid-run doesn't 400 the
        // whole batch.
        let cutoff = Date().addingTimeInterval(-13.5 * 86_400)
        var recent: [String] = []
        var old: [String] = []
        for id in messageIds {
            if let created = Self.messageCreatedDate(fromSnowflake: id), created < cutoff {
                old.append(id)
            } else {
                recent.append(id)
            }
        }

        var deleted = 0

        // Recent → bulk-delete in chunks of 100. A lone message can't use
        // bulk-delete (needs ≥2), so delete it individually.
        for chunk in stride(from: 0, to: recent.count, by: 100).map({ Array(recent[$0..<min($0 + 100, recent.count)]) }) {
            if chunk.count == 1 {
                if await deleteIndividually(channelId: channelId, messageId: chunk[0], token: token) { deleted += 1 }
            } else {
                let ok = await withRateLimitRetry {
                    try await self.messageRESTClient.bulkDeleteMessages(channelId: channelId, messageIds: chunk, token: token)
                }
                if ok { deleted += chunk.count }
            }
        }

        // Old → individual deletes, paced to stay polite with the API.
        for id in old {
            if await deleteIndividually(channelId: channelId, messageId: id, token: token) { deleted += 1 }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        return deleted
    }

    /// Single delete with 429 retry. Returns whether it succeeded.
    private func deleteIndividually(channelId: String, messageId: String, token: String) async -> Bool {
        await withRateLimitRetry {
            try await self.messageRESTClient.deleteMessage(channelId: channelId, messageId: messageId, token: token)
        }
    }

    /// Run a throwing REST call, retrying on HTTP 429 after the server's
    /// `retry_after`. Returns `true` on success, `false` once retries are
    /// exhausted or a non-429 error is hit (caller continues with the rest).
    private func withRateLimitRetry(maxAttempts: Int = 5, _ work: () async throws -> Void) async -> Bool {
        var attempt = 0
        while attempt < maxAttempts {
            do {
                try await work()
                return true
            } catch {
                let ns = error as NSError
                guard ns.code == 429 else { return false }
                let retryAfter = Self.retryAfterSeconds(from: ns) ?? 1.0
                try? await Task.sleep(nanoseconds: UInt64(min(retryAfter, 10) * 1_000_000_000))
                attempt += 1
            }
        }
        return false
    }

    /// Parse `retry_after` (seconds) from a 429 NSError's `responseBody`.
    private static func retryAfterSeconds(from error: NSError) -> Double? {
        guard let body = error.userInfo["responseBody"] as? String,
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let secs = json["retry_after"] as? Double { return secs }
        if let secs = json["retry_after"] as? Int { return Double(secs) }
        return nil
    }

    private static func encodeDiscordPayload(_ payload: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload)
    }

    /// Discord snowflake → creation date. `timestamp_ms = (id >> 22) + epoch`,
    /// where the Discord epoch is 2015-01-01.
    static func messageCreatedDate(fromSnowflake id: String) -> Date? {
        guard let raw = UInt64(id) else { return nil }
        let discordEpochMs: UInt64 = 1_420_070_400_000
        let ms = (raw >> 22) + discordEpochMs
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// Replace `:name:` shorthand with the `<:name:id>` token Discord needs for
    /// custom emoji, using the guild's emoji list. Unmatched shorthand is left
    /// as-is (it may be a Unicode emoji or just text). Read-only; best-effort.
    func sweepResolveCustomEmoji(guildId: String, in text: String) async -> String {
        guard text.contains(":"), !guildId.isEmpty, let token = botToken, !token.isEmpty,
              let emojis = try? await messageRESTClient.fetchGuildEmojis(guildId: guildId, token: token),
              !emojis.isEmpty else { return text }
        var out = text
        for emoji in emojis {
            let shorthand = ":\(emoji.name):"
            guard out.contains(shorthand) else { continue }
            // Skip if a fully-formed token is already present (e.g. the user
            // pasted `<:name:id>` directly) — otherwise we'd corrupt it.
            if out.contains("<:\(emoji.name):") || out.contains("<a:\(emoji.name):") { continue }
            let prefix = emoji.animated ? "a" : ""
            out = out.replacingOccurrences(of: shorthand, with: "<\(prefix):\(emoji.name):\(emoji.id)>")
        }
        return out
    }

    /// Sweep entry point — post an embed notice and pin it. Returns the new
    /// message ID. Gated by `outputAllowed` via the underlying REST calls.
    func sweepPostPinnedNotice(channelId: String, embed: [String: Any]) async throws -> String {
        guard outputAllowed else {
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        guard let token = botToken, !token.isEmpty else {
            throw NSError(domain: "DiscordService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sweep notice failed: no bot token."])
        }
        let payload: [String: Any] = [
            "embeds": [embed],
            "allowed_mentions": ["parse": []]
        ]
        let payloadData = try Self.encodeDiscordPayload(payload)
        let messageId = try await messageRESTClient.sendMessageReturningID(channelId: channelId, payloadData: payloadData, token: token)
        try await messageRESTClient.pinMessage(channelId: channelId, messageId: messageId, token: token)
        return messageId
    }

    /// Sweep entry point — edit the existing pinned notice embed in-place.
    /// Gated by `outputAllowed` via the same Primary-only guard as other
    /// Discord output paths.
    func sweepEditPinnedNotice(channelId: String, messageId: String, embed: [String: Any]) async throws {
        guard outputAllowed else {
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        guard let token = botToken, !token.isEmpty else {
            throw NSError(domain: "DiscordService", code: 401, userInfo: [NSLocalizedDescriptionKey: "Sweep notice failed: no bot token."])
        }
        let payloadData = try Self.encodeDiscordPayload([
            "embeds": [embed],
            "allowed_mentions": ["parse": []]
        ])
        try await messageRESTClient.editMessage(
            channelId: channelId,
            messageId: messageId,
            payloadData: payloadData,
            token: token
        )
    }

    /// Sweep entry point — does a previously-posted notice still exist? Used so
    /// the notice is posted once and only re-posted if it was deleted. Read-only
    /// (not gated by `outputAllowed`). On a transient/non-404 error we assume it
    /// still exists, so we never accidentally post a duplicate.
    func sweepMessageExists(channelId: String, messageId: String) async -> Bool {
        guard let token = botToken, !token.isEmpty else { return false }
        do {
            _ = try await messageRESTClient.fetchMessage(channelId: channelId, messageId: messageId, token: token)
            return true
        } catch {
            return (error as NSError).code != 404
        }
    }

    nonisolated(unsafe) private static let sweepTimestampWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let sweepTimestampNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func parseSweepTimestamp(_ stamp: String) -> Date? {
        if let date = sweepTimestampWithFraction.date(from: stamp) { return date }
        return sweepTimestampNoFraction.date(from: stamp)
    }

    private func mapSweepMessage(from raw: [String: DiscordJSON]) -> SweepFetchedMessage? {
        guard case let .string(id)? = raw["id"] else { return nil }
        let content: String = {
            if case let .string(value)? = raw["content"] { return value }
            return ""
        }()
        let createdAt: Date = {
            if case let .string(stamp)? = raw["timestamp"],
               let parsed = Self.parseSweepTimestamp(stamp) {
                return parsed
            }
            return Date()
        }()
        let isPinned: Bool = {
            if case let .bool(value)? = raw["pinned"] { return value }
            return false
        }()
        let hasReactions: Bool = {
            if case .array(let arr)? = raw["reactions"], !arr.isEmpty { return true }
            return false
        }()
        var authorID = ""
        var authorName = ""
        var isBot = false
        if case let .object(author)? = raw["author"] {
            if case let .string(value)? = author["id"] { authorID = value }
            if case let .string(value)? = author["username"] { authorName = value }
            if case let .bool(value)? = author["bot"] { isBot = value }
        }

        return SweepFetchedMessage(
            id: id,
            authorID: authorID,
            authorName: authorName,
            isBot: isBot,
            content: Self.humanizeContent(
                content,
                mentionNames: Self.mentionNames(from: raw),
                channelNames: channelNamesByID,
                roleNames: roleNamesByID
            ),
            createdAt: createdAt,
            isPinned: isPinned,
            hasReactions: hasReactions
        )
    }

    /// Build a user-mention map (id → display name) from a message's `mentions`
    /// array so `<@id>` can render as a real @name in logs/activity/speech.
    static func mentionNames(from raw: [String: DiscordJSON]) -> [String: String] {
        var names: [String: String] = [:]
        guard case let .array(mentions)? = raw["mentions"] else { return names }
        for case let .object(user) in mentions {
            guard case let .string(uid)? = user["id"] else { continue }
            if case let .string(global)? = user["global_name"], !global.isEmpty {
                names[uid] = global
            } else if case let .string(uname)? = user["username"] {
                names[uid] = uname
            }
        }
        return names
    }

    /// Convert Discord's raw markup into human-readable text for logs/activity:
    /// `<@id>`/`<@!id>` → `@name`, `<@&id>` → `@role-name`, `<#id>` → `#channel-name`,
    /// `<:name:id>`/`<a:name:id>` → `:name:`, `<t:unix(:style)>` → a date. Pass
    /// `channelNames`/`roleNames` (id → name) to resolve real names; unknown IDs
    /// fall back to the generic `#channel` / `@role`.
    static func humanizeContent(
        _ content: String,
        mentionNames: [String: String],
        channelNames: [String: String] = [:],
        roleNames: [String: String] = [:]
    ) -> String {
        guard content.contains("<") else { return content }
        var text = content

        func replace(_ pattern: String, _ transform: ([String]) -> String) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: text) else { continue }
                var groups: [String] = []
                for i in 1..<match.numberOfRanges {
                    if let r = Range(match.range(at: i), in: text) {
                        groups.append(String(text[r]))
                    } else {
                        groups.append("")
                    }
                }
                text.replaceSubrange(full, with: transform(groups))
            }
        }

        // Custom emoji <:name:id> / <a:name:id> → :name:
        replace("<a?:([A-Za-z0-9_]+):[0-9]+>") { ":\($0[0]):" }
        // User mentions <@id> / <@!id> → @name (real name when known)
        replace("<@!?([0-9]+)>") { groups in
            let id = groups[0]
            return "@\(mentionNames[id] ?? "user")"
        }
        // Role mentions <@&id> → @role-name (generic when unknown)
        replace("<@&([0-9]+)>") { groups in "@\(roleNames[groups[0]] ?? "role")" }
        // Channel mentions <#id> → #channel-name (generic when unknown)
        replace("<#([0-9]+)>") { groups in "#\(channelNames[groups[0]] ?? "channel")" }
        // Timestamps <t:unix> / <t:unix:style> → localized date/time
        replace("<t:([0-9]+)(?::[a-zA-Z])?>") { groups in
            guard let secs = TimeInterval(groups[0]) else { return groups[0] }
            return DiscordService.humanTimestampFormatter.string(from: Date(timeIntervalSince1970: secs))
        }
        return text
    }

    private static let humanTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    func addRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        guard outputAllowed else {
            discordLogger.warning("[DiscordService] Secondary guard: addRole blocked — outputAllowed is false (node is not Primary).")
            throw NSError(domain: "DiscordService", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked: node is not Primary."])
        }
        try await guildRESTClient.addRole(guildId: guildId, userId: userId, roleId: roleId, token: token)
    }

    func fetchGuildInvites(guildId: String, token: String) async throws -> [WelcomeFlowService.InviteSnapshot] {
        try await guildRESTClient.fetchGuildInvites(guildID: guildId, token: token)
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
