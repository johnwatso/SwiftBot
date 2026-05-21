import Foundation

@MainActor
final class WelcomeFlowService {
    struct PublicMessage: Equatable {
        let content: String?
        let embed: Embed?
    }

    struct Embed: Equatable {
        let title: String
        let description: String
        let color: Int
        let footer: String
        /// Optional thumbnail image (typically the user avatar).
        var thumbnailURL: String?
        /// Optional author line displayed above the title.
        var authorName: String?
        var authorIconURL: String?
    }

    struct InviteSource: Equatable, Sendable {
        let code: String
        let channelID: String?
        let channelName: String?
        let inviterID: String?
        let uses: Int
    }

    struct InviteSnapshot: Equatable, Sendable {
        let code: String
        let channelID: String?
        let channelName: String?
        let inviterID: String?
        let uses: Int
    }

    struct Result: Sendable {
        let handledAt: Date
        let safeUsername: String
        let serverName: String
        let memberCount: Int
        let publicMessageSent: Bool
        let directMessageSent: Bool
        let grantedRoleIDs: [String]
        var autoRoleGranted: Bool { !grantedRoleIDs.isEmpty }
        let isDuplicate: Bool
        let isBurstSuppressed: Bool
    }

    private var recentMemberJoins: [String: Date] = [:]
    private var memberCountsByGuild: [String: Int] = [:]
    private var joinTimestampsByGuild: [String: [Date]] = [:]
    private var invitesByGuild: [String: [String: InviteSnapshot]] = [:]

    func seedMemberCount(guildID: String, count: Int) {
        memberCountsByGuild[guildID] = max(0, count)
    }

    func decrementMemberCount(guildID: String) {
        guard let count = memberCountsByGuild[guildID] else { return }
        memberCountsByGuild[guildID] = max(0, count - 1)
    }

    func seedInvites(guildID: String, invites: [InviteSnapshot]) {
        invitesByGuild[guildID] = Dictionary(uniqueKeysWithValues: invites.map { ($0.code, $0) })
    }

