import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol AIEngine: Sendable {
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
            // swiftlint:disable:next identifier_name
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

actor DiscordAIService {
    struct Configuration: Sendable {
        var enabled = false
        var provider: AIProvider = .appleIntelligence
        var preferredProvider: AIProviderPreference = .apple
        var endpoint = "http://127.0.0.1:1234/v1/chat/completions"
        var model = "local-model"
        var openAIAPIKey = ""
        var openAIModel = "gpt-4o-mini"
        var systemPrompt = ""
    }

    struct EngineSet: Sendable {
        let apple: any AIEngine
        let ollama: any AIEngine
        let openAI: any AIEngine
    }

    typealias EngineSetFactory = @Sendable (Configuration, String) -> EngineSet
    typealias OllamaModelResolver = @Sendable (String, String?) async -> String?
    typealias OpenAIProbe = @Sendable (String, String) async -> Bool
    typealias AppleAvailabilityProvider = @Sendable () -> Bool
    typealias OpenAIImageGenerator = @Sendable (String, String, String) async -> Data?

    private var configuration = Configuration()
    private let engineFactory: EngineSetFactory
    private let ollamaModelResolver: OllamaModelResolver
    private let openAIProbe: OpenAIProbe
    private let appleAvailability: AppleAvailabilityProvider
    private let openAIImageGenerator: OpenAIImageGenerator

    init(session: URLSession) {
        engineFactory = { configuration, systemPrompt in
            EngineSet(
                apple: AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt),
                ollama: OllamaEngine(
                    baseURL: Self.normalizedOllamaBaseURL(configuration.endpoint),
                    preferredModel: configuration.model,
                    session: session
                ),
                openAI: OpenAIEngine(
                    apiKey: configuration.openAIAPIKey,
                    model: configuration.openAIModel.isEmpty ? "gpt-4o-mini" : configuration.openAIModel,
                    baseURL: "https://api.openai.com",
                    session: session
                )
            )
        }
        ollamaModelResolver = { baseURL, preferredModel in
            await OllamaEngine.resolveModel(baseURL: baseURL, preferredModel: preferredModel, session: session)
        }
        openAIProbe = { apiKey, baseURL in
            await OpenAIEngine.isOnline(apiKey: apiKey, baseURL: baseURL, session: session)
        }
        appleAvailability = { Self.isAppleIntelligenceAvailable() }
        openAIImageGenerator = { prompt, apiKey, model in
            let engine = OpenAIImageEngine(
                apiKey: apiKey,
                model: model,
                baseURL: "https://api.openai.com",
                session: session
            )
            return await engine.generateImage(prompt: prompt)
        }
    }

    init(
        engineFactory: @escaping EngineSetFactory,
        ollamaModelResolver: @escaping OllamaModelResolver,
        openAIProbe: @escaping OpenAIProbe,
        appleAvailability: @escaping AppleAvailabilityProvider,
        openAIImageGenerator: @escaping OpenAIImageGenerator
    ) {
        self.engineFactory = engineFactory
        self.ollamaModelResolver = ollamaModelResolver
        self.openAIProbe = openAIProbe
        self.appleAvailability = appleAvailability
        self.openAIImageGenerator = openAIImageGenerator
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
        configuration.enabled = enabled
        configuration.provider = provider
        configuration.preferredProvider = preferredProvider
        configuration.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIAPIKey = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.openAIModel = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectOllamaModel(baseURL: String) async -> String? {
        await detectOllamaModel(baseURL: baseURL, preferredModel: nil)
    }

    func currentAIStatus(
        ollamaBaseURL: String,
        ollamaModelHint: String?,
        openAIAPIKey: String
    ) async -> (appleOnline: Bool, ollamaOnline: Bool, ollamaModel: String?, openAIOnline: Bool) {
        let appleOnline = appleAvailability()
        let normalized = Self.normalizedOllamaBaseURL(ollamaBaseURL)
        let model = await detectOllamaModel(baseURL: normalized, preferredModel: ollamaModelHint)
        let openAIOnline = await openAIProbe(openAIAPIKey, "https://api.openai.com")
        return (appleOnline, model != nil, model, openAIOnline)
    }

    func generateSmartDMReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
    ) async -> String? {
        guard configuration.enabled else { return nil }

        let systemPrompt = PromptComposer.buildSystemPrompt(
            base: configuration.systemPrompt,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
        return await generateReply(messages: messages, systemPrompt: systemPrompt, stripSpeakerPrefixFor: nil)
    }

    func generateHelpReply(messages: [Message], systemPrompt: String) async -> String? {
        let finalSystemPrompt = PromptComposer.buildSystemPrompt(
            base: systemPrompt,
            serverName: nil,
            channelName: nil,
            wikiContext: nil
        )
        return await generateReply(messages: messages, systemPrompt: finalSystemPrompt, stripSpeakerPrefixFor: nil)
    }

    func generateRuleActionAIReply(
        prompt: String,
        event: VoiceRuleEvent,
        serverName: String?,
        channelName: String
    ) async -> String? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return nil }

        let systemPrompt = PromptComposer.buildSystemPrompt(
            base: configuration.systemPrompt,
            serverName: serverName,
            channelName: channelName,
            wikiContext: nil
        )
        let messages = [
            Message(
                channelID: event.triggerChannelId ?? event.channelId,
                userID: event.triggerUserId,
                username: event.username,
                content: trimmedPrompt,
                role: .user
            )
        ]
        return await generateReply(messages: messages, systemPrompt: systemPrompt, stripSpeakerPrefixFor: event.username)
    }

    func generateOpenAIImage(prompt: String, apiKey: String, model: String) async -> Data? {
        await openAIImageGenerator(prompt, apiKey, model)
    }

    private func generateReply(
        messages: [Message],
        systemPrompt: String,
        stripSpeakerPrefixFor username: String?
    ) async -> String? {
        let finalMessages = PromptComposer.buildMessages(systemPrompt: systemPrompt, history: messages)
        guard finalMessages.contains(where: { $0.role == .user }) else { return nil }

        let engines = engineFactory(configuration, systemPrompt)
        let ordered = orderedEngines(preferred: configuration.preferredProvider, engines: engines)

        // Race all AI engines in parallel — fastest successful response wins.
        // Preference order determines starting order, not priority.
        return await withTaskGroup(of: (Int, String?).self) { group in
            for (index, engine) in ordered.enumerated() {
                group.addTask { [self, username] in
                    let reply = await engine.generate(messages: finalMessages)
                    // Clean the reply
                    guard let cleaned = reply.map({ cleanOutput($0) }), !cleaned.isEmpty else {
                        return (index, nil)
                    }
                    // Strip speaker prefix if needed
                    let normalized: String
                    if let username {
                        normalized = stripLeadingSpeakerPrefix(cleaned, username: username)
                    } else {
                        normalized = cleaned
                    }
                    return (index, normalized.isEmpty ? nil : normalized)
                }
            }
            
            // Collect first non-nil result
            var bestResult: (index: Int, reply: String)? = nil
            
            for await (index, result) in group {
                if let result {
                    bestResult = (index, result)
                    group.cancelAll()
                    break
                }
            }
            
            return bestResult?.reply
        }
    }

    private func orderedEngines(preferred: AIProviderPreference, engines: EngineSet) -> [any AIEngine] {
        switch preferred {
        case .apple:
            return [engines.apple, engines.openAI, engines.ollama]
        case .ollama:
            return [engines.ollama, engines.openAI, engines.apple]
        case .openAI:
            return [engines.openAI, engines.apple, engines.ollama]
        }
    }

    private func detectOllamaModel(baseURL: String, preferredModel: String?) async -> String? {
        await ollamaModelResolver(baseURL, preferredModel)
    }

    private nonisolated func stripLeadingSpeakerPrefix(_ text: String, username: String) -> String {
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

    nonisolated static func normalizedOllamaBaseURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "http://localhost:11434" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed)"
    }

    nonisolated static func isAppleIntelligenceAvailable() -> Bool {
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
}
