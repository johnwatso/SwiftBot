import Foundation

// MARK: - SwiftMiner DM Theme
//
// Centralized copy, labels, and presentation configuration for SwiftMiner DM embeds.
// Allows future wording/layout tweaks without rewriting embed builders.

struct SwiftMinerDMTheme: Sendable {

    // MARK: - Global

    var supportCommand: String = "/miner"
    var setupCommand: String = "/miner action:setup"
    var statusCommand: String = "/miner action:status"

    // MARK: - Help Documentation

    /// URL to the dedicated GitHub help/documentation page.
    /// Used for "Learn more", "Need help?", and setup guide links.
    var helpDocumentationURL: String? = "https://github.com/johnwatso/SwiftMiner/blob/main/docs/help/discord-help.md"

    // MARK: - Footer Defaults

    var defaultFooter: String = "Use /miner anytime to check status"
    var setupFooter: String = "Need help? Check the setup guide"
    var statusFooter: String = "Use /miner anytime to check status"
    var reauthFooter: String = "Reconnecting takes about 30 seconds"
    var discordLinkedFooter: String = "You can disconnect anytime in settings"

    // MARK: - Section Labels

    var prioritisationSectionLabel: String = "Current priorities"
    var prioritisationEmptyLabel: String = "Current priorities"
    var prioritisationMissingLabel: String = "Current priorities"

    var activationStepsTitle: String = "Link your Twitch account"
    var activationCodeSeparator: String = "━━━━━━━━━━━━━━"
    var notificationsSectionLabel: String = "Notifications"
    var notificationsSectionValue: String = "I'll DM you here if anything needs your attention."

    // MARK: - Help CTA Labels

    var learnMoreLabel: String = "Learn more"
    var needHelpLabel: String = "Need help?"
    var viewSetupGuideLabel: String = "View setup guide"
    var whatIsSwiftMinerLabel: String = "What is SwiftMiner?"
    var setupGuideValue: String = "Check out the setup guide for help with linking, troubleshooting, and commands."

    // MARK: - Body Copy

    var noGamesPrioritisedValue: String = "_No games prioritised — SwiftMiner will watch for any available Drops._"
    var prioritisationMissingValue: String = "_Prioritisation data could not be loaded._"

    var welcomeDescription: String = "I'll send you updates here about your Twitch Drops — when they're ready to claim, when campaigns finish, and if your connection ever needs a quick reconnect."
    var welcomeBackDescription: String = "SwiftMiner is running again. I'll keep you updated on Drops progress."
    var discordLinkedDescription: String = "Your Discord account is now connected to SwiftMiner. This lets me send you updates about Twitch Drops, setup, and anything that needs your attention."

    var setupDescription: String = "Follow the steps below to connect your Twitch account."
    var setupStep1: String = "Open **twitch.tv/activate**"
    var setupStep2: String = "Sign in to Twitch"
    var setupStep3: String = "Enter the code below"
    var setupExpiresLabel: String = "Expires"

    var reauthDescription: String = "Your Twitch connection needs refreshing. This usually happens when Twitch expires your login session."
    var reauthWhyLabel: String = "Why this happened"
    var reauthHowLabel: String = "How to fix"
    var reauthHowValue: String = "Use `/miner action:setup` to reconnect your account."

    var linkedBodyWithUsername: String = "Your Twitch account **@%@** is now connected to SwiftMiner. I'll start watching for Drops automatically."
    var linkedBodyWithoutUsername: String = "Your Twitch account is now connected to SwiftMiner. I'll start watching for Drops automatically."

    var dropClaimedDescription: String = "You claimed a drop from **%@**%@."
    var campaignCompletedDescription: String = "You've claimed all Drops from **%@**."
    var campaignDetectedDescription: String = "A new Drops campaign started for **%@**. SwiftMiner will start watching automatically if your account is connected."
    var accountActionRequiredDescription: String = "There's a problem with your mining setup."
    var accountActionIssueLabel: String = "Issue"
    var accountActionFixLabel: String = "What to do"
    var accountActionFixValue: String = "Use `/miner action:status` to see details, or `/miner action:setup` to reconnect if needed."
    var prioritisedGameNeedsLinkingDescription: String = "You prioritised **%@**, but there's no Twitch account linked to claim Drops for it."

    // MARK: - Defaults

    static let `default` = SwiftMinerDMTheme()
}