    func handleMemberJoin(
        _ event: GatewayMemberJoinEvent,
        settings: WelcomeFlowSettings,
        serverName: String,
        sendPublicMessage: @escaping (String, PublicMessage) async -> Bool,
        sendDirectMessage: @escaping (String, String) async throws -> Void,
        grantRole: @escaping (String, String, String) async throws -> Void,
        fetchInvites: @escaping (String) async -> [InviteSnapshot]?,
        log: @escaping (String) -> Void
    ) async -> Result {
        let now = Date()
        let memberCount = incrementMemberCount(guildID: event.guildID)
        let safeUsername = sanitizeMentions(event.rawUsername)

        // Bot skip — short-circuit before burst/dedupe so bot joins don't poison those windows.
        if settings.skipBots, event.isBot {
            log("Welcome Flow: skipped bot account \(safeUsername) in \(serverName).")
            return Result(
                handledAt: now,
                safeUsername: safeUsername,
                serverName: serverName,
                memberCount: memberCount,
                publicMessageSent: false,
                directMessageSent: false,
                grantedRoleIDs: [],
                isDuplicate: false,
                isBurstSuppressed: false
            )
        }

        // Account-age gate.
        if settings.minAccountAgeDays > 0,
           let creationDate = Self.accountCreationDate(forSnowflake: event.userID) {
            let ageDays = now.timeIntervalSince(creationDate) / 86_400
            if ageDays < Double(settings.minAccountAgeDays) {
                let ageDescription = String(format: "%.1f", ageDays)
                let modChannelID = settings.modAlertChannelId.trimmingCharacters(in: .whitespacesAndNewlines)
                switch settings.accountAgeAction {
                case .skipWelcome:
                    log("Welcome Flow: skipped \(safeUsername) (account age \(ageDescription)d < \(settings.minAccountAgeDays)d).")
                case .alertModerators where !modChannelID.isEmpty:
                    let alert = sanitizeMentions(
                        "⚠️ New account joined \(serverName): \(safeUsername) — account age \(ageDescription) day(s)."
                    )
                    _ = await sendPublicMessage(modChannelID, PublicMessage(content: alert, embed: nil))
                    log("Welcome Flow: low-age alert for \(safeUsername) (\(ageDescription)d) sent to mods.")
                case .alertModerators:
                    log("Welcome Flow: low-age \(safeUsername) (\(ageDescription)d) — no mod channel configured.")
                }
                return Result(
                    handledAt: now,
                    safeUsername: safeUsername,
                    serverName: serverName,
                    memberCount: memberCount,
                    publicMessageSent: false,
                    directMessageSent: false,
                    grantedRoleIDs: [],
                    isDuplicate: false,
                    isBurstSuppressed: false
                )
            }
        }

        if isBurstJoin(guildID: event.guildID, at: now, threshold: settings.burstThreshold) {
            if shouldSendBurstSummary(guildID: event.guildID, threshold: settings.burstThreshold),
               settings.hasPublicWelcome {
                let message = sanitizeMentions("👥 Multiple members joined \(serverName) - welcome everyone!")
                _ = await sendPublicMessage(settings.publicChannelId, PublicMessage(content: message, embed: nil))
                log("Welcome Flow: join burst detected in \(event.guildID); sent summary and suppressed individual welcomes.")
            } else {
                log("Welcome Flow: join burst detected in \(event.guildID); suppressed individual welcome.")
            }
            return Result(
                handledAt: now,
                safeUsername: safeUsername,
                serverName: serverName,
                memberCount: memberCount,
                publicMessageSent: false,
                directMessageSent: false,
                grantedRoleIDs: [],
                isDuplicate: false,
                isBurstSuppressed: true
            )
        }

        if isDuplicateJoin(guildID: event.guildID, userID: event.userID, at: now) {
            return Result(
                handledAt: now,
                safeUsername: safeUsername,
                serverName: serverName,
                memberCount: memberCount,
                publicMessageSent: false,
                directMessageSent: false,
                grantedRoleIDs: [],
                isDuplicate: true,
                isBurstSuppressed: false
            )
        }

        let avatarURL = Self.avatarURL(
            userID: event.userID,
            avatarHash: event.avatarHash,
            discriminator: event.discriminator
        )

        var publicSent = false
        if settings.hasPublicWelcome {
            let message = renderPublicMessage(
                settings: settings,
                username: safeUsername,
                userID: event.userID,
                serverName: serverName,
                memberCount: memberCount,
                avatarURL: avatarURL
            )
            publicSent = await sendPublicMessage(settings.publicChannelId, message)
        }

        var dmSent = false
        if settings.hasDMWelcome {
            let message = render(
                template: settings.dmMessageTemplate,
                username: safeUsername,
                userID: event.userID,
                serverName: serverName,
                memberCount: memberCount
            )
            do {
                try await sendDirectMessage(event.userID, message)
                dmSent = true
            } catch {
                log("Welcome Flow: DM welcome failed for \(safeUsername): \(error.localizedDescription)")
                if settings.dmFallbackToChannelEnabled,
                   settings.hasPublicWelcome,
                   !settings.dmFallbackTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let fallback = render(
                        template: settings.dmFallbackTemplate,
                        username: safeUsername,
                        userID: event.userID,
                        serverName: serverName,
                        memberCount: memberCount
                    )
                    _ = await sendPublicMessage(
                        settings.publicChannelId,
                        PublicMessage(content: fallback, embed: nil)
                    )
                }
            }
        }

        var grantedRoleIDs: [String] = []
        let inviteSource = await resolveInviteSource(guildID: event.guildID, fetchInvites: fetchInvites)
        for rule in matchingRules(settings: settings, inviteSource: inviteSource) {
            do {
                try await grantRole(event.guildID, event.userID, rule.roleId)
                grantedRoleIDs.append(rule.roleId)
            } catch {
                log("Welcome Flow: rule '\(rule.name)' failed for \(safeUsername): \(error.localizedDescription)")
            }
        }

        if publicSent || dmSent || !grantedRoleIDs.isEmpty {
            let delivery = [
                publicSent ? "public" : nil,
                dmSent ? "DM" : nil,
                grantedRoleIDs.isEmpty ? nil : "\(grantedRoleIDs.count) role(s)"
            ].compactMap { $0 }.joined(separator: " + ")
            log("Welcome Flow: \(delivery) welcome sent for \(safeUsername) in \(serverName)")
        }

