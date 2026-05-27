import XCTest
@testable import SwiftBot

@MainActor
final class AutomationModerationPrecedenceTests: XCTestCase {

    private var accumulator: ThreadSafeAccumulator!
    private var automationService: AutomationService!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        let localAccumulator = ThreadSafeAccumulator()
        self.accumulator = localAccumulator

        let deps = AutomationService.Dependencies(
            sendMessage: { _, _, _ in },
            sendPayloadMessage: { _, _, _ in },
            sendDM: { userId, content in
                localAccumulator.appendDM(userId: userId, content: content)
            },
            addReaction: { _, _, _, _ in },
            deleteMessage: { cid, mid, _ in
                localAccumulator.appendDelete(channelId: cid, messageId: mid)
            },
            addRole: { _, _, _, _ in },
            removeRole: { _, _, _, _ in },
            timeoutMember: { _, _, _, _ in },
            kickMember: { _, _, _, _ in },
            moveMember: { _, _, _, _ in },
            sendWebhook: { _, _ in },
            resolveChannelName: { _, _ in "test-channel" },
            resolveGuildName: { _ in "test-guild" },
            log: { line in
                localAccumulator.appendLog(line: line)
            },
            recordAutomationRun: { ruleId, ruleName, eventKind, triggerUser, stepsCount, status in
                localAccumulator.appendRecord(ruleId: ruleId, ruleName: ruleName, eventKind: eventKind, triggerUser: triggerUser, stepsCount: stepsCount, status: status)
            }
        )

        automationService = AutomationService(
            aiService: DiscordAIService(session: URLSession.shared),
            dependencies: deps
        )

        model = AppModel(discordRESTSession: URLSession.shared)
        await model.service.setBotTokenForTesting("bot-token-999")
        model.settings.token = "bot-token-999"
        model.settings.clusterMode = .standalone
        model.clusterSnapshot.mode = .standalone
        model.automationService = automationService

