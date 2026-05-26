// MARK: - Archived Bug Tracker & Bug Report Features (Deprecated / Removed)
// Preserved here in case we ever want to bring these features back.
//
// Original files touched:
// - AppModel+Commands.swift
// - Services/CommandProcessor.swift
// - Models/BotStateModels.swift
// - AppModel+SlashCommandHelpers.swift
// - HelpEngine.swift

import Foundation

// MARK: - Enums & Models from BotStateModels.swift
enum BugStatus: String, Codable, Hashable {
    case new = "New"
    case workingOn = "Working On"
    case inProgress = "In Progress"
    case blocked = "Blocked"
    case resolved = "Resolved"

    var emoji: String {
        switch self {
        case .new:
            return "🐞"
        case .workingOn:
            return "🔧"
        case .inProgress:
            return "🟡"
        case .blocked:
            return "⛔"
        case .resolved:
            return "✅"
        }
    }
}

struct BugEntry: Hashable, Codable {
    let bugMessageID: String
    let sourceMessageID: String
    let channelID: String
    let guildID: String
    let reporterID: String
    let createdBy: String
    var status: BugStatus
    var timestamp: Date
}

// MARK: - Extension Methods from AppModel+Commands.swift
extension AppModel {
    var bugStatusEmojis: [String] {
        [BugStatus.new.emoji, BugStatus.workingOn.emoji, BugStatus.inProgress.emoji, BugStatus.blocked.emoji, BugStatus.resolved.emoji]
    }

    var bugStatusByEmoji: [String: BugStatus] {
        let raw: [String: BugStatus] = [
            BugStatus.new.emoji: .new,
            BugStatus.workingOn.emoji: .workingOn,
            BugStatus.inProgress.emoji: .inProgress,
            BugStatus.blocked.emoji: .blocked,
            BugStatus.resolved.emoji: .resolved
        ]
        var normalized = raw
        for (emoji, status) in raw {
            normalized[normalizedReactionEmojiName(emoji)] = status
        }
        return normalized
    }

