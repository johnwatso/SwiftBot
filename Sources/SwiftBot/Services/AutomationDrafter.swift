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

        // Pull any channels and roles the user explicitly mentioned by name
        // forward in the context list, so they survive the prefix(8)/prefix(6)
        // truncation when the prompt is built.
        let prioritised = Self.prioritiseContext(context, basedOn: prompt)

        let session = LanguageModelSession(instructions: Self.systemInstructions(context: prioritised))

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
            // Fix common drafter mistakes — channel resolution, empty filters.
            Self.postProcess(&rule, context: context)
            return rule
        } catch {
            logger.error("Drafting failed: \(error.localizedDescription)")
            throw DraftError.generationFailed(error.localizedDescription)
        }
    }

    // MARK: - Post-processing
    //
    // The on-device model regularly makes a few specific mistakes that we
    // can clean up deterministically:
    //
    //   • Mentions a channel by name in the message body (`#noti-bot`) but
    //     forgets to set sendTarget=specificChannel + channelId.
    //   • Adds an empty `inChannel` (or other list-typed) filter with no
    //     actual values, which would block the rule from ever firing.
    //   • Picks `sameChannel` for voice triggers, where "same channel" is
    //     a voice channel — the message would never get posted.

    private static func postProcess(_ rule: inout Automations.Rule, context: ServerContext) {
        // Build a lower-cased name → id lookup across all channels.
        var channelsByName: [String: (id: String, isVoice: Bool)] = [:]
        for c in context.textChannels  { channelsByName[c.name.lowercased()] = (c.id, false) }
        for c in context.voiceChannels { channelsByName[c.name.lowercased()] = (c.id, true)  }

        for i in rule.steps.indices where rule.steps[i].kind == .sendMessage {
            var step = rule.steps[i]

            // If a channel reference like "#noti-bot" appears in the
            // content or aiPrompt and we haven't already targeted a
            // specific channel, redirect the step to that channel.
            let inputs = [step.content ?? "", step.aiPrompt ?? ""]
            for text in inputs {
                guard let match = firstHashRef(in: text) else { continue }
                guard let resolved = channelsByName[match.lowercased()], !resolved.isVoice else { continue }
                if step.sendTarget != .specificChannel || (step.channelId ?? "").isEmpty {
                    step.sendTarget = .specificChannel
                    step.channelId  = resolved.id
                }
                break
            }

            // Voice triggers + sameChannel is almost always wrong (the
            // "same channel" is a voice channel, no text gets posted).
            // If we can find any text channel in context, prefer that.
            if isVoiceTrigger(rule.trigger.kind),
               (step.sendTarget == nil || step.sendTarget == .sameChannel),
               step.channelId == nil || step.channelId?.isEmpty == true,
               let firstText = context.textChannels.first {
                step.sendTarget = .specificChannel
                step.channelId = firstText.id
            }

            rule.steps[i] = step
        }

        // Drop filters that carry no actual constraint values.
        rule.filters = rule.filters.filter(Self.filterHasValue)
    }

    /// Returns the bare channel name (without the `#`) of the first
    /// `#channelname` pattern in `text`, or nil if none.
    private static func firstHashRef(in text: String) -> String? {
        // Discord channel names: a-z, 0-9, -, _ (lowercase enforced)
        guard let range = text.range(of: #"#[a-zA-Z0-9_-]+"#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst())
    }

    private static func isVoiceTrigger(_ kind: Automations.TriggerKind) -> Bool {
        switch kind {
        case .userJoinedVoice, .userLeftVoice, .userMovedVoice: return true
        default: return false
        }
    }

    // MARK: - Context prioritisation

    /// Reorders `context.textChannels`, `context.voiceChannels`, and
    /// `context.roles` so anything the user directly named (e.g. `#noti-bot`
    /// or `@Muted`) lands at the front. The prompt-builder still slices the
    /// first 8 channels / 6 roles, but the relevant ones survive.
    private static func prioritiseContext(_ ctx: ServerContext, basedOn prompt: String) -> ServerContext {
        let hashNames = matches(of: #"#[a-zA-Z0-9_-]+"#, in: prompt)
            .map { String($0.dropFirst()).lowercased() }
        let atNames = matches(of: #"@[a-zA-Z0-9_-]+"#, in: prompt)
            .map { String($0.dropFirst()).lowercased() }

        let text = bringToFront(ctx.textChannels, matching: hashNames)
        let voice = bringToFront(ctx.voiceChannels, matching: hashNames)
        let roles = bringToFront(ctx.roles, matching: atNames)

        return ServerContext(
            guildName: ctx.guildName,
            guildId: ctx.guildId,
            textChannels: text,
            voiceChannels: voice,
            roles: roles
        )
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func bringToFront(
        _ items: [(id: String, name: String)],
        matching wanted: [String]
    ) -> [(id: String, name: String)] {
        guard !wanted.isEmpty else { return items }
        let wantedSet = Set(wanted)
        let (hit, miss) = items.partitioned { wantedSet.contains($0.name.lowercased()) }
        return hit + miss
    }

    private static func filterHasValue(_ f: Automations.Filter) -> Bool {
        switch f.kind {
        case .inChannel:                return !(f.channelIds?.isEmpty ?? true)
        case .userIsOneOf:              return !(f.userIds?.isEmpty ?? true)
        case .userHasAnyRole,
             .userHasAllRoles,
             .userHasNoneOfRoles:       return !(f.roleIds?.isEmpty ?? true)
        case .messageContainsAny:       return !(f.textValues?.isEmpty ?? true)
        case .messageContains,
             .messageEquals,
             .messageDoesNotContain,
             .messageMatchesRegex,
             .reactionEmoji,
             .mediaSource:              return !((f.text ?? "").isEmpty)
        case .messageIsReply,
             .directMessage,
             .fromBot:                  return f.boolValue != nil
        case .minVoiceDurationSeconds:  return (f.intValue ?? 0) > 0
        case .messageContainsSpamLink:  return true
        case .messageCapsPercentage,
             .messageMentionsCount:     return (f.intValue ?? 0) > 0
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
        Do NOT add a filter with an empty list/value — only add a filter when you have a concrete value for it.

        Steps: usually 1. For sendMessage, set EITHER content OR aiPrompt.

        CHANNEL TARGETING — when the user says "ping #channel", "post to #channel",
        "in #channel", or "to #channel", they mean the rule's OUTPUT destination,
        not a filter. Set sendTarget=specificChannel and channelId=<the matching ID
        from the Channels list below>. Do NOT put "#channel" into the message body.
        Write a meaningful message body (e.g. "{username} joined #{channelName}").

        VOICE TRIGGERS — for userJoinedVoice / userLeftVoice / userMovedVoice the
        "same channel" is a VOICE channel, so sameChannel won't post text. Use
        sendTarget=specificChannel and pick a text channel for the destination.

        VARIABLES — the ONLY tokens allowed in content / aiPrompt / logText are:
          {username}    user's display name
          {userMention} user @-mention (renders as a clickable mention)
          {userId}      raw user ID
          {channelName} channel name
          {channelId}   channel ID
          {guildName}   server name
          {guildId}     server ID
          {message}     the triggering message text (messageCreated trigger only)
          {messageId}   message ID
          {duration}    voice session duration like "5m 12s" (voice triggers only)
          {mediaFile}   media file name (mediaAdded trigger only)
          {mediaSource} media source (mediaAdded trigger only)
        DO NOT use {user}, {server}, {memberCount}, {role}, {time}, or any other token — they will render literally.

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

private extension Array {
    /// Splits the array into (matches, rest) preserving original order on
    /// each side. Used by the drafter's context-prioritisation pass to keep
    /// user-named channels/roles at the front of the prompt context.
    func partitioned(by belongsToFirst: (Element) -> Bool) -> (first: [Element], rest: [Element]) {
        var first: [Element] = []
        var rest: [Element] = []
        for element in self {
            if belongsToFirst(element) {
                first.append(element)
            } else {
                rest.append(element)
            }
        }
        return (first, rest)
    }
}
