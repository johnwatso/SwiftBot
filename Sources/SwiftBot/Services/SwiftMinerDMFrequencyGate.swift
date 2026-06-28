import Foundation

// MARK: - SwiftMiner DM Notification Filter
//
// Lightweight per-type toggle that controls which event DMs are delivered.
// Onboarding messages (welcome, discordLinked, setup, linked) always pass through.

actor SwiftMinerDMNotificationFilter {
    private let preferences: SwiftMinerDMNotificationPreferences

    init(preferences: SwiftMinerDMNotificationPreferences) {
        self.preferences = preferences
    }

    /// Returns true if the DM should be sent, false if suppressed by preferences.
    func shouldSend(messageType: SwiftMinerDMMessageType) -> Bool {
        // Onboarding messages always pass through.
        switch messageType {
        case .welcome, .discordLinked, .setup, .linked:
            return true
        case .dropClaimed:
            return preferences.dropClaimedEnabled
        case .campaignCompleted:
            return preferences.campaignCompletedEnabled
        case .reauth:
            return preferences.connectionExpiredEnabled
        case .welcomeBack:
            return preferences.welcomeBackEnabled
        case .prioritisedGameNeedsLinking:
            return preferences.linkRequiredEnabled
        case .campaignDetected:
            return preferences.campaignDetectedEnabled
        case .accountActionRequired:
            return preferences.accountActionRequiredEnabled
        case .webDashboardAvailable:
            // One-time announcement, sent only when the dashboard first goes
            // live — always allowed through.
            return true
        }
    }
}
