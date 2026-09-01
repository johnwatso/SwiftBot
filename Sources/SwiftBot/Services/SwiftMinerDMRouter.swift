import Foundation

// MARK: - SwiftMiner DM Router
//
// Routes incoming `SwiftMinerDMRequest` payloads to the correct embed builder
// and determines whether this DM should mutate onboarding state.
//
// Rules:
// - debug == true  → never mutate state, mark embeds as test
// - .welcome        → track welcome sent (unless debug)
// - .linked         → track onboarding completion (unless debug)
// - .setup          → does NOT track completion (onboarding started, not finished)
// - all others      → do not mutate onboarding state
//
// Portal links: SwiftMiner resolves a deep link per DM and sends it as
// `portal_url`. That becomes the one primary button, labelled from
// `portal_destination`. Only when a DM carries no deep link does the generic
// "manage your miner" dashboard footer stand in — never both, or the reader
// gets a specific destination and a vague one side by side.

struct SwiftMinerDMRouter: Sendable {

    let theme: SwiftMinerDMTheme
    /// Public URL of the companion web dashboard (e.g. https://swiftminer.example.com).
    /// When set, every DM gets a "manage it on the web" footer instead of buttons.
    let dashboardURL: String?

    init(theme: SwiftMinerDMTheme = .default, dashboardURL: String? = nil) {
        self.theme = theme
        self.dashboardURL = dashboardURL
    }

    func route(request: SwiftMinerDMRequest, discordName: String?) -> SwiftMinerDMResult {
        var embed: [String: Any]
        // Interactive controls still live on the web dashboard; the only
        // components a DM carries are link buttons out to it.
        let components: [[String: Any]] = Self.portalComponents(for: request)
        var shouldTrackWelcome = false
        var shouldTrackCompletion = false
        let analyticsDescription: String

        switch request.messageType {
        case .welcome:
            embed = SwiftMinerDMEmbedBuilders.buildWelcomeEmbed(
                discordName: discordName,
                debug: request.debug,
                theme: theme
            )
            shouldTrackWelcome = !request.debug
            analyticsDescription = "welcome"

        case .discordLinked:
            embed = SwiftMinerDMEmbedBuilders.buildDiscordLinkedEmbed(
                discordName: discordName,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "discord_linked"

        case .setup:
            embed = SwiftMinerDMEmbedBuilders.buildSetupEmbed(
                discordName: discordName,
                activationCode: request.activationCode,
                activationExpiresInMinutes: request.activationExpiresInMinutes,
                activationExpiresAt: request.activationExpiresAt,
                activationURL: request.activationURL,
                debug: request.debug,
                theme: theme
            )
            // Setup starts onboarding; it does NOT complete it.
            shouldTrackCompletion = false
            analyticsDescription = "setup"

        case .linked:
            embed = SwiftMinerDMEmbedBuilders.buildLinkedEmbed(
                discordName: discordName,
                twitchUsername: request.twitchUsername,
                priorityGames: request.priorityGames,
                priorityGamesKeyPresent: true, // linked requests always carry data
                debug: request.debug,
                theme: theme
            )
            shouldTrackCompletion = !request.debug
            analyticsDescription = "linked"

        case .reauth:
            embed = SwiftMinerDMEmbedBuilders.buildReauthEmbed(
                discordName: discordName,
                recoveryReason: request.recoveryReason,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "reauth"

        case .welcomeBack:
            embed = SwiftMinerDMEmbedBuilders.buildWelcomeBackEmbed(
                discordName: discordName,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "welcome_back"

        case .dropClaimed:
            embed = SwiftMinerDMEmbedBuilders.buildDropClaimedEmbed(
                discordName: discordName,
                twitchUsername: request.twitchUsername,
                campaignName: request.campaignName,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "drop_claimed"

        case .campaignCompleted:
            embed = SwiftMinerDMEmbedBuilders.buildCampaignCompletedEmbed(
                discordName: discordName,
                campaignName: request.campaignName,
                gameName: request.affectedGame,
                gameArtworkURL: request.gameArtworkURL,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "campaign_completed"

        case .campaignDetected:
            embed = SwiftMinerDMEmbedBuilders.buildCampaignDetectedEmbed(
                discordName: discordName,
                campaignName: request.campaignName,
                affectedGame: request.affectedGame,
                gameArtworkURL: request.gameArtworkURL,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "campaign_detected"

        case .accountActionRequired:
            embed = SwiftMinerDMEmbedBuilders.buildAccountActionRequiredEmbed(
                discordName: discordName,
                recoveryReason: request.recoveryReason,
                issueKind: request.issueKind,
                campaignName: request.campaignName,
                affectedGame: request.affectedGame,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "account_action_required"

        case .prioritisedGameNeedsLinking:
            embed = SwiftMinerDMEmbedBuilders.buildPrioritisedGameNeedsLinkingEmbed(
                discordName: discordName,
                affectedGame: request.affectedGame,
                issueKind: request.issueKind,
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "prioritised_game_needs_linking"

        case .webDashboardAvailable:
            embed = [
                "title": (request.debug ? "[TEST] " : "") + "🌐 Your web dashboard is live",
                "description": "You can now check mining progress, see completed drops, and manage your game priorities from your browser — no commands needed."
            ]
            analyticsDescription = "web_dashboard_available"
        }

        // Fallback only. A DM that already has a deep-linked button must not
        // also advertise the dashboard root — the specific route is better.
        if components.isEmpty, let dashboardURL, !dashboardURL.isEmpty {
            var description = (embed["description"] as? String) ?? ""
            description += "\n\n🌐 Manage your miner: \(dashboardURL)"
            embed["description"] = description
        }

        return SwiftMinerDMResult(
            embed: embed,
            components: components,
            shouldTrackWelcome: shouldTrackWelcome,
            shouldTrackCompletion: shouldTrackCompletion,
            analyticsDescription: analyticsDescription
        )
    }

    // MARK: - Portal Buttons

    /// The link buttons for a DM: the portal deep link SwiftMiner resolved, plus
    /// the help article when there is one.
    ///
    /// Returns nothing when SwiftMiner sent no `portal_url`, which is how it
    /// reports that the operator has no reachable portal. Guessing a URL here
    /// would hand the recipient a link that cannot load.
    static func portalComponents(for request: SwiftMinerDMRequest) -> [[String: Any]] {
        var buttons: [[String: Any]] = []

        if let portalURL = request.portalURL, isRenderableLink(portalURL) {
            buttons.append([
                "type": 2,
                "style": 5,
                "label": (request.portalDestination ?? .dashboard).buttonLabel,
                "url": portalURL
            ])
        }

        // Secondary, and only alongside a primary — a help article on its own
        // is not the action the DM is asking for.
        if !buttons.isEmpty, let helpURL = request.helpURL, isRenderableLink(helpURL) {
            buttons.append([
                "type": 2,
                "style": 5,
                "label": "Learn More",
                "url": helpURL
            ])
        }

        return buttons.isEmpty ? [] : [["type": 1, "components": buttons]]
    }

    /// Discord rejects a link button whose URL is not http(s), and rejects the
    /// whole message with it — so a malformed link must drop the button, not
    /// the DM.
    private static func isRenderableLink(_ raw: String) -> Bool {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased() else { return false }
        guard scheme == "https" || scheme == "http" else { return false }
        return !(url.host ?? "").isEmpty
    }

    private static func campaignId(fromEventId eventId: String?) -> String? {
        guard let eventId, eventId.hasPrefix("campaignDetected:") else { return nil }
        let id = String(eventId.dropFirst("campaignDetected:".count))
        return id.isEmpty ? nil : id
    }
}
