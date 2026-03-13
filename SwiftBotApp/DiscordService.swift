import Foundation
import OSLog
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
            let finalContent: String
            switch message.role {
            case .system:
                role = .system
                finalContent = trimmed
            case .assistant:
                role = .assistant
                // Trim long assistant messages so they don't poison subsequent context.
                finalContent = trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
            case .user:
                role = .user
                finalContent = "\(message.username): \(trimmed)"
            }
            return EngineMessage(role: role, content: finalContent)
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

struct OpenAIEngine: AIEngine {
    let apiKey: String
    let model: String
    let baseURL: String
    let session: URLSession

    private struct ChatCompletionRequest: Encodable {
        struct ChatMessage: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [ChatMessage]
        let temperature: Double
    }

    private struct ChatCompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    func generate(messages: [Message]) async -> String? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        guard let url = URL(string: "\(baseURL)/v1/chat/completions") else { return nil }

        let payloadMessages = messages.toEngineMessages().map { message in
            ChatCompletionRequest.ChatMessage(role: message.role.rawValue, content: message.content)
        }
        guard payloadMessages.contains(where: { $0.role == "user" }) else { return nil }

        let payload = ChatCompletionRequest(model: trimmedModel, messages: payloadMessages, temperature: 0.4)

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 25
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let content = decoded.choices.first?.message.content ?? ""
            let cleaned = cleanOutput(content)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    static func isOnline(apiKey: String, baseURL: String, session: URLSession) async -> Bool {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty, let url = URL(string: "\(baseURL)/v1/models") else { return false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

struct OpenAIImageEngine {
    let apiKey: String
    let model: String
    let baseURL: String
    let session: URLSession

    private struct ImageGenerationRequest: Encodable {
        let model: String
        let prompt: String
        let size: String
    }

    private struct ImageGenerationResponse: Decodable {
        struct ImageData: Decodable {
            let b64_json: String?
        }
        let data: [ImageData]
    }

    func generateImage(prompt: String) async -> Data? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return nil }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else { return nil }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }
        guard let url = URL(string: "\(baseURL)/v1/images/generations") else { return nil }

        let payload = ImageGenerationRequest(
            model: trimmedModel,
            prompt: trimmedPrompt,
            size: "1024x1024"
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 60
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }

            let decoded = try JSONDecoder().decode(ImageGenerationResponse.self, from: data)
            guard
                let b64 = decoded.data.first?.b64_json,
                let imageData = Data(base64Encoded: b64)
            else {
                return nil
            }
            return imageData
        } catch {
            return nil
        }
    }
}

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
    private let finalsWikiAPI = URL(string: "https://www.thefinals.wiki/api.php")!
    private let duckDuckGoHTML = URL(string: "https://duckduckgo.com/html/")!
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
    private var finalsWeaponAliasCache: [String: String] = [:]
    private var finalsWeaponAliasCacheAt: Date?
    private lazy var messageRESTClient = DiscordMessageRESTClient(session: session, restBase: restBase)

    typealias HistoryProvider = @Sendable (MemoryScope) async -> [Message]
    private var historyProvider: HistoryProvider?

    private var localAIDMReplyEnabled = false
    private var localAIProvider: AIProvider = .appleIntelligence
    private var localPreferredAIProvider: AIProviderPreference = .apple
    private var localAIEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
    private var localAIModel = "local-model"
    private var localOpenAIAPIKey = ""
    private var localOpenAIModel = "gpt-4o-mini"
    private var localAISystemPrompt = ""

    /// Tracks message IDs that were handled by rule actions to prevent duplicate AI replies
    private var ruleHandledMessageIds: Set<String> = []
    private let ruleHandledLock = NSLock()

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
    ) {
        localAIDMReplyEnabled = enabled
        localAIProvider = provider
        localPreferredAIProvider = preferredProvider
        localAIEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        localAIModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        localOpenAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        localOpenAIModel = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        localAISystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Checks if a message was already handled by rule actions (prevents duplicate AI replies)
    func wasMessageHandledByRules(messageId: String) -> Bool {
        ruleHandledLock.lock()
        defer { ruleHandledLock.unlock() }
        return ruleHandledMessageIds.contains(messageId)
    }

    /// Marks a message as handled by rule actions
    func markMessageHandledByRules(messageId: String) {
        ruleHandledLock.lock()
        ruleHandledMessageIds.insert(messageId)
        // Cleanup old entries to prevent memory growth (keep last 1000)
        if ruleHandledMessageIds.count > 1000 {
            // Remove oldest entries by converting to array and back
            let sortedIds = Array(ruleHandledMessageIds)
            ruleHandledMessageIds = Set(sortedIds.suffix(1000))
        }
        ruleHandledLock.unlock()
    }

    func detectOllamaModel(baseURL: String) async -> String? {
        await detectOllamaModel(baseURL: baseURL, preferredModel: nil)
    }

    func currentAIStatus(ollamaBaseURL: String, ollamaModelHint: String?, openAIAPIKey: String) async -> (appleOnline: Bool, ollamaOnline: Bool, ollamaModel: String?, openAIOnline: Bool) {
        let appleOnline = isAppleIntelligenceAvailable()
        let normalized = normalizedOllamaBaseURL(ollamaBaseURL)
        let model = await detectOllamaModel(baseURL: normalized, preferredModel: ollamaModelHint)
        let openAIOnline = await OpenAIEngine.isOnline(apiKey: openAIAPIKey, baseURL: "https://api.openai.com", session: session)
        return (appleOnline, model != nil, model, openAIOnline)
    }

    func generateSmartDMReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
    ) async -> String? {
        await generateLocalAIDMReply(
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
        let finalSystemPrompt = PromptComposer.buildSystemPrompt(
            base: systemPrompt,
            serverName: nil,
            channelName: nil,
            wikiContext: nil
        )
        let finalMessages = PromptComposer.buildMessages(systemPrompt: finalSystemPrompt, history: messages)
        guard finalMessages.contains(where: { $0.role == .user }) else { return nil }

        let appleEngine = AppleIntelligenceEngine(defaultSystemPrompt: finalSystemPrompt)
        let ollamaEngine = OllamaEngine(
            baseURL: normalizedOllamaBaseURL(localAIEndpoint),
            preferredModel: localAIModel,
            session: session
        )
        let openAIEngine = OpenAIEngine(
            apiKey: localOpenAIAPIKey,
            model: localOpenAIModel.isEmpty ? "gpt-4o-mini" : localOpenAIModel,
            baseURL: "https://api.openai.com",
            session: session
        )

        for engine in orderedEngines(preferred: localPreferredAIProvider, apple: appleEngine, ollama: ollamaEngine, openAI: openAIEngine) {
            if let reply = await engine.generate(messages: finalMessages) {
                let cleaned = cleanOutput(reply)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private func stripLeadingSpeakerPrefix(_ text: String, username: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !speaker.isEmpty else { return trimmed }

        guard let range = trimmed.range(of: speaker, options: [.anchored, .caseInsensitive]) else {
            return trimmed
        }
        var remainder = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let first = remainder.first, first == ":" || first == "-" else {
            return trimmed
        }
        remainder.removeFirst()
        return remainder.trimmingCharacters(in: .whitespacesAndNewlines)
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

        for candidate in await finalsBroadQueryCandidates(for: trimmedQuery) {
            if let result = await lookupFinalsWikiExact(query: candidate) {
                return result
            }
        }
        return nil
    }

    private func lookupFinalsWikiExact(query: String) async -> FinalsWikiLookupResult? {
        if let direct = await fetchDirectFinalsWikiPage(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(direct)
        }

        if let title = await searchFinalsWikiTitle(query: query) {
            if let pageResult = await fetchFinalsWikiPage(forTitle: title),
               pageResult.weaponStats != nil {
                return pageResult
            }

            if let result = await fetchFinalsWikiSummary(title: title) {
                return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
            }
        }

        if let result = await searchFinalsWikiViaSiteSearch(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
        }

        if let result = await searchFinalsWikiViaWeb(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
        }
        return nil
    }

    private func finalsBroadQueryCandidates(for query: String) async -> [String] {
        let cleaned = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let key = finalsLookupKey(cleaned)
        var candidates: [String] = [cleaned]
        var seen: Set<String> = [cleaned.lowercased()]
        let aliases = await finalsWeaponAliases()

        if let canonical = aliases[key] {
            let normalizedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedCanonical.isEmpty, seen.insert(normalizedCanonical.lowercased()).inserted {
                candidates.append(normalizedCanonical)
            }
        }

        if cleaned.contains("-") {
            let spaced = cleaned.replacingOccurrences(of: "-", with: " ")
            if seen.insert(spaced.lowercased()).inserted {
                candidates.append(spaced)
            }
        } else if cleaned.contains(" ") {
            let hyphenated = cleaned.replacingOccurrences(of: " ", with: "-")
            if seen.insert(hyphenated.lowercased()).inserted {
                candidates.append(hyphenated)
            }
        }

        let compact = cleaned.replacingOccurrences(of: " ", with: "")
        if seen.insert(compact.lowercased()).inserted {
            candidates.append(compact)
        }

        return candidates
    }

    private func finalsWeaponAliases() async -> [String: String] {
        let now = Date()
        if let fetchedAt = finalsWeaponAliasCacheAt,
           now.timeIntervalSince(fetchedAt) < 6 * 60 * 60,
           !finalsWeaponAliasCache.isEmpty {
            return Self.finalsCanonicalAliases.merging(finalsWeaponAliasCache, uniquingKeysWith: { _, new in new })
        }

        let fetchedAliases = await fetchFinalsWeaponAliasesFromWiki()
        finalsWeaponAliasCache = fetchedAliases
        finalsWeaponAliasCacheAt = now
        return Self.finalsCanonicalAliases.merging(fetchedAliases, uniquingKeysWith: { _, new in new })
    }

    private func fetchFinalsWeaponAliasesFromWiki() async -> [String: String] {
        var aliases: [String: String] = [:]
        var cmcontinue: String?
        var pageCount = 0

        while pageCount < 4 {
            var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
            var items: [URLQueryItem] = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "list", value: "categorymembers"),
                URLQueryItem(name: "cmtitle", value: "Category:Weapons"),
                URLQueryItem(name: "cmtype", value: "page"),
                URLQueryItem(name: "cmlimit", value: "500"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "origin", value: "*")
            ]
            if let cmcontinue, !cmcontinue.isEmpty {
                items.append(URLQueryItem(name: "cmcontinue", value: cmcontinue))
            }
            components?.queryItems = items
            guard let url = components?.url else { break }

            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let query = json["query"] as? [String: Any],
                      let members = query["categorymembers"] as? [[String: Any]] else {
                    break
                }

                for member in members {
                    guard let title = member["title"] as? String else { continue }
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    aliases[finalsLookupKey(trimmed)] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: "-", with: ""))] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: "-", with: " "))] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: " ", with: ""))] = trimmed
                }

                if let `continue` = json["continue"] as? [String: Any],
                   let next = `continue`["cmcontinue"] as? String,
                   !next.isEmpty {
                    cmcontinue = next
                    pageCount += 1
                    continue
                }
                break
            } catch {
                break
            }
        }

        return aliases
    }

    private func enrichFinalsResultWithWikitextStatsIfNeeded(_ result: FinalsWikiLookupResult) async -> FinalsWikiLookupResult {
        guard result.weaponStats == nil else { return result }
        guard let stats = await fetchFinalsWeaponStatsFromWikitext(title: result.title) else { return result }
        return FinalsWikiLookupResult(
            title: result.title,
            extract: result.extract,
            url: result.url,
            weaponStats: stats
        )
    }

    private func fetchFinalsWeaponStatsFromWikitext(title: String) async -> FinalsWeaponStats? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "revisions"),
            URLQueryItem(name: "rvprop", value: "content"),
            URLQueryItem(name: "rvslots", value: "main"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = object["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any] else { return nil }

            var wikitext: String?
            for pageValue in pages.values {
                guard let page = pageValue as? [String: Any],
                      let revisions = page["revisions"] as? [[String: Any]],
                      let revision = revisions.first,
                      let slots = revision["slots"] as? [String: Any],
                      let main = slots["main"] as? [String: Any] else { continue }
                if let raw = main["*"] as? String, !raw.isEmpty {
                    wikitext = raw
                    break
                }
            }
            guard let wikitext, !wikitext.isEmpty else { return nil }
            return parseWeaponStatsFromWikitext(wikitext)
        } catch {
            return nil
        }
    }

    private func parseWeaponStatsFromWikitext(_ wikitext: String) -> FinalsWeaponStats? {
        let lines = wikitext.components(separatedBy: .newlines)

        func value(for labels: [String]) -> String? {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("|"),
                      let equals = trimmed.firstIndex(of: "=") else { continue }
                let rawKey = String(trimmed[trimmed.index(after: trimmed.startIndex)..<equals])
                let rawValue = String(trimmed[trimmed.index(after: equals)...])
                let key = rawKey
                    .lowercased()
                    .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
                let cleanedValue = cleanWikitextValue(rawValue)
                if cleanedValue.isEmpty { continue }
                for label in labels where key == label {
                    return cleanedValue
                }
            }
            return nil
        }

        let type = value(for: ["type", "class", "weapontype"])
        let bodyDamage = value(for: ["body", "damage", "damagepershot", "basedamage"])
        let headshotDamage = value(for: ["head", "headshot", "headshotdamage", "criticalhit"])
        let fireRate = value(for: ["rpm", "firerate", "rateoffire"])
        let dropoffStart = value(for: ["minrange", "dropoffstart", "effectiverangestart"])
        let dropoffEnd = value(for: ["maxrange", "dropoffend", "effectiverangeend"])
        let minimumDamage = value(for: ["minimumdamage", "mindamage"])
        let magazineSize = value(for: ["magazine", "magsize", "magazinesize", "ammo"])
        let shortReload = value(for: ["tacticalreload", "shortreload", "reloadpartial", "reloadtime"])
        let longReload = value(for: ["emptyreload", "longreload", "reloadempty"])

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

    private func cleanWikitextValue(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(of: #"\{\{[^{}]*\|([^{}|]+)\}\}"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\[\[([^|\]]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"'''"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"''"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\{\{[^{}]*\}\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalsLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private static let finalsCanonicalAliases: [String: String] = [
        "fcar": "FCAR",
        "akm": "AKM",
        "cl40": "CL-40",
        "model1887": "Model 1887",
        "pike556": "Pike-556",
        "r357": ".357",
        "357": ".357",
        "m11": "M11",
        "xp54": "XP-54",
        "v9s": "V9S",
        "v95": "V9S",
        "arn220": "ARN-220",
        "arn": "ARN-220",
        "arn220rifle": "ARN-220",
        "arnrifle": "ARN-220",
        "lh1": "LH1",
        "sr84": "SR-84",
        "recurvedbow": "Recurve Bow",
        "shak50": "SHaK-50",
        "shak": "SHaK-50",
        "m60": "M60",
        "lewismg": "Lewis Gun",
        "sa1216": "SA1216",
        "ks23": "KS-23",
        "sledgehammer": "Sledgehammer",
        "flamethrower": "Flamethrower"
    ]

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
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return TokenValidationResult(isValid: false, userId: nil, username: nil,
                                         discriminator: nil, avatarURL: nil,
                                         errorCategory: .invalidToken,
                                         errorMessage: "Token is empty.")
        }

        var req = URLRequest(url: restBase.appendingPathComponent("users/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                discordLogger.warning("Token validation: invalid response (no HTTPURLResponse)")
                return .failure(.networkFailure)
            }

            switch http.statusCode {
            case 200..<300:
                // Parse bot identity from response.
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let userId   = json?["id"] as? String
                let username = json?["username"] as? String
                let discrim  = json?["discriminator"] as? String
                let avatarHash = json?["avatar"] as? String
                var avatarURL: URL?
                if let uid = userId, let hash = avatarHash, !hash.isEmpty {
                    avatarURL = URL(string: "https://cdn.discordapp.com/avatars/\(uid)/\(hash).png")
                }
                discordLogger.info("Token validation succeeded for user \(userId ?? "unknown", privacy: .private)")
                return TokenValidationResult(isValid: true, userId: userId, username: username,
                                             discriminator: discrim, avatarURL: avatarURL,
                                             errorCategory: nil, errorMessage: "Valid token")
            case 401:
                discordLogger.warning("Token validation: 401 unauthorized")
                return .failure(.invalidToken)
            case 429:
                discordLogger.warning("Token validation: 429 rate limited")
                return .failure(.rateLimited)
            default:
                discordLogger.warning("Token validation: unexpected HTTP \(http.statusCode, privacy: .public)")
                return .failure(.serverError(http.statusCode))
            }
        } catch {
            discordLogger.warning("Token validation: network failure — \(error.localizedDescription, privacy: .public)")
            return .failure(.networkFailure)
        }
    }

    /// Resolves the bot's application client_id via /oauth2/applications/@me.
    /// Falls back to the userId from token validation if the endpoint is unavailable.
    func resolveClientID(token: String, fallbackUserID: String?) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackUserID }

        var req = URLRequest(url: restBase.appendingPathComponent("oauth2/applications/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let appID = json["id"] as? String {
                discordLogger.info("Resolved client_id from /oauth2/applications/@me")
                return appID
            }
        } catch {
            discordLogger.warning("client_id resolution failed, using fallback: \(error.localizedDescription, privacy: .public)")
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
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, nil, nil) }
        var req = URLRequest(url: URL(string: "https://discord.com/api/v10/users/@me")!)
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (false, nil, nil) }
            let remaining = (http.value(forHTTPHeaderField: "X-RateLimit-Remaining"))
                .flatMap { Int($0) }
            return (http.statusCode == 200, http.statusCode, remaining)
        } catch {
            return (false, nil, nil)
        }
    }

    func validateBotToken(_ token: String) async -> (isValid: Bool, message: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Token is empty.")
        }

        var req = URLRequest(url: restBase.appendingPathComponent("users/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Discord returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Valid token")
            }
            if http.statusCode == 401 {
                return (false, "Unauthorized (401). Token is invalid or revoked.")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.isEmpty {
                return (false, "Discord API returned HTTP \(http.statusCode).")
            }
            return (false, "Discord API returned HTTP \(http.statusCode): \(body)")
        } catch {
            return (false, "Token validation request failed: \(error.localizedDescription)")
        }
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

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ownerID = json["owner_id"] as? String,
                !ownerID.isEmpty
            else {
                return nil
            }
            guildOwnerIdByGuild[trimmedGuildID] = ownerID
            return ownerID
        } catch {
            return nil
        }
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

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)/members/\(trimmedUserID)"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roles = json["roles"] as? [String] else {
                return nil
            }
            return roles
        } catch {
            return nil
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
        let trimmedAppID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppID.isEmpty else { return }
        var req = URLRequest(url: restBase.appendingPathComponent("applications/\(trimmedAppID)/commands"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: commands)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to register slash commands",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func registerGuildApplicationCommands(
        applicationID: String,
        guildID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        let trimmedAppID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppID.isEmpty, !trimmedGuildID.isEmpty else { return }
        var req = URLRequest(url: restBase.appendingPathComponent("applications/\(trimmedAppID)/guilds/\(trimmedGuildID)/commands"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: commands)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to register guild slash commands",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
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
        var req = URLRequest(url: restBase.appendingPathComponent("interactions/\(interactionID)/\(interactionToken)/callback"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to respond to interaction",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
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
        var req = URLRequest(url: restBase.appendingPathComponent("webhooks/\(applicationID)/\(interactionToken)/messages/@original"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to edit interaction response",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func fetchFinalsMetaFromSkycoach() async -> String? {
        guard let url = URL(string: "https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds") else {
            return nil
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let cleanedHTML = html
                .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<noscript[\s\S]*?</noscript>"#, with: " ", options: .regularExpression)

            let headingRegex = try NSRegularExpression(
                pattern: #"<h[2-4][^>]*>(.*?)</h[2-4]>(.*?)(?=<h[2-4][^>]*>|$)"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )

            func normalize(_ value: String) -> String {
                value
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            func cleanFieldValue(_ raw: String) -> String {
                var value = normalize(stripHTML(raw))
                value = value.replacingOccurrences(of: #"^[\-\:\•\s]+"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s+\|\s+.*$"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                value = value.replacingOccurrences(of: "â€˜", with: "'")
                value = value.replacingOccurrences(of: "â€™", with: "'")
                if let cut = value.range(
                    of: #"(?i)\b(the reason|players|gameplay|balancing|this build|this class|speaking of|adding a few|it embodies|it epitomizes)\b"#,
                    options: .regularExpression
                ) {
                    value = String(value[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let dot = value.firstIndex(of: ".") {
                    value = String(value[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }

            func plainTextForSection(_ bodyHTML: String) -> String {
                let withLineBreaks = bodyHTML
                    .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</li>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</div>"#, with: "\n", options: .regularExpression)
                return withLineBreaks
            }

            func extractLabeledValue(from text: String, labelPattern: String, stopLabels: [String]) -> String? {
                let stopPattern = stopLabels.joined(separator: "|")
                let pattern = #"(?is)\b(?:best\s+)?"# + labelPattern + #"\b\s*:\s*(.+?)(?=\b(?:best\s+)?(?:"# + stopPattern + #")\b\s*:|[\n\r]|$)"#
                guard let raw = text.firstMatch(for: pattern) else { return nil }
                let cleaned = cleanFieldValue(raw)
                return cleaned.isEmpty ? nil : cleaned
            }

            func extractField(in bodyText: String, bodyItems: [String], labels: [String], stopLabels: [String]) -> String? {
                for label in labels {
                    if let match = extractLabeledValue(from: bodyText, labelPattern: label, stopLabels: stopLabels) {
                        if !match.isEmpty { return match }
                    }
                    for item in bodyItems {
                        if item.lowercased().contains(label.lowercased()) {
                            let pattern = #"(?i)(?:best\s+)?"# + label + #"\s*[:\-]\s*(.+)"#
                            guard let match = item.firstMatch(for: pattern) else { continue }
                            let value = cleanFieldValue(match)
                            if !value.isEmpty { return value }
                        }
                    }
                }
                return nil
            }

            struct MetaBuildSection {
                let title: String
                var weapon: String?
                var specialization: String?
                var gadgets: String?
            }

            var parsed: [String: MetaBuildSection] = [:]
            let range = NSRange(location: 0, length: (cleanedHTML as NSString).length)

            for match in headingRegex.matches(in: cleanedHTML, options: [], range: range) {
                guard match.numberOfRanges >= 3 else { continue }
                let headingRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)
                guard headingRange.location != NSNotFound, bodyRange.location != NSNotFound else { continue }

                let heading = normalize(stripHTML((cleanedHTML as NSString).substring(with: headingRange)))
                let headingLower = heading.lowercased()

                let sectionKey: String
                if headingLower.contains("light") {
                    sectionKey = "Light"
                } else if headingLower.contains("medium") {
                    sectionKey = "Medium"
                } else if headingLower.contains("heavy") {
                    sectionKey = "Heavy"
                } else {
                    continue
                }

                let bodyHTML = (cleanedHTML as NSString).substring(with: bodyRange)
                let bodyText = normalize(stripHTML(plainTextForSection(bodyHTML)))
                let bodyItems = htmlMatches(for: #"<li[^>]*>(.*?)</li>"#, in: bodyHTML)
                    .map { normalize(stripHTML($0)) }
                    .filter { !$0.isEmpty && !$0.contains("{") && !$0.lowercased().contains("googletagmanager") }

                var section = parsed[sectionKey] ?? MetaBuildSection(title: sectionKey, weapon: nil, specialization: nil, gadgets: nil)
                section.weapon = section.weapon ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["weapon"],
                    stopLabels: ["specialization", "specialisation", "special", "gadgets?", "utility"]
                )
                section.specialization = section.specialization ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["specialization", "specialisation", "special"],
                    stopLabels: ["weapon", "gadgets?", "utility"]
                )
                section.gadgets = section.gadgets ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["gadgets?", "utility"],
                    stopLabels: ["weapon", "specialization", "specialisation", "special"]
                )

                parsed[sectionKey] = section
            }

            let orderedKeys = ["Light", "Medium", "Heavy"]
            let sections = orderedKeys.compactMap { parsed[$0] }
                .filter { $0.weapon != nil || $0.specialization != nil || $0.gadgets != nil }
            guard !sections.isEmpty else { return nil }

            var lines: [String] = ["Current THE FINALS meta (Skycoach):"]
            for section in sections {
                lines.append("")
                lines.append("\(section.title):")
                lines.append("Best Weapon: \(section.weapon ?? "N/A")")
                lines.append("Best Specialization: \(section.specialization ?? "N/A")")
                lines.append("Best Gadgets: \(section.gadgets ?? "N/A")")
            }
            lines.append("")
            lines.append("Source: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds")
            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
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
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch message", "responseBody": responseBody]
            )
        }
        return try JSONDecoder().decode([String: DiscordJSON].self, from: data)
    }

    func fetchRecentMessages(channelId: String, limit: Int, token: String) async throws -> [[String: DiscordJSON]] {
        var components = URLComponents(url: restBase.appendingPathComponent("channels/\(channelId)/messages"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
        guard let url = components?.url else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid messages URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch recent messages", "responseBody": responseBody]
            )
        }
        return try JSONDecoder().decode([[String: DiscordJSON]].self, from: data)
    }

    func addReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/reactions/\(emoji)/@me"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to add reaction", "responseBody": responseBody]
            )
        }
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/reactions/\(emoji)/@me"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to remove reaction", "responseBody": responseBody]
            )
        }
    }

    func pinMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/pins/\(messageId)"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to pin message", "responseBody": responseBody]
            )
        }
    }

    func unpinMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/pins/\(messageId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to unpin message", "responseBody": responseBody]
            )
        }
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/threads"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "auto_archive_duration": 1440
        ])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create thread", "responseBody": responseBody]
            )
        }
    }

    @discardableResult
    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let url = restBase.appendingPathComponent("channels/\(channelId)/messages")
        return try await sendMultipartImage(
            url: url,
            method: "POST",
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
        let url = restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)")
        _ = try await sendMultipartImage(
            url: url,
            method: "PATCH",
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    func generateOpenAIImage(prompt: String, apiKey: String, model: String) async -> Data? {
        let engine = OpenAIImageEngine(
            apiKey: apiKey,
            model: model,
            baseURL: "https://api.openai.com",
            session: session
        )
        return await engine.generateImage(prompt: prompt)
    }

    private func sendMultipartImage(
        url: URL,
        method: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 90
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "content": content,
            "attachments": [
                [
                    "id": "0",
                    "filename": filename
                ]
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n".data(using: .utf8)!)
        body.append(payloadData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to upload image", "responseBody": responseBody]
            )
        }

        if let decoded = try? JSONDecoder().decode(DiscordMessageEnvelope.self, from: data) {
            return decoded.id
        }
        return ""
    }

    private func htmlMatches(for pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let capture = match.range(at: 1)
            guard capture.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: capture)
        }
    }

    /// Sends a typing indicator to the given channel. Fire-and-forget; errors are silently discarded.
    func triggerTyping(channelId: String, token: String) async {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/typing"))
        req.httpMethod = "POST"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: req)
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
        var context = PipelineContext()
        context.isDirectMessage = isDirectMessage
        context.triggerGuildId = event.triggerGuildId
        context.triggerChannelId = event.triggerChannelId
        context.triggerMessageId = event.triggerMessageId

        discordLogger.debug("Executing rule pipeline: \(actions.count) blocks. Initial context: \(context)")

        for (index, action) in actions.enumerated() {
            await execute(action: action, for: event, context: &context)
            discordLogger.debug("  [\(index)] Executed \(action.type.rawValue). Updated context: \(context)")
        }

        if context.eventHandled, let messageId = event.triggerMessageId {
            markMessageHandledByRules(messageId: messageId)
            discordLogger.debug("Message \(messageId) handled by rule actions - AI reply will be skipped")
        }

        discordLogger.debug("Rule pipeline execution complete.")
        return context
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
        
        // 1. Create DM channel
        var req = URLRequest(url: restBase.appendingPathComponent("users/@me/channels"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["recipient_id": userId])
        
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelId = json["id"] as? String else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DM channel"])
        }
        
        // 2. Send message to that channel
        try await sendMessage(channelId: channelId, content: content, token: token)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete message"])
        }
    }

    func addRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)/roles/\(roleId)"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add role"])
        }
    }

    func removeRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)/roles/\(roleId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to remove role"])
        }
    }

    func timeoutMember(guildId: String, userId: String, durationSeconds: Int, token: String) async throws {
        let until = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = ["communication_disabled_until": formatter.string(from: until)]
        
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to timeout member"])
        }
    }

    func kickMember(guildId: String, userId: String, reason: String, token: String) async throws {
        var components = URLComponents(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"), resolvingAgainstBaseURL: false)
        if !reason.isEmpty {
            components?.queryItems = [URLQueryItem(name: "reason", value: reason)]
        }
        guard let url = components?.url else { return }
        
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to kick member"])
        }
    }

    func moveMember(guildId: String, userId: String, channelId: String, token: String) async throws {
        let body: [String: Any] = ["channel_id": channelId.isEmpty ? NSNull() : channelId]
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to move member"])
        }
    }

    func createChannel(guildId: String, name: String, token: String) async throws {
        let body: [String: Any] = ["name": name, "type": 0] // Text channel
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/channels"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create channel"])
        }
    }

    func sendWebhook(url: String, content: String) async throws {
        guard let webhookUrl = URL(string: url) else { return }
        var req = URLRequest(url: webhookUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send webhook"])
        }
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
        guard let token = botToken else { return }
        
        switch action.type {
        case .mentionUser:
            context.prependUserMention = true
        case .mentionRole:
            context.mentionRole = action.roleId
        case .disableMention:
            context.mentionUser = false
        case .sendToChannel:
            context.targetChannelId = action.channelId
        case .sendToDM:
            context.sendToDM = true
        case .replyToTrigger:
            context.replyToTriggerMessage = true
            if let triggerChannelId = event.triggerChannelId {
                context.targetChannelId = triggerChannelId
            }
        case .generateAIResponse:
            let prompt = renderMessage(template: action.message, event: event, context: context)
            if let aiReply = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiResponse = aiReply
            }
        case .summariseMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let prompt = "Summarize the following message concisely:\n\n\(content)"
            if let summary = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiSummary = summary
            }
        case .classifyMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let categories = action.categories.isEmpty ? "question, feedback, spam, other" : action.categories
            let prompt = "Classify the following message into one of these categories [\(categories)]:\n\n\(content)\n\nCategory:"
            if let classification = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiClassification = classification.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .extractEntities:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let entityTypes = action.entityTypes.isEmpty ? "names, dates, locations, organizations" : action.entityTypes
            let prompt = "Extract \(entityTypes) from the following message as a comma-separated list:\n\n\(content)\n\nEntities:"
            if let entities = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiEntities = entities.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .rewriteMessage:
            guard let content = event.messageContent, !content.isEmpty else { break }
            let style = action.rewriteStyle.isEmpty ? "professional" : action.rewriteStyle
            let prompt = "Rewrite the following message in a \(style) style:\n\n\(content)\n\nRewritten:"
            if let rewrite = await generateRuleActionAIReply(prompt: prompt, event: event) {
                context.aiRewrite = rewrite
            }
        case .sendMessage:
            // Determine content based on contentSource
            let messageContent: String
            switch action.contentSource {
            case .custom:
                messageContent = action.message
            case .aiResponse:
                messageContent = context.aiResponse ?? "{ai.response} not available"
            case .aiSummary:
                messageContent = context.aiSummary ?? "{ai.summary} not available"
            case .aiClassification:
                messageContent = context.aiClassification ?? "{ai.classification} not available"
            case .aiEntities:
                messageContent = context.aiEntities ?? "{ai.entities} not available"
            case .aiRewrite:
                messageContent = context.aiRewrite ?? "{ai.rewrite} not available"
            }
            
            let targetIsDM = context.sendToDM
            let rendered = renderMessage(template: messageContent, event: event, context: context)

            if targetIsDM && !event.userId.isEmpty {
                _ = try? await sendDM(userId: event.userId, content: rendered)
                context.eventHandled = true
                return
            }

            let modifierTargetChannelId = context.targetChannelId
            let triggerMessageId = context.triggerMessageId ?? event.triggerMessageId
            let triggerChannelId = context.triggerChannelId ?? event.triggerChannelId

            if context.replyToTriggerMessage,
               let triggerMessageId,
               let triggerChannelId,
               !triggerChannelId.isEmpty {
                let payload: [String: Any] = [
                    "content": rendered,
                    "message_reference": [
                        "message_id": triggerMessageId,
                        "channel_id": triggerChannelId,
                        "fail_if_not_exists": false
                    ]
                ]
                _ = try? await sendMessage(channelId: triggerChannelId, payload: payload, token: token)
                context.eventHandled = true
                return
            }

            let destinationMode = action.destinationMode ?? MessageDestination.defaultMode(for: event, context: context)

            switch destinationMode {
            case .replyToTrigger:
                if let triggerMessageId,
                   let triggerChannelId,
                   !triggerChannelId.isEmpty {
                    let payload: [String: Any] = [
                        "content": rendered,
                        "message_reference": [
                            "message_id": triggerMessageId,
                            "channel_id": triggerChannelId,
                            "fail_if_not_exists": false
                        ]
                    ]
                    _ = try? await sendMessage(channelId: triggerChannelId, payload: payload, token: token)
                    context.eventHandled = true
                } else if let fallbackChannelId = modifierTargetChannelId ?? triggerChannelId, !fallbackChannelId.isEmpty {
                    try? await sendMessage(channelId: fallbackChannelId, content: rendered, token: token)
                    context.eventHandled = true
                } else if !action.channelId.isEmpty {
                    try? await sendMessage(channelId: action.channelId, content: rendered, token: token)
                    context.eventHandled = true
                }
            case .sameChannel:
                let targetChannelId = modifierTargetChannelId ?? triggerChannelId ?? event.channelId
                guard !targetChannelId.isEmpty else { return }
                try? await sendMessage(channelId: targetChannelId, content: rendered, token: token)
                context.eventHandled = true
            case .specificChannel:
                let targetChannelId = modifierTargetChannelId ?? action.channelId
                guard !targetChannelId.isEmpty else { return }
                try? await sendMessage(channelId: targetChannelId, content: rendered, token: token)
                context.eventHandled = true
            }
        case .addLogEntry:
            return
        case .setStatus:
            let statusText = renderMessage(template: action.statusText, event: event, context: context)
            guard !statusText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await updatePresence(text: statusText)
        case .sendDM:
            let rendered = renderMessage(template: action.dmContent, event: event, context: context)
            _ = try? await sendDM(userId: event.userId, content: rendered)
            context.eventHandled = true
        case .addReaction:
            guard let triggerMessageId = event.triggerMessageId, let triggerChannelId = event.triggerChannelId else { return }
            _ = try? await addReaction(channelId: triggerChannelId, messageId: triggerMessageId, emoji: action.emoji, token: token)
            context.eventHandled = true
        case .deleteMessage:
            guard let triggerMessageId = event.triggerMessageId, let triggerChannelId = event.triggerChannelId else { return }
            if action.deleteDelaySeconds > 0 {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(action.deleteDelaySeconds) * 1_000_000_000)
                    _ = try? await deleteMessage(channelId: triggerChannelId, messageId: triggerMessageId, token: token)
                }
            } else {
                _ = try? await deleteMessage(channelId: triggerChannelId, messageId: triggerMessageId, token: token)
            }
            context.eventHandled = true
        case .addRole:
            _ = try? await addRole(guildId: event.guildId, userId: event.userId, roleId: action.roleId, token: token)
            context.eventHandled = true
        case .removeRole:
            _ = try? await removeRole(guildId: event.guildId, userId: event.userId, roleId: action.roleId, token: token)
            context.eventHandled = true
        case .timeoutMember:
            _ = try? await timeoutMember(guildId: event.guildId, userId: event.userId, durationSeconds: action.timeoutDuration, token: token)
            context.eventHandled = true
        case .kickMember:
            _ = try? await kickMember(guildId: event.guildId, userId: event.userId, reason: action.kickReason, token: token)
            context.eventHandled = true
        case .moveMember:
            _ = try? await moveMember(guildId: event.guildId, userId: event.userId, channelId: action.targetVoiceChannelId, token: token)
            context.eventHandled = true
        case .createChannel:
            _ = try? await createChannel(guildId: event.guildId, name: action.newChannelName, token: token)
            context.eventHandled = true
        case .webhook:
            _ = try? await sendWebhook(url: action.webhookURL, content: action.webhookContent)
        case .delay:
            try? await Task.sleep(nanoseconds: UInt64(action.delaySeconds) * 1_000_000_000)
        case .setVariable, .randomChoice:
            // TODO: Implement variables and random choice logic
            discordLogger.debug("Action \(action.type.rawValue) not yet fully implemented")
            return
        }
    }

    private func renderMessage(template: String, event: VoiceRuleEvent, context: PipelineContext) -> String {
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
            .replacingOccurrences(of: "{message}", with: event.messageContent ?? "")
            .replacingOccurrences(of: "{messageId}", with: event.messageId ?? "")
            .replacingOccurrences(of: "{media.file}", with: event.mediaFileName ?? "")
            .replacingOccurrences(of: "{media.path}", with: event.mediaRelativePath ?? "")
            .replacingOccurrences(of: "{media.source}", with: event.mediaSourceName ?? "")
            .replacingOccurrences(of: "{media.node}", with: event.mediaNodeName ?? "")
            .replacingOccurrences(of: "{ai.response}", with: context.aiResponse ?? "")

        if !context.mentionUser {
            output = output.replacingOccurrences(of: "<@\(event.userId)>", with: event.username)
        }

        if context.prependUserMention {
            output = "<@\(event.userId)> " + output
        }

        if let roleMention = context.mentionRole {
            output = "<@&\(roleMention)> " + output
        }

        return output
    }

    private func resolvedChannelName(guildId: String, channelId: String) -> String {
        if let name = voiceChannelNamesByGuild[guildId]?[channelId], !name.isEmpty {
            return name
        }
        return "Channel \(channelId.suffix(5))"
    }

    private func generateLocalAIDMReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
    ) async -> String? {
        guard localAIDMReplyEnabled else { return nil }

        let systemPrompt = PromptComposer.buildSystemPrompt(
            base: localAISystemPrompt,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
        let finalMessages = PromptComposer.buildMessages(systemPrompt: systemPrompt, history: messages)
        guard finalMessages.contains(where: { $0.role == .user }) else { return nil }

        let appleEngine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let ollamaEngine = OllamaEngine(
            baseURL: normalizedOllamaBaseURL(localAIEndpoint),
            preferredModel: localAIModel,
            session: session
        )
        let openAIEngine = OpenAIEngine(
            apiKey: localOpenAIAPIKey,
            model: localOpenAIModel.isEmpty ? "gpt-4o-mini" : localOpenAIModel,
            baseURL: "https://api.openai.com",
            session: session
        )

        for engine in orderedEngines(preferred: localPreferredAIProvider, apple: appleEngine, ollama: ollamaEngine, openAI: openAIEngine) {
            if let reply = await engine.generate(messages: finalMessages) {
                let cleaned = cleanOutput(reply)
                return cleaned.isEmpty ? nil : cleaned
            }
        }
        return nil
    }

    private func generateRuleActionAIReply(prompt: String, event: VoiceRuleEvent) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        let channelId = event.triggerChannelId ?? event.channelId
        let channelName = event.isDirectMessage
            ? "Direct Message"
            : resolvedChannelName(guildId: event.triggerGuildId, channelId: channelId)
        let systemPrompt = PromptComposer.buildSystemPrompt(
            base: localAISystemPrompt,
            serverName: guildNamesById[event.triggerGuildId],
            channelName: channelName,
            wikiContext: nil
        )
        let messages = [
            Message(
                channelID: channelId,
                userID: event.triggerUserId,
                username: event.username,
                content: trimmedPrompt,
                role: .user
            )
        ]
        let finalMessages = PromptComposer.buildMessages(systemPrompt: systemPrompt, history: messages)

        let appleEngine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let ollamaEngine = OllamaEngine(
            baseURL: normalizedOllamaBaseURL(localAIEndpoint),
            preferredModel: localAIModel,
            session: session
        )
        let openAIEngine = OpenAIEngine(
            apiKey: localOpenAIAPIKey,
            model: localOpenAIModel.isEmpty ? "gpt-4o-mini" : localOpenAIModel,
            baseURL: "https://api.openai.com",
            session: session
        )

        for engine in orderedEngines(preferred: localPreferredAIProvider, apple: appleEngine, ollama: ollamaEngine, openAI: openAIEngine) {
            if let reply = await engine.generate(messages: finalMessages) {
                let cleaned = cleanOutput(reply)
                let normalized = stripLeadingSpeakerPrefix(cleaned, username: event.username)
                if !normalized.isEmpty { return normalized }
            }
        }
        return nil
    }

    private func orderedEngines(preferred: AIProviderPreference, apple: AIEngine, ollama: AIEngine, openAI: AIEngine) -> [AIEngine] {
        switch preferred {
        case .apple:
            return [apple, openAI, ollama]
        case .ollama:
            return [ollama, openAI, apple]
        case .openAI:
            return [openAI, apple, ollama]
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

        if let parsedFromLooseLines = extractWeaponStatsFromLooseLines(html: html) {
            return parsedFromLooseLines
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

    private func extractWeaponStatsFromLooseLines(html: String) -> FinalsWeaponStats? {
        let lines = readableTextLines(from: html)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        func value(for labels: [String]) -> String? {
            // Inline `Label: value`
            for line in lines {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawValue.isEmpty { continue }
                for label in labels where normalizedLabel(key) == normalizedLabel(label) {
                    return rawValue
                }
            }

            // Two-line `Label` then `value`
            for (index, line) in lines.enumerated() {
                for label in labels where normalizedLabel(line) == normalizedLabel(label) {
                    if let next = nextValue(in: lines, after: index) {
                        return next
                    }
                }
            }

            return nil
        }

        let type = value(for: ["Type", "Class", "Weapon Type"])
        let bodyDamage = value(for: ["Body", "Damage", "Damage per Shot", "Base Damage"])
        let headshotDamage = value(for: ["Head", "Headshot", "Headshot Damage", "Critical Hit"])
        let fireRate = value(for: ["RPM", "Fire Rate", "Rate of Fire"])
        let dropoffStart = value(for: ["Min Range", "Dropoff Start", "Effective Range Start"])
        let dropoffEnd = value(for: ["Max Range", "Dropoff End", "Effective Range End"])
        let minimumDamage = value(for: ["Minimum Damage", "Min Damage"])
        let magazineSize = value(for: ["Magazine", "Mag Size", "Magazine Size", "Ammo"])
        let shortReload = value(for: ["Tactical Reload", "Short Reload", "Reload (Partial)", "Reload Time"])
        let longReload = value(for: ["Empty Reload", "Long Reload", "Reload (Empty)"])

        let computedMinimum = minimumDamage ?? computeMinimumDamage(
            bodyDamage: bodyDamage,
            multiplier: value(for: ["Multiplier", "Min Damage Multiplier"])
        )

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computedMinimum),
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