    // Prefix `@swiftbot bug` command handler
    func handleBugTrackCommand(raw: [String: DiscordJSON], username: String, responseChannelId: String) async {
        let serverName = commandServerName(from: raw)
        guard settings.bugTrackingEnabled else {
            return
        }

        guard let guildId = guildId(from: raw) else {
            let ok = await send(responseChannelId, "⚠️ Bug tracking only works in server channels.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard await canRunDebugCommand(raw: raw) else {
            let ok = await send(responseChannelId, "⛔ `@swiftbot bug` is restricted to server owners or admins.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard case let .object(messageReference)? = raw["message_reference"],
              case let .string(sourceMessageID)? = messageReference["message_id"] else {
            let ok = await send(responseChannelId, "⚠️ Reply to a message with `@swiftbot bug` to track it.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let sourceChannelID: String = {
            if case let .string(id)? = messageReference["channel_id"] { return id }
            return responseChannelId
        }()

        let sourceMessage: [String: DiscordJSON]? = {
            if case let .object(ref)? = raw["referenced_message"] {
                return ref
            }
            return nil
        }()
        let resolvedSourceMessage: [String: DiscordJSON]?
        if let sourceMessage {
            resolvedSourceMessage = sourceMessage
        } else {
            resolvedSourceMessage = await fetchMessage(channelId: sourceChannelID, messageId: sourceMessageID)
        }

        guard let sourceMessage = resolvedSourceMessage else {
            let ok = await send(responseChannelId, "❌ Couldn't load the referenced message.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        guard let bugChannelID = bugTrackerChannelID(for: guildId) else {
            let ok = await send(responseChannelId, "❌ Couldn't find #swiftbot-dev in this server.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let reporterID: String = {
            guard case let .object(author)? = sourceMessage["author"],
                  case let .string(id)? = author["id"] else {
                return "unknown-user"
            }
            return id
        }()
        let sourceText: String = {
            if case let .string(text)? = sourceMessage["content"] { return text }
            return ""
        }()
        let cleanedSourceText = bugPreviewText(from: sourceText)
        let jumpLink = "https://discord.com/channels/\(guildId)/\(sourceChannelID)/\(sourceMessageID)"
        let bugMessage = """
        🐞 SwiftBot Bug
        Reporter: <@\(reporterID)>
        Channel: <#\(sourceChannelID)>
        Message:
        "\(cleanedSourceText)"
        Status: \(BugStatus.new.rawValue)
        Link: \(jumpLink)
        """

        guard let bugMessageID = await sendMessageReturningID(channelId: bugChannelID, content: bugMessage) else {
            let ok = await send(responseChannelId, "❌ Failed to create bug report in <#\(bugChannelID)>.")
            await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
            return
        }

        let creatorID = authorId(from: raw) ?? username
        bugEntriesByMessageID[bugMessageID] = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: sourceMessageID,
            channelID: sourceChannelID,
            guildID: guildId,
            reporterID: reporterID,
            createdBy: creatorID,
            status: .new,
            timestamp: Date()
        )

        let didPin = await retryBugOperation {
            await pinMessage(channelId: bugChannelID, messageId: bugMessageID)
        }
        let didSeedReactions = await seedBugStatusReactions(channelID: bugChannelID, messageID: bugMessageID)

        let threadTitle = bugThreadTitle(from: cleanedSourceText)
        _ = await createThreadFromMessage(channelId: bugChannelID, messageId: bugMessageID, name: threadTitle)
        await postBugThreadLegend(bugChannelID: bugChannelID, bugMessageID: bugMessageID)

        logs.append(
            "🐞 BugEntry created bugMessageID=\(bugMessageID) sourceMessageID=\(sourceMessageID) guildID=\(guildId) reporterID=\(reporterID) createdBy=\(creatorID) status=\(BugStatus.new.rawValue)"
        )

        var responseLines: [String] = ["✅ Bug tracked in <#\(bugChannelID)>."]
        if didPin {
            responseLines.append("📌 Pinned successfully.")
        } else {
            responseLines.append("⚠️ I couldn't pin the bug message. Please grant me `Manage Messages` in <#\(bugChannelID)> so I can pin/unpin bug reports.")
        }
        if !didSeedReactions {
            responseLines.append("⚠️ I couldn't add status reactions. Please grant me `Add Reactions` and `Read Message History` in <#\(bugChannelID)>.")
        }
        let ok = await send(responseChannelId, responseLines.joined(separator: "\n"))
        if !didPin {
            logs.append("⚠️ Bug pin failed for message \(bugMessageID) in channel \(bugChannelID). Likely missing `Manage Messages` permission.")
        }
        if !didSeedReactions {
            logs.append("⚠️ Bug reaction seed failed for message \(bugMessageID) in channel \(bugChannelID). Likely missing `Add Reactions` or `Read Message History` permission.")
        }
        await appendBugCommandLog(user: username, server: serverName, command: "@swiftbot bug", channel: responseChannelId, ok: ok)
    }

    // Slash command /logabug handler
    func handleLogABugSlash(raw: [String: DiscordJSON], username: String, channelId: String, errorText: String) async -> (ok: Bool, message: String) {
        guard settings.bugTrackingEnabled else {
            return (false, "Bug tracking is disabled in command settings.")
        }

        guard let guildId = guildId(from: raw) else {
            return (false, "`/logabug` only works in a server channel.")
        }

        guard await canRunDebugCommand(raw: raw) else {
            return (false, "`/logabug` is restricted to server owners or admins.")
        }

        guard let bugChannelID = bugTrackerChannelID(for: guildId) else {
            return (false, "Couldn't find #swiftbot-dev in this server.")
        }

        let reporterID = authorId(from: raw) ?? "unknown-user"
        let sourceMessageID = "manual-\(UUID().uuidString)"
        let cleanedSourceText = bugPreviewText(from: errorText)
        let bugMessage = """
        🐞 SwiftBot Bug
        Reporter: <@\(reporterID)>
        Channel: <#\(channelId)>
        Message:
        "\(cleanedSourceText)"
        Status: \(BugStatus.new.rawValue)
        Link: Manual log via /logabug
        """

        guard let bugMessageID = await sendMessageReturningID(channelId: bugChannelID, content: bugMessage) else {
            return (false, "Failed to create bug report in <#\(bugChannelID)>.")
        }

        bugEntriesByMessageID[bugMessageID] = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: sourceMessageID,
            channelID: channelId,
            guildID: guildId,
            reporterID: reporterID,
            createdBy: reporterID,
            status: .new,
            timestamp: Date()
        )

        let didPin = await retryBugOperation {
            await pinMessage(channelId: bugChannelID, messageId: bugMessageID)
        }
        let didSeedReactions = await seedBugStatusReactions(channelID: bugChannelID, messageID: bugMessageID)
        let threadTitle = bugThreadTitle(from: cleanedSourceText)
        _ = await createThreadFromMessage(channelId: bugChannelID, messageId: bugMessageID, name: threadTitle)
        await postBugThreadLegend(bugChannelID: bugChannelID, bugMessageID: bugMessageID)

        logs.append(
            "🐞 BugEntry created via /logabug bugMessageID=\(bugMessageID) guildID=\(guildId) reporterID=\(reporterID) status=\(BugStatus.new.rawValue)"
        )

        var lines: [String] = ["Created bug report in <#\(bugChannelID)>."]
        if didPin {
            lines.append("📌 Pinned successfully.")
        } else {
            lines.append("⚠️ I couldn't pin it. Please grant `Manage Messages` in <#\(bugChannelID)>.")
        }
        if !didSeedReactions {
            lines.append("⚠️ I couldn't add status reactions. Please grant `Add Reactions` and `Read Message History` in <#\(bugChannelID)>.")
        }
        return (true, lines.joined(separator: "\n"))
    }

    func handleBugReactionAdd(raw: [String: DiscordJSON]) async {
        guard settings.bugTrackingEnabled else { return }
        guard case let .string(messageID)? = raw["message_id"],
              case let .string(channelID)? = raw["channel_id"],
              case let .string(userID)? = raw["user_id"],
              case let .object(emoji)? = raw["emoji"],
              case let .string(emojiName)? = emoji["name"]
        else { return }

        if let botUserId, userID == botUserId {
            return
        }

        let normalizedEmoji = normalizedReactionEmojiName(emojiName)
        let bugStatus = bugStatusByEmoji[emojiName] ?? bugStatusByEmoji[normalizedEmoji]

        if let bugStatus, bugEntriesByMessageID[messageID] != nil {
            await handleBugStatusReaction(raw: raw, messageID: messageID, channelID: channelID, userID: userID, targetStatus: bugStatus)
            return
        }

        guard bugStatus != nil else { return }

        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = message["content"] else {
            return
        }
        let isBugMessage = content.contains("🐞 SwiftBot Bug")

        if isBugMessage, let bugStatus {
            await handleBugStatusReaction(raw: raw, messageID: messageID, channelID: channelID, userID: userID, targetStatus: bugStatus)
            return
        }
    }

    func handleBugStatusReaction(
        raw: [String: DiscordJSON],
        messageID: String,
        channelID: String,
        userID: String,
        targetStatus: BugStatus
    ) async {
        let guildID: String? = {
            if case let .string(id)? = raw["guild_id"] { return id }
            return nil
        }()
        guard var entry = await loadOrCreateBugEntry(
            bugMessageID: messageID,
            channelID: channelID,
            guildID: guildID,
            fallbackCreatedBy: userID
        ) else { return }

        entry.status = targetStatus
        entry.timestamp = Date()
        bugEntriesByMessageID[messageID] = entry

        let reactionsReady = await seedBugStatusReactions(channelID: channelID, messageID: messageID)
        let contentUpdated = await updateBugMessageStatus(channelID: channelID, messageID: messageID, status: targetStatus)
        await postBugThreadStatusNote(
            bugChannelID: channelID,
            bugMessageID: messageID,
            actorUserID: userID,
            status: targetStatus
        )

        var statusOK = contentUpdated && reactionsReady
        if targetStatus == .resolved {
            let unpinned = await unpinMessage(channelId: channelID, messageId: messageID)
            if unpinned {
                _ = await send(channelID, "✅ Bug resolved — unpinned")
            }
            statusOK = statusOK && unpinned
        }

        let reactorName = await displayNameForUserID(userID)
        let serverName = connectedServers[entry.guildID] ?? "Server \(entry.guildID.suffix(4))"
        await appendBugCommandLog(
            user: reactorName,
            server: serverName,
            command: "@swiftbot bug status \(targetStatus.rawValue)",
            channel: channelID,
            ok: statusOK
        )
        logs.append("🐞 BugEntry updated bugMessageID=\(messageID) status=\(targetStatus.rawValue) by=\(userID)")
    }

    func loadOrCreateBugEntry(
        bugMessageID: String,
        channelID: String,
        guildID: String?,
        fallbackCreatedBy: String
    ) async -> BugEntry? {
        if let existing = bugEntriesByMessageID[bugMessageID] {
            return existing
        }

        guard let message = await fetchMessage(channelId: channelID, messageId: bugMessageID),
              case let .string(content)? = message["content"],
              content.contains("🐞 SwiftBot Bug")
        else {
            return nil
        }

        let parsedSourceMessageID = parseBugSourceMessageID(from: content)
        let parsedReporterID = parseBugReporterID(from: content) ?? "unknown-user"
        let parsedStatus = parseBugStatus(from: content) ?? .new
        let resolvedGuildID: String = guildID
            ?? {
                if case let .string(id)? = message["guild_id"] { return id }
                return "unknown-guild"
            }()
        let sourceChannelID = parseBugSourceChannelID(from: content) ?? channelID

        let reconstructed = BugEntry(
            bugMessageID: bugMessageID,
            sourceMessageID: parsedSourceMessageID ?? bugMessageID,
            channelID: sourceChannelID,
            guildID: resolvedGuildID,
            reporterID: parsedReporterID,
            createdBy: fallbackCreatedBy,
            status: parsedStatus,
            timestamp: Date()
        )
        bugEntriesByMessageID[bugMessageID] = reconstructed
        return reconstructed
    }

    func appendBugCommandLog(user: String, server: String, command: String, channel: String, ok: Bool) async {
        let executionDetails = await commandExecutionDetails(for: "bug")
        addCommandLogEntry(CommandLogEntry(
            time: Date(),
            user: user,
            server: server,
            command: command,
            channel: channel,
            executionRoute: executionDetails.route,
            executionNode: executionDetails.node,
            ok: ok
        ))
    }

    func bugTrackerChannelID(for guildID: String) -> String? {
        let channels = availableTextChannelsByServer[guildID] ?? []
        if let exact = channels.first(where: { $0.name.caseInsensitiveCompare("swiftbot-dev") == .orderedSame }) {
            return exact.id
        }
        return nil
    }

    func bugPreviewText(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "(no text content)"
        }
        let collapsed = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let reducedSpaces = collapsed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return reducedSpaces.count > 1200 ? String(reducedSpaces.prefix(1200)) + "..." : reducedSpaces
    }

    func bugThreadTitle(from preview: String) -> String {
        let base = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Bug: "
        guard !base.isEmpty else { return "\(prefix)Untitled" }
        let limit = max(1, 60 - prefix.count)
        return prefix + String(base.prefix(limit))
    }

    func seedBugStatusReactions(channelID: String, messageID: String) async -> Bool {
        var allSucceeded = true
        for emoji in bugStatusEmojis {
            let added = await retryBugOperation {
                await addReaction(channelId: channelID, messageId: messageID, emoji: emoji)
            }
            allSucceeded = allSucceeded && added
        }
        return allSucceeded
    }

    func retryBugOperation(maxAttempts: Int = 3, delayNanoseconds: UInt64 = 250_000_000, operation: () async -> Bool) async -> Bool {
        for attempt in 1...maxAttempts {
            if await operation() {
                return true
            }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }
        return false
    }

    func updateBugMessageStatus(channelID: String, messageID: String, status: BugStatus) async -> Bool {
        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(currentContent)? = message["content"] else {
            return false
        }
        let updated = replacingBugStatusLine(in: currentContent, status: status.rawValue)
        return await editMessage(channelId: channelID, messageId: messageID, content: updated)
    }

    func replacingBugStatusLine(in text: String, status: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var found = false
        let rewritten = lines.map { line -> String in
            if line.hasPrefix("Status:") {
                found = true
                return "Status: \(status)"
            }
            return line
        }
        if found {
            return rewritten.joined(separator: "\n")
        }
        return text + "\nStatus: \(status)"
    }

    // Slash command /bugreport text builder
    func bugReportText(for raw: [String: DiscordJSON]) -> String {
        guard let guildID = guildId(from: raw) else {
            return "⚠️ `/bugreport` only works in a server channel."
        }

        let statuses: [BugStatus] = [.new, .workingOn, .inProgress, .blocked, .resolved]
        let entries = bugEntriesByMessageID.values.filter { $0.guildID == guildID }
        let grouped = Dictionary(grouping: entries, by: \.status)

        var lines: [String] = ["🐞 SwiftBot Bug Report"]
        lines.append("Total: \(entries.count)")
        for status in statuses {
            lines.append("\(status.emoji) \(status.rawValue): \(grouped[status]?.count ?? 0)")
        }
        return lines.joined(separator: "\n")
    }

    func parseBugStatus(from content: String) -> BugStatus? {
        guard let statusLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Status:") })
        else { return nil }
        let raw = statusLine.replacingOccurrences(of: "Status:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BugStatus(rawValue: raw)
    }

    func parseBugReporterID(from content: String) -> String? {
        guard let reporterLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Reporter:") })
        else { return nil }
        guard let start = reporterLine.range(of: "<@")?.upperBound,
              let end = reporterLine[start...].firstIndex(of: ">") else {
            return nil
        }
        let userID = String(reporterLine[start..<end])
        return userID.allSatisfy(\.isNumber) ? userID : nil
    }

    func parseBugSourceChannelID(from content: String) -> String? {
        guard let channelLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Channel:") })
        else { return nil }
        guard let start = channelLine.range(of: "<#")?.upperBound,
              let end = channelLine[start...].firstIndex(of: ">") else {
            return nil
        }
        let channelID = String(channelLine[start..<end])
        return channelID.allSatisfy(\.isNumber) ? channelID : nil
    }

    func parseBugSourceMessageID(from content: String) -> String? {
        guard let linkLine = content
            .components(separatedBy: .newlines)
            .first(where: { $0.hasPrefix("Link:") })
        else { return nil }
        let components = linkLine.split(separator: "/").map(String.init)
        guard let last = components.last, last.allSatisfy(\.isNumber) else { return nil }
        return last
    }

    func postBugThreadStatusNote(
        bugChannelID: String,
        bugMessageID: String,
        actorUserID: String,
        status: BugStatus
    ) async {
        let threadID = await ensureBugThreadChannelID(bugChannelID: bugChannelID, bugMessageID: bugMessageID)
        guard let threadID else { return }
        let note = "📝 <@\(actorUserID)> marked this issue as **\(status.rawValue)**."
        _ = await send(threadID, note)
    }

    func postBugThreadLegend(bugChannelID: String, bugMessageID: String) async {
        guard let threadID = await ensureBugThreadChannelID(bugChannelID: bugChannelID, bugMessageID: bugMessageID) else { return }
        let legend = """
        🧭 **Bug Status Reactions**
        🐞 New
        🔧 Working On
        🟡 In Progress
        ⛔ Blocked
        ✅ Resolved

        Add one of these reactions on the parent bug message to update status.
        """
        _ = await send(threadID, legend)
    }

    func ensureBugThreadChannelID(bugChannelID: String, bugMessageID: String) async -> String? {
        if let message = await fetchMessage(channelId: bugChannelID, messageId: bugMessageID),
           case let .object(thread)? = message["thread"],
           case let .string(threadID)? = thread["id"],
           !threadID.isEmpty {
            return threadID
        }

        let threadCreated = await createThreadFromMessage(
            channelId: bugChannelID,
            messageId: bugMessageID,
            name: "Bug Thread"
        )
        guard threadCreated else { return nil }

        if let refreshed = await fetchMessage(channelId: bugChannelID, messageId: bugMessageID),
           case let .object(thread)? = refreshed["thread"],
           case let .string(threadID)? = thread["id"],
           !threadID.isEmpty {
            return threadID
        }
        return nil
    }
}
