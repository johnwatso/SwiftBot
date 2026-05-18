import Foundation
import FoundationModels
import OSLog

/// Turns natural-language input ("when someone joins voice, log it") into a
/// fully-formed `Automations.Rule` using on-device Apple Intelligence.
///
/// Few-shot examples come from `Automations.examples`. The model is told
/// about available Discord context (server name, channels, roles) so it can
/// pick real IDs.
@MainActor
final class AutomationDrafter {

    struct ServerContext {
        var guildName: String?
        var guildId: String?
        /// Text channels (id, name) — for message / reaction / log filters.
        var textChannels: [(id: String, name: String)]
        /// Voice channels (id, name) — for voice triggers and moveVoice steps.
        var voiceChannels: [(id: String, name: String)]
        var roles: [(id: String, name: String)]

        /// Combined list (text + voice) for places where channel type doesn't matter.
        var channels: [(id: String, name: String)] { textChannels + voiceChannels }

        static let empty = ServerContext(guildName: nil, guildId: nil,
                                         textChannels: [], voiceChannels: [], roles: [])
    }

    enum DraftError: Error, LocalizedError {
        case unavailable(String)
        case generationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return "Apple Intelligence is unavailable: \(why)"
            case .generationFailed(let why): return "Could not draft a rule: \(why)"
            }
        }
    }

    private let logger = Logger(subsystem: "com.swiftbot", category: "automations.drafter")

    /// True when on-device Apple Intelligence can produce a rule.
    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    var unavailabilityReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "this device does not support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off in System Settings"
        case .unavailable(.modelNotReady):
            return "the on-device model is still downloading"
        case .unavailable(let other):
            return "\(other)"
        }
    }

    // MARK: - Draft

    func draft(prompt: String, context: ServerContext = .empty) async throws -> Automations.Rule {
        guard isAvailable else {
            throw DraftError.unavailable(unavailabilityReason ?? "unknown")
        }

        let session = LanguageModelSession(instructions: Self.systemInstructions(context: context))

        do {
            let response = try await session.respond(
                to: prompt,
                generating: Automations.Rule.self
            )
            var rule = response.content
            // Ensure a fresh ID — the model may copy an example ID.
            rule.id = UUID().uuidString
            // Ensure each step has a unique ID for SwiftUI list identity.
            rule.steps = rule.steps.map { step in
                var s = step
                s.id = UUID().uuidString
                return s
            }
            return rule
        } catch {
            logger.error("Drafting failed: \(error.localizedDescription)")
            throw DraftError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - System prompt

    private static func systemInstructions(context: ServerContext) -> String {
        var lines: [String] = []

        // Tight: the on-device model has ~4K context. Keep this small.
        lines.append("""
        You turn a user's request into one Discord automation Rule.
        Pick trigger.kind. Add filters[] only for conditions the user explicitly mentioned.
        filterLogic is 'all' (AND) unless the user says "or any of".
        Each filter has kind + the param it uses (channelIds, roleIds, userIds, text, textValues, boolValue, intValue).
        Steps: usually 1. For sendMessage, set EITHER content OR aiPrompt.
        Variables in text: {username} {channelName} {message} {duration} {guildName}.
        Name: 2-4 words.
        """)

        // Cap channel/role hints aggressively — these eat tokens fastest.
        if !context.channels.isEmpty {
            let sample = context.channels.prefix(8).map { "\($0.id)=\($0.name)" }.joined(separator: ", ")
            lines.append("Channels: \(sample)")
        }
        if !context.roles.isEmpty {
            let sample = context.roles.prefix(6).map { "\($0.id)=\($0.name)" }.joined(separator: ", ")
            lines.append("Roles: \(sample)")
        }

        return lines.joined(separator: "\n")
    }
}
