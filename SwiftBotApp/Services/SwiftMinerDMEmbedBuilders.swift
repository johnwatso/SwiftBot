import Foundation

// MARK: - SwiftMiner DM Embed Primitives
//
// Reusable embed assembly helpers. Stateless, pure functions.

enum SwiftMinerDMEmbedPrimitives {

    static func makeStandardEmbed(
        title: String,
        description: String,
        style: SwiftMinerDMStyle,
        fields: [[String: Any]] = [],
        footer: String,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var embed: [String: Any] = [
            "title": debugTitle(title, debug: debug),
            "description": description,
            "color": style.color,
            "footer": ["text": debugFooter(footer, debug: debug)]
        ]
        if !fields.isEmpty {
            embed["fields"] = fields
        }
        return embed
    }

    static func makePrioritisationField(
        games: [String],
        keyPresent: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        if !keyPresent {
            return [
                "name": theme.prioritisationMissingLabel,
                "value": theme.prioritisationMissingValue,
                "inline": false
            ]
        }
        if games.isEmpty {
            return [
                "name": theme.prioritisationEmptyLabel,
                "value": theme.noGamesPrioritisedValue,
                "inline": false
            ]
        }
        // Rank the top 8 with medal emoji for positions 1–3 and bold rank
        // numbers for 4–8. Hierarchy makes the "what gets mined first" answer
        // scannable at a glance instead of a flat bullet list.
        let medals = ["🥇", "🥈", "🥉"]
        let preview = games.prefix(8).enumerated().map { index, game -> String in
            if index < medals.count {
                return "\(medals[index]) **\(index + 1).** \(game)"
            }
            return "**\(index + 1).** \(game)"
        }.joined(separator: "\n")
        let extra = games.count > 8 ? "\n…and \(games.count - 8) more" : ""
        return [
            "name": theme.prioritisationSectionLabel,
            "value": preview + extra,
            "inline": false
        ]
    }

    static func makeActivationCodeField(
        code: String,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        [
            "name": theme.activationCodeSeparator,
            "value": "```\n\(code)\n```",
            "inline": false
        ]
    }

    static func makeNotificationsField(
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        [
            "name": theme.notificationsSectionLabel,
            "value": theme.notificationsSectionValue,
            "inline": false
        ]
    }

    static func makeCTAField(title: String, value: String) -> [String: Any] {
        [
            "name": title,
            "value": value,
            "inline": false
        ]
    }

    static func makeHelpField(theme: SwiftMinerDMTheme = .default) -> [String: Any]? {
        guard let url = theme.helpDocumentationURL, !url.isEmpty else { return nil }
        return [
            "name": theme.needHelpLabel,
            "value": "[\(theme.viewSetupGuideLabel)](\(url))",
            "inline": false
        ]
    }

    static func makeProjectField(theme: SwiftMinerDMTheme = .default) -> [String: Any]? {
        guard let url = theme.projectURL, !url.isEmpty else { return nil }
        let link = "[\(theme.viewProjectLabel)](\(url))"
        return [
            "name": theme.whatIsSwiftMinerLabel,
            "value": String(format: theme.projectInfoValue, link),
            "inline": false
        ]
    }

    // MARK: - Debug Helpers

    static func debugTitle(_ title: String, debug: Bool) -> String {
        debug ? SwiftMinerDMDebugStyle.titlePrefix + title : title
    }

    static func debugFooter(_ footer: String, debug: Bool) -> String {
        debug ? footer + SwiftMinerDMDebugStyle.footerSuffix : footer
    }

    // MARK: - Greeting

    static func greeting(for discordName: String?) -> String {
        discordName.map { "Hi **\($0)**\n\n" } ?? ""
    }
}

// MARK: - SwiftMiner DM Embed Builders
//
// Typed embed builders per message category. Thin wrappers over primitives + theme.

enum SwiftMinerDMEmbedBuilders {

    static let linkWarningDismissCustomID = "swiftminer:link-warning:dismiss"
    static let linkWarningDismissTestCustomID = "swiftminer:link-warning:dismiss:test"

    // MARK: - Welcome

