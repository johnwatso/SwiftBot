import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol AIEngine: Sendable {
    func generate(messages: [Message]) async -> String?
}

enum EngineMessageRole: String {
    case system
    case user
    case assistant
}

struct EngineMessage {
    let role: EngineMessageRole
    let content: String
}

extension Array where Element == Message {
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

func cleanAIOutput(_ raw: String) -> String {
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
                let content = cleanAIOutput(response.content)
                return content.isEmpty ? nil : content
            } catch {
                return nil
            }
        }
#endif
        return nil
    }
}

actor DiscordAIService {
    struct Configuration: Sendable {
        var enabled = false
        var systemPrompt = ""
    }

    typealias EngineFactory = @Sendable (String) -> any AIEngine
    typealias AppleAvailabilityProvider = @Sendable () -> Bool

    private var configuration = Configuration()
    private let engineFactory: EngineFactory
    private let appleAvailability: AppleAvailabilityProvider

    init(session: URLSession = URLSession(configuration: .default)) {
        self.engineFactory = { systemPrompt in
            AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        }
        self.appleAvailability = { Self.isAppleIntelligenceAvailable() }
        _ = session // accepted for API parity with the prior multi-provider init
    }

    init(
        engineFactory: @escaping EngineFactory,
        appleAvailability: @escaping AppleAvailabilityProvider
    ) {
        self.engineFactory = engineFactory
        self.appleAvailability = appleAvailability
    }

    func configureLocalAIDMReplies(enabled: Bool, systemPrompt: String) {
        configuration.enabled = enabled
        configuration.systemPrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func currentAIStatus() async -> Bool {
        appleAvailability()
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

    func generateStepAIReply(
        prompt: String,
        event: SwiftBotEvent,
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

    func summarizePatchyUpdateWithAppleIntelligence(updateText: String, source: String) async -> String? {
        let trimmed = updateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, appleAvailability() else { return nil }

        let systemPrompt = """
        You summarise Patchy update checks for a Discord embed.
        Produce an overall user-facing blurb, not just fixes.
        Include important highlights, fixes, known issues, regressions, UI or GUI changes, compatibility notes, and upgrade impact when present.
        For GitHub commits or releases, call out visible product/UI changes and practical developer-facing changes.
        Output one or two short paragraphs, maximum. Do not use bullet points. Do not include a heading. Do not mention that you are an AI.
        """
        let prompt = """
        Summarise this \(source) update:

        \(trimmed)
        """
        let engine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let messages = [
            Message(channelID: "patchy", userID: "swiftbot", username: "Patchy", content: systemPrompt, role: .system),
            Message(channelID: "patchy", userID: "swiftbot", username: "Patchy", content: prompt, role: .user)
        ]

        guard let reply = await engine.generate(messages: messages) else { return nil }
        let cleaned = cleanAIOutput(reply)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Sweep digest — on-device summarisation of a stretch of channel activity
    /// using Apple Intelligence. Returns nil if Apple Intelligence isn't
    /// available or the input is empty.
    func summarizeSweepDigest(channelName: String, lines: [String]) async -> String? {
        let body = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard !body.isEmpty, appleAvailability() else { return nil }

        let systemPrompt = """
        You condense noisy Discord channel activity into a calm, scannable summary.
        Group recurring patterns (driver releases, voice join/leave, repeated alerts) into a single line each.
        Drop pleasantries and routine acknowledgements.
        Output two or three short sentences, plain prose, no bullet points, no heading, no mention of being an AI.
        """
        let prompt = """
        Summarise the recent activity from #\(channelName):

        \(body)
        """
        let engine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let messages = [
            Message(channelID: "sweep", userID: "swiftbot", username: "Sweep", content: systemPrompt, role: .system),
            Message(channelID: "sweep", userID: "swiftbot", username: "Sweep", content: prompt, role: .user)
        ]

        guard let reply = await engine.generate(messages: messages) else { return nil }
        let cleaned = cleanAIOutput(reply)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func generateReply(
        messages: [Message],
        systemPrompt: String,
        stripSpeakerPrefixFor username: String?
    ) async -> String? {
        let finalMessages = PromptComposer.buildMessages(systemPrompt: systemPrompt, history: messages)
        guard finalMessages.contains(where: { $0.role == .user }) else { return nil }

        let engine = engineFactory(systemPrompt)
        let raw = await engine.generate(messages: finalMessages)
        guard let cleaned = raw.map({ cleanAIOutput($0) }), !cleaned.isEmpty else { return nil }
        if let username {
            let normalized = stripLeadingSpeakerPrefix(cleaned, username: username)
            return normalized.isEmpty ? nil : normalized
        }
        return cleaned
    }

    nonisolated private func stripLeadingSpeakerPrefix(_ text: String, username: String) -> String {
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
