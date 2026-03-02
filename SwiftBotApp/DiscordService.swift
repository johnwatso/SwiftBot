import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    private var localAIDMReplyEnabled = false
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

    func configureLocalAIDMReplies(enabled: Bool, endpoint: String, model: String, systemPrompt: String) {
        localAIDMReplyEnabled = enabled
        localAISystemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func generateSmartDMReply(message: String, username: String) async -> String? {
        await generateLocalAIDMReply(userMessage: message, username: username)
    }

    func lookupFinalsWiki(query: String) async -> FinalsWikiLookupResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        if let direct = await fetchDirectFinalsWikiPage(query: trimmedQuery) {
            return direct
        }

        if let title = await searchFinalsWikiTitle(query: trimmedQuery),
           let result = await fetchFinalsWikiSummary(title: title) {
            return result
        }

        if let result = await searchFinalsWikiViaSiteSearch(query: trimmedQuery) {
            return result
        }

        return await searchFinalsWikiViaWeb(query: trimmedQuery)
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

        let guildId: String
        let isDirectMessage: Bool
        if case let .string(gid)? = map["guild_id"] {
            guildId = gid
            isDirectMessage = false
        } else {
            guildId = ""
            isDirectMessage = true
        }

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
               let aiReply = await generateLocalAIDMReply(userMessage: userMessage, username: event.username) {
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

    private func generateLocalAIDMReply(userMessage: String, username: String) async -> String? {
        guard localAIDMReplyEnabled else { return nil }

        let systemPrompt = localAISystemPrompt.isEmpty
            ? "You are a friendly Discord assistant. Reply briefly and naturally."
            : localAISystemPrompt

#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                break
            default:
                return nil
            }

            let prompt = "Message from \(username): \(userMessage)"
            let session = LanguageModelSession(model: model, instructions: Instructions(systemPrompt))
            do {
                let response = try await session.respond(to: prompt)
                let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : content
            } catch {
                return nil
            }
        }
#endif

        return nil
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
                url: page.fullurl ?? fallbackURL
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
            return FinalsWikiLookupResult(
                title: title ?? resolvedURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " "),
                extract: extract,
                url: resolvedURL.absoluteString
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
