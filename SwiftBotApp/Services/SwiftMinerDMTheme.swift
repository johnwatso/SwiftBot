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
    var projectURL: String? = "https://github.com/johnwatso/SwiftMiner"

    // MARK: - Footer Defaults

    var defaultFooter: String = "Use /miner to check status"
    var setupFooter: String = "Need help? Open the setup guide"
    var statusFooter: String = "Use /miner to check status"
    var reauthFooter: String = "This usually takes less than a minute"
    var discordLinkedFooter: String = "Use /miner to manage your setup"

    // MARK: - Section Labels

    var prioritisationSectionLabel: String = "🎯 Current priorities"
    var prioritisationEmptyLabel: String = "🎯 Current priorities"
    var prioritisationMissingLabel: String = "🎯 Current priorities"

    var activationStepsTitle: String = "Link your Twitch account"
    var activationCodeSeparator: String = "━━━━━━━━━━━━━━"
    var setupLinkTitle: String = "🚀 Start setup"
    var setupLinkLabel: String = "Open Twitch activation"
    var notificationsSectionLabel: String = "🔔 Notifications"
    var notificationsSectionValue: String = "I'll keep messages low-noise: claimed Drops, new campaigns, and anything that needs your attention."

    // MARK: - Help CTA Labels

    var learnMoreLabel: String = "Learn more"
    var needHelpLabel: String = "❓ Need help?"
    var viewSetupGuideLabel: String = "View setup guide"
    var whatIsSwiftMinerLabel: String = "What is SwiftMiner?"
    var viewProjectLabel: String = "Check the project on GitHub"
    var projectInfoValue: String = "Want the bigger picture? %@."
    var setupGuideValue: String = "Open the setup guide for linking, troubleshooting, and commands."

    // MARK: - Body Copy

    var noGamesPrioritisedValue: String = "_No games prioritised. SwiftMiner will watch for any available Drops._"
    var prioritisationMissingValue: String = "_Prioritisation data could not be loaded._"

    var welcomeDescription: String = "I'll keep an eye on your Twitch Drops and message you here when something useful happens: claimed Drops, new campaigns, or anything that needs a quick fix."
    var welcomeBackDescription: String = "SwiftMiner is watching again. I'll keep an eye on your Drops and message you when something useful changes."
    var discordLinkedDescription: String = "You're connected to SwiftMiner now. This DM thread is where I'll send setup codes, Twitch Drops updates, and the occasional account alert."

    var setupDescription: String = "Almost there. Link Twitch once, then SwiftMiner can watch eligible Drops and claim them for you."
    var setupStep1: String = "Open **twitch.tv/activate**"
    var setupStep2: String = "Sign in to Twitch"
    var setupStep3: String = "Enter the code below"
    var setupExpiresLabel: String = "⏱️ Expires"
    var setupExpiredHint: String = "If it expires, run `/miner action:setup` for a new one."

    var reauthDescription: String = "Your Twitch session expired, so SwiftMiner can't claim Drops until you reconnect."
    var reauthWhyLabel: String = "❓ Reason"
    var reauthHowLabel: String = "🛠️ Next step"
    var reauthHowValue: String = "Run `/miner action:setup` to get a fresh Twitch link."

    var linkedBodyWithUsername: String = "Twitch is linked. SwiftMiner will watch for eligible Drops on **@%@** and claim them when they're ready."
    var linkedBodyWithoutUsername: String = "Twitch is linked. SwiftMiner will watch for eligible Drops and claim them when they're ready."

    var dropClaimedDescription: String = "Claimed a Drop from **%@**%@."
    var campaignCompletedDescription: String = "All available Drops from **%@** are claimed."
    var campaignDetectedDescription: String = "A new Drops campaign is available for **%@**. SwiftMiner will pick it up automatically when it matches your setup."
    var accountActionRequiredDescription: String = "SwiftMiner needs one thing checked before it can continue cleanly."
    var accountActionIssueLabel: String = "⚠️ Issue"
    var accountActionFixLabel: String = "🛠️ Next step"
    var accountActionFixValue: String = "Run `/miner action:status` for details, or `/miner action:setup` if Twitch needs reconnecting."
    var prioritisedGameNeedsLinkingDescription: String = "**%@** is prioritised, but no linked Twitch account can claim its Drops yet."

    // MARK: - Defaults

    static let `default` = SwiftMinerDMTheme()
}