        // Clear any initial rules in-memory for testing
        model.automationStore.setRulesForTesting([])
    }

    override func tearDown() async throws {
        // Reset any rules in-memory
        model.automationStore.setRulesForTesting([])
        accumulator = nil
        automationService = nil
        model = nil
        try await super.tearDown()
    }

    // MARK: - Trigger Matching Tests

    func testTriggerChannelRestriction() {
        let trigger = Automations.Trigger(kind: .messageCreated, channelId: "chan-123")
        
        let matchingEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "chan-123",
            messageId: "msg-123",
            content: "hello",
            isDirectMessage: false,
            authorIsBot: false
        ))
        
        let nonMatchingEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "chan-999",
            messageId: "msg-124",
            content: "hello",
            isDirectMessage: false,
            authorIsBot: false
        ))

        let rules = [Automations.Rule(id: "r-1", name: "Test Rule", enabled: true, category: .automation, trigger: trigger, steps: [])]
        
        let matches1 = automationService.evaluate(event: matchingEvent, in: rules)
        XCTAssertEqual(matches1.count, 1)

        let matches2 = automationService.evaluate(event: nonMatchingEvent, in: rules)
        XCTAssertEqual(matches2.count, 0)
    }

    func testTriggerVoiceDurationThreshold() {
        let trigger = Automations.Trigger(kind: .userLeftVoice, voiceDurationThreshold: 300)
        
        let matchingEvent = SwiftBotEvent.leave(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "voice-123",
            durationSeconds: 400
        )
        
        let nonMatchingEvent = SwiftBotEvent.leave(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "voice-123",
            durationSeconds: 150
        )

        let rules = [Automations.Rule(id: "r-1", name: "Test Rule", enabled: true, category: .automation, trigger: trigger, steps: [])]

        let matches1 = automationService.evaluate(event: matchingEvent, in: rules)
        XCTAssertEqual(matches1.count, 1)

        let matches2 = automationService.evaluate(event: nonMatchingEvent, in: rules)
        XCTAssertEqual(matches2.count, 0)
    }

    // MARK: - Advanced Moderation Filter Tests

    func testSpamLinkFilterMatchesKeywords() {
        let spamFilter = Automations.Filter(id: "f-1", kind: .messageContainsSpamLink)
        
        let spamEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "spammer",
            channelId: "chat-1",
            messageId: "msg-1",
            content: "Check out this FREE-DISCORD-NITRO gift here: https://phishing-site.com",
            isDirectMessage: false,
            authorIsBot: false
        ))
        
        let safeEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "chat-1",
            messageId: "msg-2",
            content: "Here is a safe link to Google: https://google.com",
            isDirectMessage: false,
            authorIsBot: false
        ))

        let rules = [
            Automations.Rule(
                id: "r-1",
                name: "Spam Filter",
                enabled: true,
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filterLogic: .all,
                filters: [spamFilter],
                steps: []
            )
        ]

        let matchesSpam = automationService.evaluate(event: spamEvent, in: rules)
        XCTAssertEqual(matchesSpam.count, 1)

        let matchesSafe = automationService.evaluate(event: safeEvent, in: rules)
        XCTAssertEqual(matchesSafe.count, 0)
    }

    func testCapsPercentageFilter() {
        let capsFilter = Automations.Filter(id: "f-1", kind: .messageCapsPercentage, intValue: 80)
        
        let spamEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "shouter",
            channelId: "chat-1",
            messageId: "msg-1",
            content: "HELLO WORLD WHAT IS UP PEOPLE",
            isDirectMessage: false,
            authorIsBot: false
        ))
        
        let safeEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "chat-1",
            messageId: "msg-2",
            content: "Hello World What is up people",
            isDirectMessage: false,
            authorIsBot: false
        ))

        let rules = [
            Automations.Rule(
                id: "r-1",
                name: "Caps Filter",
                enabled: true,
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filterLogic: .all,
                filters: [capsFilter],
                steps: []
            )
        ]

        let matchesSpam = automationService.evaluate(event: spamEvent, in: rules)
        XCTAssertEqual(matchesSpam.count, 1)

        let matchesSafe = automationService.evaluate(event: safeEvent, in: rules)
        XCTAssertEqual(matchesSafe.count, 0)
    }

    func testMentionsCountFilter() {
        let pingsFilter = Automations.Filter(id: "f-1", kind: .messageMentionsCount, intValue: 3)
        
        let spamEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "pinger",
            channelId: "chat-1",
            messageId: "msg-1",
            content: "Hey <@123> <@456> and <@789> wake up!",
            isDirectMessage: false,
            authorIsBot: false
        ))
        
        let safeEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            channelId: "chat-1",
            messageId: "msg-2",
            content: "Hey <@123> how are you?",
            isDirectMessage: false,
            authorIsBot: false
        ))

        let rules = [
            Automations.Rule(
                id: "r-1",
                name: "Pings Filter",
                enabled: true,
                category: .moderation,
                trigger: Automations.Trigger(kind: .messageCreated),
                filterLogic: .all,
                filters: [pingsFilter],
                steps: []
            )
        ]

        let matchesSpam = automationService.evaluate(event: spamEvent, in: rules)
        XCTAssertEqual(matchesSpam.count, 1)

        let matchesSafe = automationService.evaluate(event: safeEvent, in: rules)
        XCTAssertEqual(matchesSafe.count, 0)
    }

    // MARK: - Operational Separation & Precedence Tests

    func testDestructiveModerationBypassesAutomationRules() async {
        // Build a destructive moderation rule: delete spam messages
        let spamFilter = Automations.Filter(id: "f-1", kind: .messageContainsSpamLink)
        let deleteStep = Automations.Step(id: "s-delete", kind: .modifyMessage, messageOp: .delete)
        let moderationRule = Automations.Rule(
            id: "r-mod",
            name: "Delete Spam Links",
            enabled: true,
            category: .moderation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [spamFilter],
            steps: [deleteStep]
        )

        // Build a normal automation rule: send a DM greeting on any message
        let welcomeStep = Automations.Step(id: "s-welcome", kind: .sendMessage, sendTarget: .directMessage, content: "Welcome!")
        let automationRule = Automations.Rule(
            id: "r-auto",
            name: "DM Greeting",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            steps: [welcomeStep]
        )

        model.automationStore.setRulesForTesting([automationRule, moderationRule])

        // Event triggering spam link
        let event = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-123",
            username: "spammer",
            channelId: "chat-123",
            messageId: "msg-456",
            content: "Claim free gift at www.free-discord-nitro.phishing.com",
            isDirectMessage: false,
            authorIsBot: false
        ))

        await model.fireAutomations(for: event)

        // Verify:
        // 1. The moderation rule executed and deleted the message
        XCTAssertEqual(accumulator.mockDeletes.count, 1)
        XCTAssertEqual(accumulator.mockDeletes.first?.0, "chat-123")
        XCTAssertEqual(accumulator.mockDeletes.first?.1, "msg-456")

        // 2. Critical Boundary Assertion: The welcome automation rule was bypassed entirely (mockDMs is empty!)
        XCTAssertEqual(accumulator.mockDMs.count, 0)
    }

    func testNonDestructiveModerationDoesNotBypassAutomationRules() async {
        // Build a non-destructive moderation rule: React to trigger with emoji (no deletion)
        let capsFilter = Automations.Filter(id: "f-1", kind: .messageCapsPercentage, intValue: 80)
        let reactStep = Automations.Step(id: "s-react", kind: .modifyMessage, messageOp: .react, reactEmoji: "🤐")
        let moderationRule = Automations.Rule(
            id: "r-mod",
            name: "React to shouting",
            enabled: true,
            category: .moderation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [capsFilter],
            steps: [reactStep]
        )

        // Build a normal automation rule: send a DM greeting on any message
        let welcomeStep = Automations.Step(id: "s-welcome", kind: .sendMessage, sendTarget: .directMessage, content: "Welcome!")
        let automationRule = Automations.Rule(
            id: "r-auto",
            name: "DM Greeting",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            steps: [welcomeStep]
        )

        model.automationStore.setRulesForTesting([automationRule, moderationRule])

        // Event triggering caps but not destructive
        let event = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-123",
            username: "shouter",
            channelId: "chat-123",
            messageId: "msg-456",
            content: "PLEASE WAKE UP YALL",
            isDirectMessage: false,
            authorIsBot: false
        ))

        await model.fireAutomations(for: event)

        // Verify:
        // 1. Both rules were executed successfully
        XCTAssertEqual(accumulator.mockDMs.count, 1)
        XCTAssertEqual(accumulator.mockDMs.first?.0, "user-123")
        XCTAssertEqual(accumulator.mockDMs.first?.1, "Welcome!")
    }

    func testRuleSimulationAndTracingSuccess() async {
        // Build a rule with trigger, filters, and steps
        let spamFilter = Automations.Filter(id: "f-1", kind: .messageContainsSpamLink)
        let capsFilter = Automations.Filter(id: "f-2", kind: .messageCapsPercentage, intValue: 80)
        let deleteStep = Automations.Step(id: "s-delete", kind: .modifyMessage, messageOp: .delete)
        let rule = Automations.Rule(
            id: "r-sim",
            name: "Spam Simulation",
            enabled: true,
            category: .moderation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [spamFilter, capsFilter],
            steps: [deleteStep]
        )

        // Event that matches trigger and both filters
        let matchingEvent = SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-123",
            username: "spammer",
            channelId: "chat-123",
            messageId: "msg-456",
            content: "FREE-DISCORD-NITRO PHISHING LINK HERE: HTTPS://GIFT-NITRO.COM",
            isDirectMessage: false,
            authorIsBot: false
        ))

        let result = await automationService.simulate(rule: rule, event: matchingEvent)

        // Verify:
        // 1. Trigger matched
        XCTAssertTrue(result.triggerMatched)
        
        // 2. Filters matched and traced
        XCTAssertTrue(result.filtersMatched)
        XCTAssertEqual(result.filterTraces.count, 2)
        XCTAssertTrue(result.filterTraces[0].matched)
        XCTAssertTrue(result.filterTraces[1].matched)
        XCTAssertTrue(result.filterTraces[1].detail.contains("100% caps"))

        // 3. Steps dry-run timeline captured
        XCTAssertEqual(result.stepTraces.count, 1)
        XCTAssertTrue(result.stepTraces[0].executed)
        XCTAssertTrue(result.stepTraces[0].detail.contains("Would delete message"))
    }
}

