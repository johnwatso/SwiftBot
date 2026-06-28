import Foundation
import Observation

// MARK: - Legacy rule schema (stub)
//
// The legacy block-builder rule schema was replaced by `Automations.Rule`
// (see Models/Automations.swift). The macOS app's Automations tab now uses
// the new schema exclusively.
//
// These hollow types remain so that downstream consumers — the web admin
// UI rule editor, AnalyticsView's rule panels, OverviewView's rule count,
// and the BotDataProvider abstraction — keep compiling. Their behaviour is
// intentionally degraded: rule lists are always empty, mutators are no-ops.
// Rebuild those features on top of `Automations.Rule` (or remove them) when
// you're ready.

enum TriggerType: String, Codable, CaseIterable {
    case userJoinedVoice
    case userLeftVoice
    case userMovedVoice
    case messageCreated
    case memberJoined
    case memberLeft
    case reactionAdded
    case slashCommand
    case mediaAdded
}

enum ConditionType: String, Codable, CaseIterable {
    case server
    case voiceChannel
    case channelIs
    case channelType
    case channelCategory
    case usernameContains
    case minimumDuration
    case userHasRole
    case userJoinedRecently
    case messageContains
    case messageStartsWith
    case messageRegex
    case isDirectMessage
    case isFromBot
    case isFromUser
}

enum ActionType: String, Codable, CaseIterable {
    case sendMessage
    case sendDM
    case addReaction
    case deleteMessage
    case addRole
    case removeRole
    case timeoutMember
    case kickMember
    case moveMember
    case createChannel
    case webhook
    case generateAIResponse
    case summariseMessage
    case classifyMessage
    case extractEntities
    case rewriteMessage
    case replyToTrigger
    case mentionUser
    case mentionRole
    case disableMention
    case sendToChannel
    case sendToDM
    case delay
    case setVariable
    case randomChoice
    case addLogEntry
    case setStatus
}

enum BlockCategory: String, Codable, CaseIterable {
    case triggers
    case filters
    case ai
    case messaging
    case actions
    case moderation
}

enum ContentSource: String, Codable, CaseIterable {
    case custom
    case aiResponse
    case aiSummary
    case aiClassification
    case aiEntities
    case aiRewrite
}

enum MessageDestination: String, Codable, CaseIterable {
    case replyToTrigger
    case sameChannel
    case specificChannel
}

struct Condition: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: ConditionType = .server
    var value: String = ""
    var secondaryValue: String = ""
}

struct RuleAction: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var message: String = ""
    var emoji: String = ""
    var roleId: String = ""
    var timeoutDuration: Int = 60
    var kickReason: String = ""
    var targetVoiceChannelId: String = ""
    var newChannelName: String = ""
    var webhookURL: String = ""
    var webhookContent: String = ""
    var deleteDelaySeconds: Int = 0
    var delaySeconds: Int = 0
    var dmContent: String = ""
    var rewriteStyle: String = ""
    var entityTypes: String = ""
    var categories: String = ""
    var statusText: String = ""
    var destinationMode: MessageDestination?
    var contentSource: ContentSource = .custom
}

typealias Action = RuleAction

struct Rule: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var isEnabled: Bool = false
    var trigger: TriggerType? = .messageCreated
    var triggerServerId: String = ""
    var conditions: [Condition] = []
    var modifiers: [RuleAction] = []
    var actions: [RuleAction] = []
    var aiBlocks: [RuleAction] = []

    var processedActions: [RuleAction] { actions }

    static func empty() -> Rule { Rule() }
}

@MainActor
@Observable
final class RuleStore {
    var rules: [Rule] = []
    var selectedRuleID: UUID?

    func scheduleAutoSave() {}
    func reloadFromDisk() async {}

    func addNewRule(serverId: String, channelId: String) {
        var rule = Rule.empty()
        rule.triggerServerId = serverId
        rules.append(rule)
    }
}