    static func buildWelcomeEmbed(
        discordName: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []
        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }
        if let projectField = SwiftMinerDMEmbedPrimitives.makeProjectField(theme: theme) {
            fields.append(projectField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "👋 Welcome to SwiftMiner",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.welcomeDescription,
            style: .neutral,
            fields: fields,
            footer: theme.defaultFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Discord Linked

    static func buildDiscordLinkedEmbed(
        discordName: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []
        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🔗 Discord linked",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.discordLinkedDescription,
            style: .info,
            fields: fields,
            footer: theme.discordLinkedFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Setup / Activation

    static func buildSetupEmbed(
        discordName: String?,
        activationCode: String?,
        activationExpiresInMinutes: Int?,
        activationExpiresAt: Date? = nil,
        activationURL: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []

        // Primary CTA: clickable activation link with code pre-filled.
        if let url = activationURL, !url.isEmpty {
            fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
                title: theme.setupLinkTitle,
                value: "[\(theme.setupLinkLabel)](\(url))"
            ))
        }

        // Always show the code if we have one, even alongside the CTA — it's a
        // useful fallback if Discord blocks the link or the user is on another
        // device. When there's no URL, also include the manual steps.
        if let code = activationCode, !code.isEmpty {
            if activationURL?.isEmpty ?? true {
                let steps = [
                    "1. \(theme.setupStep1)",
                    "2. \(theme.setupStep2)",
                    "3. \(theme.setupStep3)"
                ].joined(separator: "\n")
                fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
                    title: theme.activationStepsTitle,
                    value: steps
                ))
            }
            fields.append(SwiftMinerDMEmbedPrimitives.makeActivationCodeField(code: code, theme: theme))
        }

