// MARK: - Archived Feature Request Feature (Deprecated / Removed)
// Preserved here in case we ever want to bring this feature back.
//
// Original files touched:
// - AppModel+Commands.swift
// - Services/CommandProcessor.swift
// - AppModel+SlashCommandHelpers.swift

import Foundation

extension AppModel {
    var featureStatusEmojiDescriptions: [(emoji: String, label: String)] {
        [
            ("💡", "New Request"),
            ("🧪", "Needs Review"),
            ("🗓️", "Planned"),
            ("🚧", "In Progress"),
            ("✅", "Implemented"),
            ("❌", "Declined")
        ]
    }

    var featureStatusByEmoji: [String: String] {
        let raw = Dictionary(uniqueKeysWithValues: featureStatusEmojiDescriptions.map { ($0.emoji, $0.label) })
        var normalized = raw
        for (emoji, label) in raw {
            normalized[normalizedReactionEmojiName(emoji)] = label
        }
        return normalized
    }

    // Slash command /featurerequest handler
    func handleFeatureRequestSlash(
        raw: [String: DiscordJSON],
        username: String,
        channelId: String,
        featureText: String,
        reasonText: String?
    ) async -> (ok: Bool, message: String) {
        guard let guildId = guildId(from: raw) else {
            return (false, "`/featurerequest` only works in a server channel.")
        }

        guard let targetChannelID = bugTrackerChannelID(for: guildId) else {
            return (false, "Couldn't find #swiftbot-dev in this server.")
        }

        let requesterID = authorId(from: raw) ?? "unknown-user"
        let cleaned = bugPreviewText(from: featureText)
        var message = """
        ✨ SwiftBot Feature Request
        Requester: <@\(requesterID)>
        Channel: <#\(channelId)>
        Feature:
        "\(cleaned)"
        Status: New Request
        """
        let cleanedReason = reasonText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedReason.isEmpty {
            message += "\nReason:\n\"\(bugPreviewText(from: cleanedReason))\""
        }

        guard let requestMessageID = await sendMessageReturningID(channelId: targetChannelID, content: message) else {
            return (false, "Failed to post feature request in <#\(targetChannelID)>.")
        }

        let didPin = await retryBugOperation {
            await pinMessage(channelId: targetChannelID, messageId: requestMessageID)
        }
        let didSeedReactions = await seedFeatureRequestReactions(channelID: targetChannelID, messageID: requestMessageID)
        let threadTitle = "Feature: " + String(cleaned.prefix(51))
        _ = await createThreadFromMessage(channelId: targetChannelID, messageId: requestMessageID, name: threadTitle)
        await postFeatureThreadLegend(channelID: targetChannelID, messageID: requestMessageID)

        logs.append("✨ Feature request created messageID=\(requestMessageID) guildID=\(guildId) requester=\(requesterID) username=\(username)")
        if !didSeedReactions {
            logs.append("⚠️ Feature request reaction seed failed for message \(requestMessageID) in channel \(targetChannelID). Likely missing `Add Reactions` or `Read Message History` permission.")
        }
        var responseLines = ["Feature request posted in <#\(targetChannelID)>."]
        if didPin {
            responseLines.append("📌 Pinned successfully.")
        } else {
            responseLines.append("⚠️ I couldn't pin it. Please grant `Manage Messages` in that channel.")
        }
        if !didSeedReactions {
            responseLines.append("⚠️ I couldn't add status reactions. Please grant `Add Reactions` and `Read Message History` in that channel.")
        }
        return (true, responseLines.joined(separator: "\n"))
    }

    func handleFeatureStatusReaction(
        messageID: String,
        channelID: String,
        userID: String,
        statusLabel: String
    ) async {
        guard let message = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = message["content"],
              content.contains("✨ SwiftBot Feature Request")
        else { return }

        let reactionsReady = await seedFeatureRequestReactions(channelID: channelID, messageID: messageID)
        let updatedContent = replacingBugStatusLine(in: content, status: statusLabel)
        let contentUpdated = await editMessage(channelId: channelID, messageId: messageID, content: updatedContent)

        var unpinOK = true
        if statusLabel == "Implemented" {
            let didUnpin = await unpinMessage(channelId: channelID, messageId: messageID)
            unpinOK = didUnpin
            if didUnpin {
                _ = await send(channelID, "✅ Feature request implemented — unpinned.")
            }
        }

        if let threadID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) {
            _ = await send(threadID, "📝 <@\(userID)> marked this feature request as **\(statusLabel)**.")
        }

        let guildID: String = {
            if case let .string(id)? = message["guild_id"] { return id }
            return "unknown-guild"
        }()
        let reactorName = await displayNameForUserID(userID)
        let serverName = connectedServers[guildID] ?? "Server \(guildID.suffix(4))"
        await appendBugCommandLog(
            user: reactorName,
            server: serverName,
            command: "/featurerequest status \(statusLabel)",
            channel: channelID,
            ok: contentUpdated && reactionsReady && unpinOK
        )
        logs.append("✨ Feature request updated messageID=\(messageID) status=\(statusLabel) by=\(userID)")
    }

    func seedFeatureRequestReactions(channelID: String, messageID: String) async -> Bool {
        var allSucceeded = true
        for item in featureStatusEmojiDescriptions {
            let added = await retryBugOperation {
                await addReaction(channelId: channelID, messageId: messageID, emoji: item.emoji)
            }
            allSucceeded = allSucceeded && added
        }
        return allSucceeded
    }

    func postFeatureThreadLegend(channelID: String, messageID: String) async {
        guard let threadID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) else { return }
        var lines: [String] = ["🧭 **Feature Request Status Reactions**"]
        for item in featureStatusEmojiDescriptions {
            lines.append("\(item.emoji) \(item.label)")
        }
        lines.append("")
        lines.append("Add one of these reactions on the parent feature request message to show current status.")
        _ = await send(threadID, lines.joined(separator: "\n"))
    }
}
