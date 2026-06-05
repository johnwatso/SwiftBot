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

struct SwiftMinerDMRouter: Sendable {

    let theme: SwiftMinerDMTheme

    init(theme: SwiftMinerDMTheme = .default) {
        self.theme = theme
    }

    func route(request: SwiftMinerDMRequest, discordName: String?) -> SwiftMinerDMResult {
        let embed: [String: Any]
        var components = SwiftMinerDMEmbedBuilders.buildStatusRefreshComponents()
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
                debug: request.debug,
                theme: theme
            )
            analyticsDescription = "account_action_required"

        case .prioritisedGameNeedsLinking:
            embed = SwiftMinerDMEmbedBuilders.buildPrioritisedGameNeedsLinkingEmbed(
                discordName: discordName,
                affectedGame: request.affectedGame,
                debug: request.debug,
                theme: theme
            )
            components = SwiftMinerDMEmbedBuilders.buildPrioritisedGameNeedsLinkingComponents(
                affectedGame: request.affectedGame,
                debug: request.debug,
                theme: theme
            ) + components
            analyticsDescription = "prioritised_game_needs_linking"
        }

        return SwiftMinerDMResult(
            embed: embed,
            components: components,
            shouldTrackWelcome: shouldTrackWelcome,
            shouldTrackCompletion: shouldTrackCompletion,
            analyticsDescription: analyticsDescription
        )
    }
}