final class ThreadSafeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _mockLogs: [String] = []
    private var _mockDMs: [(String, String)] = []
    private var _mockDeletes: [(String, String)] = []
    private var _recordedRuns: [(String, String, String, String, Int, String)] = []

    var mockLogs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _mockLogs
    }

    var mockDMs: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _mockDMs
    }

    var mockDeletes: [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _mockDeletes
    }

    var recordedRuns: [(String, String, String, String, Int, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _recordedRuns
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        _mockLogs.removeAll()
        _mockDMs.removeAll()
        _mockDeletes.removeAll()
        _recordedRuns.removeAll()
    }

    func appendDM(userId: String, content: String) {
        lock.lock()
        defer { lock.unlock() }
        _mockDMs.append((userId, content))
    }

    func appendDelete(channelId: String, messageId: String) {
        lock.lock()
        defer { lock.unlock() }
        _mockDeletes.append((channelId, messageId))
    }

    func appendLog(line: String) {
        lock.lock()
        defer { lock.unlock() }
        _mockLogs.append(line)
    }

    func appendRecord(ruleId: String, ruleName: String, eventKind: String, triggerUser: String, stepsCount: Int, status: String) {
        lock.lock()
        defer { lock.unlock() }
        _recordedRuns.append((ruleId, ruleName, eventKind, triggerUser, stepsCount, status))
    }
}