        // Prefer the absolute instant: Discord renders `<t:UNIX:R>` as a
        // live-updating "in 29 minutes" string and keeps counting down even if
        // the user opens the DM hours later. Fall back to the legacy minute
        // text when SwiftMiner only supplied a relative duration.
        if let expiresAt = activationExpiresAt {
            let unix = Int(expiresAt.timeIntervalSince1970)
            // Discord keeps rendering `<t:UNIX:R>` after expiry ("5 minutes
            // ago"), which confuses users staring at a long-stale DM. Append a
            // hint so the next action is obvious without forcing them to guess.
            fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
                title: theme.setupExpiresLabel,
                value: "This code expires <t:\(unix):R>.\n\(theme.setupExpiredHint)"
            ))
        } else if let minutes = activationExpiresInMinutes, minutes > 0 {
            fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
                title: theme.setupExpiresLabel,
                value: "This code expires in \(minutes) minute\(minutes == 1 ? "" : "s")."
            ))
        }

        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🟣 Link Twitch",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.setupDescription,
            style: .info,
            fields: fields,
            footer: theme.setupFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Linked (Twitch Connected)

    static func buildLinkedEmbed(
        discordName: String?,
        twitchUsername: String?,
        priorityGames: [String],
        priorityGamesKeyPresent: Bool,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []

        let body: String
        if let twitchUsername, !twitchUsername.isEmpty {
            body = String(format: theme.linkedBodyWithUsername, twitchUsername)
        } else {
            body = theme.linkedBodyWithoutUsername
        }

        fields.append(SwiftMinerDMEmbedPrimitives.makePrioritisationField(
            games: priorityGames,
            keyPresent: priorityGamesKeyPresent,
            theme: theme
        ))

        fields.append(SwiftMinerDMEmbedPrimitives.makeNotificationsField(theme: theme))

        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "✅ Twitch connected",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + body,
            style: .success,
            fields: fields,
            footer: theme.statusFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Re-auth (Connection Expired)

    static func buildReauthEmbed(
        discordName: String?,
        recoveryReason: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []

        let reason = recoveryReason ?? "Your Twitch login session expired."
        fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
            title: theme.reauthWhyLabel,
            value: reason
        ))

        fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
            title: theme.reauthHowLabel,
            value: theme.reauthHowValue
        ))

        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "⚠️ Twitch connection expired",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.reauthDescription,
            style: .warning,
            fields: fields,
            footer: theme.reauthFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Welcome Back

    static func buildWelcomeBackEmbed(
        discordName: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "👋 Welcome back",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.welcomeBackDescription,
            style: .neutral,
            footer: theme.statusFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Drop Claimed

    static func buildDropClaimedEmbed(
        discordName: String?,
        twitchUsername: String?,
        campaignName: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let campaign = campaignName ?? "a campaign"
        let account = twitchUsername.map { " on **@\($0)**" } ?? ""
        let desc = String(format: theme.dropClaimedDescription, campaign, account)

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🎁 Drop claimed",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .success,
            footer: "Check Twitch inventory for the claimed Drop",
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Campaign Completed

    /// Twitch Drops inventory — where Drops progress and claimed rewards live.
    static let twitchDropsURL = "https://www.twitch.tv/drops/inventory"

    /// Builds the campaign-completed embed. The game box art is the large focal
    /// image, the title leads with the game name, and the embed includes a
    /// visible link to the Twitch Drops inventory.
    static func buildCampaignCompletedEmbed(
        discordName: String?,
        campaignName: String?,
        gameName: String? = nil,
        gameArtworkURL: String? = nil,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let campaign = campaignName ?? "a campaign"
        let desc = String(format: theme.campaignCompletedDescription, campaign)

        let trimmedGame = gameName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let trimmedGame, !trimmedGame.isEmpty {
            title = "🏁 \(trimmedGame) — Campaign complete"
        } else {
            title = "🏁 Campaign complete"
        }

        var embed = SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: title,
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .success,
            footer: theme.statusFooter,
            debug: debug,
            theme: theme
        )
        embed["fields"] = [[
            "name": theme.inventoryLinkLabel,
            "value": "[\(theme.viewInventoryLabel)](\(Self.twitchDropsURL))",
            "inline": false
        ]]
        // Game box art is the focal image.
        if let gameArtworkURL, !gameArtworkURL.isEmpty {
            embed["image"] = ["url": gameArtworkURL]
        }
        return embed
    }

    // MARK: - Campaign Detected

    static func buildCampaignDetectedEmbed(
        discordName: String?,
        campaignName: String?,
        affectedGame: String?,
        gameArtworkURL: String? = nil,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let game = affectedGame ?? campaignName ?? "a game"
        let desc = String(format: theme.campaignDetectedDescription, game)
        let trimmedGame = affectedGame?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let trimmedGame, !trimmedGame.isEmpty {
            title = "🆕 \(trimmedGame) — New campaign"
        } else {
            title = "🆕 New campaign"
        }

        var embed = SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: title,
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .info,
            footer: theme.statusFooter,
            debug: debug,
            theme: theme
        )
        embed["fields"] = [[
            "name": theme.inventoryLinkLabel,
            "value": "[\(theme.viewInventoryLabel)](\(Self.twitchDropsURL))",
            "inline": false
        ]]
        if let gameArtworkURL, !gameArtworkURL.isEmpty {
            embed["image"] = ["url": gameArtworkURL]
        }
        return embed
    }

    // MARK: - Account Action Required

    static func buildAccountActionRequiredEmbed(
        discordName: String?,
        recoveryReason: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        var fields: [[String: Any]] = []

        let reason = recoveryReason ?? "Something needs your attention."
        fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
            title: theme.accountActionIssueLabel,
            value: reason
        ))

        fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
            title: theme.accountActionFixLabel,
            value: theme.accountActionFixValue
        ))

        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "⚠️ SwiftMiner needs a look",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.accountActionRequiredDescription,
            style: .recovery,
            fields: fields,
            footer: "Use /miner action:status for details",
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Prioritised Game Needs Linking

    static func buildPrioritisedGameNeedsLinkingEmbed(
        discordName: String?,
        affectedGame: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let game = affectedGame ?? "a prioritised game"
        let desc = String(format: theme.prioritisedGameNeedsLinkingDescription, game)

        var fields: [[String: Any]] = []
        // Primary CTA: open the Twitch Drops page where the user manages Drops
        // and the linked account that claims them.
        fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
            title: "🔗 Open Twitch Drops",
            value: "[Link your account for Drops](\(twitchDropsURL))"
        ))
        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        var embed = SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🔗 Link Twitch for \(game)",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .warning,
            fields: fields,
            footer: theme.setupFooter,
            debug: debug,
            theme: theme
        )
        return embed
    }

    static func buildPrioritisedGameNeedsLinkingComponents(
        affectedGame: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [[String: Any]] {
        let game = affectedGame ?? "this game"
        let dismissLabel = truncatedButtonLabel("Dismiss \(game) reminders")
        return [[
            "type": 1,
            "components": [
                [
                    "type": 2,
                    "style": 5,
                    "label": "Open Twitch Drops",
                    "url": twitchDropsURL
                ],
                [
                    "type": 2,
                    "style": 2,
                    "label": dismissLabel,
                    "custom_id": debug ? linkWarningDismissTestCustomID : linkWarningDismissCustomID
                ]
            ]
        ]]
    }

    private static func truncatedButtonLabel(_ label: String) -> String {
        guard label.count > 80 else { return label }
        return String(label.prefix(77)) + "..."
    }
}
