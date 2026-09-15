import Foundation
import OSLog
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

#if canImport(FoundationModels)
/// Picks the language model for every Apple Intelligence request.
///
/// On macOS 27 requests go to Private Cloud Compute first and fall back to the
/// on-device model when PCC is unavailable, over quota, offline, or fails for
/// any other reason the on-device model could recover from. Refusals and
/// guardrail violations are not retried — the on-device model would refuse too.
enum FoundationModelRouter {
    enum RouterError: Error, LocalizedError {
        case unavailable

        var errorDescription: String? { "No Apple Intelligence model is available" }
    }

    private static let logger = Logger(subsystem: "com.swiftbot", category: "ai.router")

    static var isAvailable: Bool {
        isPrivateCloudComputeAvailable || SystemLanguageModel.default.availability == .available
    }

    static var isPrivateCloudComputeAvailable: Bool {
        if #available(macOS 27.0, *) {
            return PrivateCloudComputeLanguageModel().isAvailable
        }
        return false
    }

    /// Name of the model requests go to first, or nil when none is available.
    static var activeModelName: String? {
        if isPrivateCloudComputeAvailable { return "Private Cloud Compute" }
        let model = SystemLanguageModel.default
        guard model.availability == .available else { return nil }
        if #available(macOS 27.0, *) {
            return "On-device · \(model.variant.displayName)"
        }
        return "On-device"
    }

    /// Context window of the on-device fallback (4096 before macOS 27). Prompts
    /// are sized to fit it so a request that falls back from PCC still runs.
    static var fallbackContextSize: Int {
        SystemLanguageModel.default.contextSize
    }

    static func instructions(_ text: String) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: text))],
                toolDefinitions: []
            )
        )
    }

    /// Runs `body` against Private Cloud Compute, then the on-device model.
    nonisolated(nonsending) static func run<T>(
        transcript: Transcript,
        _ body: (LanguageModelSession) async throws -> T
    ) async throws -> T {
        if #available(macOS 27.0, *) {
            let pcc = PrivateCloudComputeLanguageModel()
            if pcc.isAvailable {
                do {
                    return try await body(LanguageModelSession(model: pcc, transcript: transcript))
                } catch let error where shouldFallBack(from: error) {
                    logger.notice("Private Cloud Compute failed, using on-device model: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { throw RouterError.unavailable }
        return try await body(LanguageModelSession(model: model, transcript: transcript))
    }

    private static func shouldFallBack(from error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .guardrailViolation, .refusal: return false
            default: return true
            }
        }
        if #available(macOS 27.0, *), let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: return false
            default: return true
            }
        }
        return true
    }
}
#endif

struct AppleIntelligenceEngine: AIEngine {
    let defaultSystemPrompt: String

    func generate(messages: [Message]) async -> String? {
#if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard FoundationModelRouter.isAvailable else { return nil }
            let engineMessages = messages.toEngineMessages()
            guard let lastUserIndex = engineMessages.lastIndex(where: { $0.role == .user }) else { return nil }

            let instructions = engineMessages
                .last(where: { $0.role == .system })?
                .content ?? defaultSystemPrompt
            let prompt = engineMessages[lastUserIndex].content
            guard !prompt.isEmpty else { return nil }

            var transcriptEntries: [Transcript.Entry] = [FoundationModelRouter.instructions(instructions)]
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

            do {
                let raw = try await FoundationModelRouter.run(transcript: Transcript(entries: transcriptEntries)) { session in
                    try await session.respond(to: prompt).content
                }
                let content = cleanAIOutput(raw)
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
        You summarise software, game, driver, and repository update notes for a Discord embed.
        Describe the update itself, not the monitoring tool that found it.
        Start with the product, vendor, game, repository, release, or commit subject when one is present.
        Never use the word Patchy.
        Use the Summary brief and Key extracted changes first, then consult Full notes only for missing context.
        Produce a useful user-facing summary with concrete changes and practical impact, not a generic announcement.
        Include important highlights, fixes, known issues, regressions, UI or GUI changes, compatibility notes, and upgrade impact when present.
        For GitHub commits or releases, call out visible product/UI changes and practical developer-facing changes.
        Output two compact paragraphs or one rich paragraph. Aim for 45-110 words. Do not use bullet points. Do not include a heading. Do not mention that you are an AI.
        """
        let prompt = """
        Update category: \(source)

        Summarise these update notes for users:

        \(trimmed)
        """
        let engine = AppleIntelligenceEngine(defaultSystemPrompt: systemPrompt)
        let messages = [
            Message(channelID: "update-summary", userID: "swiftbot", username: "Release notes", content: systemPrompt, role: .system),
            Message(channelID: "update-summary", userID: "swiftbot", username: "Release notes", content: prompt, role: .user)
        ]

        guard let reply = await engine.generate(messages: messages) else { return nil }
        let cleaned = cleanAIOutput(reply)
        let summary = Self.cleanPatchySummary(cleaned)
        return Self.isUsefulPatchySummary(summary) ? summary : nil
    }

    nonisolated static func cleanPatchySummary(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        let disallowedPrefixes = [
            "patchy reports ",
            "patchy has detected ",
            "patchy detected ",
            "patchy found ",
            "patchy says ",
            "patchy summarises ",
            "patchy summarizes "
        ]
        let lowered = cleaned.lowercased()
        for prefix in disallowedPrefixes where lowered.hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }

        guard !cleaned.lowercased().hasPrefix("patchy") else { return "" }
        return cleaned
    }

    nonisolated static func isUsefulPatchySummary(_ summary: String) -> Bool {
        let cleaned = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }
        let words = cleaned
            .split { !$0.isLetter && !$0.isNumber }
        guard words.count >= 24 else { return false }

        let lowered = cleaned.lowercased()
        let vagueOpeners = [
            "this update",
            "this release",
            "the update",
            "the release",
            "a new update",
            "an update"
        ]
        guard !vagueOpeners.contains(where: { lowered.hasPrefix($0) }) else { return false }
        return true
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
        return FoundationModelRouter.isAvailable
#else
        return false
#endif
    }

    /// Name of the model Apple Intelligence requests go to first, for display.
    nonisolated static func activeAIModelName() -> String? {
#if canImport(FoundationModels)
        return FoundationModelRouter.activeModelName
#else
        return nil
#endif
    }
}
