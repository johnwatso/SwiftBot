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
        let preview = games.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let extra = games.count > 8 ? "\n• …and \(games.count - 8) more" : ""
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
            title: "🔗 Discord account linked",
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

        if let minutes = activationExpiresInMinutes, minutes > 0 {
            fields.append(SwiftMinerDMEmbedPrimitives.makeCTAField(
                title: theme.setupExpiresLabel,
                value: "This code expires in \(minutes) minute\(minutes == 1 ? "" : "s")."
            ))
        }

        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🟣 Link your Twitch account",
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
            footer: "Check your Twitch inventory to redeem it",
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Campaign Completed

    static func buildCampaignCompletedEmbed(
        discordName: String?,
        campaignName: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let campaign = campaignName ?? "a campaign"
        let desc = String(format: theme.campaignCompletedDescription, campaign)

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🏁 Campaign complete",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .success,
            footer: theme.statusFooter,
            debug: debug,
            theme: theme
        )
    }

    // MARK: - Campaign Detected

    static func buildCampaignDetectedEmbed(
        discordName: String?,
        campaignName: String?,
        affectedGame: String?,
        debug: Bool,
        theme: SwiftMinerDMTheme = .default
    ) -> [String: Any] {
        let game = affectedGame ?? campaignName ?? "a game"
        let desc = String(format: theme.campaignDetectedDescription, game)

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🆕 New campaign",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .info,
            footer: "Prioritise or ignore games with /miner",
            debug: debug,
            theme: theme
        )
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
            title: "⚠️ Something needs a look",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + theme.accountActionRequiredDescription,
            style: .recovery,
            fields: fields,
            footer: "Check status for next steps",
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
        if let helpField = SwiftMinerDMEmbedPrimitives.makeHelpField(theme: theme) {
            fields.append(helpField)
        }

        return SwiftMinerDMEmbedPrimitives.makeStandardEmbed(
            title: "🔗 Link Twitch for \(game)",
            description: SwiftMinerDMEmbedPrimitives.greeting(for: discordName) + desc,
            style: .warning,
            fields: fields,
            footer: theme.setupFooter,
            debug: debug,
            theme: theme
        )
    }
}