        return Result(
            handledAt: now,
            safeUsername: safeUsername,
            serverName: serverName,
            memberCount: memberCount,
            publicMessageSent: publicSent,
            directMessageSent: dmSent,
            grantedRoleIDs: grantedRoleIDs,
            isDuplicate: false,
            isBurstSuppressed: false
        )
    }

    private func resolveInviteSource(
        guildID: String,
        fetchInvites: @escaping (String) async -> [InviteSnapshot]?
    ) async -> InviteSource? {
        guard let current = await fetchInvites(guildID) else { return nil }
        let previous = invitesByGuild[guildID] ?? [:]
        seedInvites(guildID: guildID, invites: current)
        return current
            .filter { invite in
                invite.uses > (previous[invite.code]?.uses ?? invite.uses)
            }
            .sorted { $0.uses > $1.uses }
            .first
            .map {
                InviteSource(
                    code: $0.code,
                    channelID: $0.channelID,
                    channelName: $0.channelName,
                    inviterID: $0.inviterID,
                    uses: $0.uses
                )
            }
    }

    private func matchingRules(settings: WelcomeFlowSettings, inviteSource: InviteSource?) -> [WelcomeFlowRule] {
        settings.activeNextStepRules.filter { $0.matches(inviteCode: inviteSource?.code) }
    }

    private func incrementMemberCount(guildID: String) -> Int {
        let count = (memberCountsByGuild[guildID] ?? 0) + 1
        memberCountsByGuild[guildID] = count
        return count
    }

    private func isDuplicateJoin(guildID: String, userID: String, at now: Date) -> Bool {
        let key = "\(guildID):\(userID)"
        if let last = recentMemberJoins[key], now.timeIntervalSince(last) < 10 {
            return true
        }
        recentMemberJoins[key] = now
        if recentMemberJoins.count > 500 {
            let pruned = recentMemberJoins.filter { now.timeIntervalSince($0.value) < 60 }
            recentMemberJoins = Dictionary(uniqueKeysWithValues: Array(pruned.prefix(500)))
        }
        return false
    }

    private func isBurstJoin(guildID: String, at now: Date, threshold: Int) -> Bool {
        let threshold = max(1, threshold)
        var timestamps = joinTimestampsByGuild[guildID] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 5 }
        timestamps.append(now)
        if timestamps.count > 50 {
            timestamps = Array(timestamps.suffix(50))
        }
        joinTimestampsByGuild[guildID] = timestamps
        return timestamps.count > threshold
    }

    private func shouldSendBurstSummary(guildID: String, threshold: Int) -> Bool {
        (joinTimestampsByGuild[guildID]?.count ?? 0) == max(1, threshold) + 1
    }

    private func render(
        template: String,
        username: String,
        userID: String,
        serverName: String,
        memberCount: Int
    ) -> String {
        let rendered = template
            .replacingOccurrences(of: "{username}", with: username)
            .replacingOccurrences(of: "{userId}", with: userID)
            .replacingOccurrences(of: "{userMention}", with: "<@\(userID)>")
            .replacingOccurrences(of: "{server}", with: serverName)
            .replacingOccurrences(of: "{guildName}", with: serverName)
            .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")
        return sanitizeMentions(rendered)
    }

    private func renderPublicMessage(
        settings: WelcomeFlowSettings,
        username: String,
        userID: String,
        serverName: String,
        memberCount: Int,
        avatarURL: String?
    ) -> PublicMessage {
        let chosenTemplate = pickTemplate(
            from: settings.publicMessageTemplatePool,
            fallback: settings.publicMessageTemplate
        )
        let description = render(
            template: chosenTemplate,
            username: username,
            userID: userID,
            serverName: serverName,
            memberCount: memberCount
        )

        switch settings.publicMessageFormat {
        case .plainText:
            return PublicMessage(content: description, embed: nil)
        case .embed:
            let title = render(
                template: settings.publicEmbedTitleTemplate,
                username: username,
                userID: userID,
                serverName: serverName,
                memberCount: memberCount
            )
            let footer = render(
                template: settings.publicEmbedFooterTemplate,
                username: username,
                userID: userID,
                serverName: serverName,
                memberCount: memberCount
            )
            return PublicMessage(
                content: nil,
                embed: Embed(
                    title: title,
                    description: description,
                    color: settings.publicEmbedColor,
                    footer: footer,
                    thumbnailURL: settings.publicEmbedShowAvatar ? avatarURL : nil,
                    authorName: settings.publicEmbedShowAuthor ? "\(username) joined" : nil,
                    authorIconURL: settings.publicEmbedShowAuthor ? avatarURL : nil
                )
            )
        }
    }

    /// Pick a template at random from the pool if non-empty; otherwise use the fallback.
    /// Empty/whitespace-only entries in the pool are ignored.
    private func pickTemplate(from pool: [String], fallback: String) -> String {
        let usable = pool
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return usable.randomElement() ?? fallback
    }

    private func sanitizeMentions(_ value: String) -> String {
        value
            .replacingOccurrences(of: "@everyone", with: "@\u{200B}everyone")
            .replacingOccurrences(of: "@here", with: "@\u{200B}here")
    }

    // MARK: - Goodbye

    /// Posts a goodbye message when a member leaves the guild.
    /// Best-effort: no dedupe, no burst suppression (leaves are typically far rarer than joins).
    func handleGoodbye(
        _ event: GatewayMemberLeaveEvent,
        settings: WelcomeFlowSettings,
        serverName: String,
        sendPublicMessage: @escaping (String, PublicMessage) async -> Bool,
        log: @escaping (String) -> Void
    ) async {
        guard settings.hasGoodbyeMessage else { return }
        let safeUsername = sanitizeMentions(event.username)
        let memberCount = max(memberCountsByGuild[event.guildID] ?? 0, 0)
        let message = renderGoodbyeMessage(
            settings: settings,
            username: safeUsername,
            userID: event.userID,
            serverName: serverName,
            memberCount: memberCount
        )
        let sent = await sendPublicMessage(settings.goodbyeChannelId, message)
        if sent {
            log("Welcome Flow: goodbye sent for \(safeUsername) in \(serverName).")
        } else {
            log("Welcome Flow: goodbye send failed for \(safeUsername) in \(serverName).")
        }
    }

    private func renderGoodbyeMessage(
        settings: WelcomeFlowSettings,
        username: String,
        userID: String,
        serverName: String,
        memberCount: Int
    ) -> PublicMessage {
        let description = render(
            template: settings.goodbyeMessageTemplate,
            username: username,
            userID: userID,
            serverName: serverName,
            memberCount: memberCount
        )
        switch settings.goodbyeMessageFormat {
        case .plainText:
            return PublicMessage(content: description, embed: nil)
        case .embed:
            let title = render(
                template: settings.goodbyeEmbedTitleTemplate,
                username: username,
                userID: userID,
                serverName: serverName,
                memberCount: memberCount
            )
            let footer = render(
                template: settings.goodbyeEmbedFooterTemplate,
                username: username,
                userID: userID,
                serverName: serverName,
                memberCount: memberCount
            )
            return PublicMessage(
                content: nil,
                embed: Embed(
                    title: title,
                    description: description,
                    color: settings.goodbyeEmbedColor,
                    footer: footer
                )
            )
        }
    }

    // MARK: - Test send

    /// Renders the configured welcome message using a synthetic event and posts it without
    /// touching dedupe / burst state. Used by the UI's "Send Test" button.
    func sendTestWelcome(
        settings: WelcomeFlowSettings,
        serverName: String,
        testUserID: String,
        testUsername: String,
        sendPublicMessage: @escaping (String, PublicMessage) async -> Bool,
        log: @escaping (String) -> Void
    ) async -> Bool {
        guard settings.hasPublicWelcome else {
            log("Welcome Flow test: public welcome is not configured.")
            return false
        }
        let safeUsername = sanitizeMentions(testUsername)
        let memberCount = max(memberCountsByGuild[settings.publicChannelId] ?? 1, 1)
        let message = renderPublicMessage(
            settings: settings,
            username: safeUsername,
            userID: testUserID,
            serverName: serverName,
            memberCount: memberCount,
            avatarURL: Self.avatarURL(userID: testUserID, avatarHash: nil, discriminator: "0")
        )
        let sent = await sendPublicMessage(settings.publicChannelId, message)
        log(sent
            ? "Welcome Flow test: posted preview to configured channel."
            : "Welcome Flow test: send failed (check channel ID / permissions).")
        return sent
    }

    // MARK: - Snowflake / avatar helpers

    /// Discord snowflake epoch (2015-01-01T00:00:00.000Z).
    private static let discordEpochMillis: UInt64 = 1_420_070_400_000

    /// Decode the creation timestamp embedded in a Discord snowflake.
    /// Returns nil for malformed input.
    static func accountCreationDate(forSnowflake snowflake: String) -> Date? {
        guard let raw = UInt64(snowflake), raw >> 22 > 0 else { return nil }
        let millis = (raw >> 22) + discordEpochMillis
        return Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
    }

    /// Build a CDN avatar URL for the given user. Falls back to Discord's default-avatar set when
    /// `avatarHash` is nil. Returns nil if the userID isn't a valid snowflake.
    static func avatarURL(userID: String, avatarHash: String?, discriminator: String?) -> String? {
        if let hash = avatarHash, !hash.isEmpty {
            let ext = hash.hasPrefix("a_") ? "gif" : "png"
            return "https://cdn.discordapp.com/avatars/\(userID)/\(hash).\(ext)?size=128"
        }
        // Default avatar fallback.
        let index: Int
        if let disc = discriminator, disc != "0", let value = Int(disc) {
            index = value % 5
        } else if let id = UInt64(userID) {
            index = Int((id >> 22) % 6)
        } else {
            index = 0
        }
        return "https://cdn.discordapp.com/embed/avatars/\(index).png"
    }
}
