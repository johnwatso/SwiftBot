import Foundation

// MARK: - SwiftMiner DM Message Types
//
// These types mirror the payload sent by SwiftMiner via REST.
// SwiftMiner is the event source; SwiftBot is the presentation layer.

/// The category of DM notification SwiftMiner wants SwiftBot to deliver.
enum SwiftMinerDMMessageType: String, Codable, CaseIterable, Sendable, Identifiable {
    case welcome
    case discordLinked = "discord_linked"
    case setup
    case linked
    case reauth
    case welcomeBack = "welcome_back"
    case dropClaimed = "drop_claimed"
    case campaignCompleted = "campaign_completed"
    case campaignDetected = "campaign_detected"
    case accountActionRequired = "account_action_required"
    case prioritisedGameNeedsLinking = "prioritised_game_needs_linking"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .welcome: return "Welcome"
        case .discordLinked: return "Discord Linked"
        case .setup: return "Setup"
        case .linked: return "Twitch Connected"
        case .reauth: return "Connection Expired"
        case .welcomeBack: return "Welcome Back"
        case .dropClaimed: return "Drop Claimed"
        case .campaignCompleted: return "Campaign Complete"
        case .campaignDetected: return "New Campaign"
        case .accountActionRequired: return "Needs a Look"
        case .prioritisedGameNeedsLinking: return "Link Twitch to Claim Drops"
        }
    }
}

/// Full payload sent by SwiftMiner when requesting a DM be delivered to a Discord user.
struct SwiftMinerDMRequest: Codable, Sendable, Equatable {
    let messageType: SwiftMinerDMMessageType
    let debug: Bool
    let twitchUsername: String?
    let priorityGames: [String]
    let activationCode: String?
    let activationExpiresInMinutes: Int?
    let activationURL: String?
    let affectedGame: String?
    let campaignName: String?
    let milestoneTitle: String?
    let recoveryReason: String?
    /// Opaque event identifier for persistent deduplication. E.g. "drop:<id>", "campaign:<id>".
    let eventId: String?

    init(
        messageType: SwiftMinerDMMessageType,
        debug: Bool = false,
        twitchUsername: String? = nil,
        priorityGames: [String] = [],
        activationCode: String? = nil,
        activationExpiresInMinutes: Int? = nil,
        activationURL: String? = nil,
        affectedGame: String? = nil,
        campaignName: String? = nil,
        milestoneTitle: String? = nil,
        recoveryReason: String? = nil,
        eventId: String? = nil
    ) {
        self.messageType = messageType
        self.debug = debug
        self.twitchUsername = twitchUsername
        self.priorityGames = priorityGames
        self.activationCode = activationCode
        self.activationExpiresInMinutes = activationExpiresInMinutes
        self.activationURL = activationURL
        self.affectedGame = affectedGame
        self.campaignName = campaignName
        self.milestoneTitle = milestoneTitle
        self.recoveryReason = recoveryReason
        self.eventId = eventId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.messageType = try container.decode(SwiftMinerDMMessageType.self, forKey: .messageType)
        self.debug = try container.decodeIfPresent(Bool.self, forKey: .debug) ?? false
        self.twitchUsername = try container.decodeIfPresent(String.self, forKey: .twitchUsername)
        self.priorityGames = try container.decodeIfPresent([String].self, forKey: .priorityGames) ?? []
        self.activationCode = try container.decodeIfPresent(String.self, forKey: .activationCode)
        self.activationExpiresInMinutes = try container.decodeIfPresent(Int.self, forKey: .activationExpiresInMinutes)
        self.activationURL = try container.decodeIfPresent(String.self, forKey: .activationURL)
        self.affectedGame = try container.decodeIfPresent(String.self, forKey: .affectedGame)
        self.campaignName = try container.decodeIfPresent(String.self, forKey: .campaignName)
        self.milestoneTitle = try container.decodeIfPresent(String.self, forKey: .milestoneTitle)
        self.recoveryReason = try container.decodeIfPresent(String.self, forKey: .recoveryReason)
        self.eventId = try container.decodeIfPresent(String.self, forKey: .eventId)
    }

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case debug
        case twitchUsername = "twitch_username"
        case priorityGames = "priority_games"
        case activationCode = "activation_code"
        case activationExpiresInMinutes = "activation_expires_in_minutes"
        case activationURL = "activation_url"
        case affectedGame = "affected_game"
        case campaignName = "campaign_name"
        case milestoneTitle = "milestone_title"
        case recoveryReason = "recovery_reason"
        case eventId = "event_id"
    }
}

// MARK: - Mock Data for Testing

/// Injectable mock values for previewing SwiftMiner DMs without real Twitch state.
struct SwiftMinerDMMockData: Sendable {
    var twitchUsername: String? = "test_user"
    var priorityGames: [String] = ["THE FINALS", "Overwatch 2"]
    var activationCode: String? = "ABCD-EFGH"
    var activationExpiresInMinutes: Int? = 29
    var activationURL: String? = "https://www.twitch.tv/activate?code=ABCD-EFGH"
    var affectedGame: String? = "Test Game"
    var campaignName: String? = "Test Campaign"
    var milestoneTitle: String? = "50% Complete"
    var recoveryReason: String? = "Twitch token expired during mining."

    static let `default` = SwiftMinerDMMockData()
}

// MARK: - Routing Result

/// The outcome of routing a `SwiftMinerDMRequest` through `SwiftMinerDMRouter`.
struct SwiftMinerDMResult {
    /// The Discord embed payload to send.
    let embed: [String: Any]

    /// Whether this DM should mark the user as having received a welcome message.
    let shouldTrackWelcome: Bool

    /// Whether this DM should mark the user as having completed initial onboarding.
    let shouldTrackCompletion: Bool

    /// A human-readable description for analytics/logging.
    let analyticsDescription: String
}
