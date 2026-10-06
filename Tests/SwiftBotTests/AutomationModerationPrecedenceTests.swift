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
            banMember: { guild, user, reason, seconds, _ in
                localAccumulator.appendLog(line: "ban:\(guild):\(user):\(reason):\(seconds)")
            },
            removeTimeout: { guild, user, _ in
                localAccumulator.appendLog(line: "removeTimeout:\(guild):\(user)")
            },
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
        await model.service.setOutputAllowed(true)
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

    func testRoleFilterMatchesAnyConfiguredRole() {
        let filter = Automations.Filter(id: "f-role", kind: .userHasAnyRole, roleIds: ["moderator", "vip"])
        let rules = [roleFilterRule(filter)]
        let event = messageEvent(roleIds: ["member", "vip"])

        let matches = automationService.evaluate(event: event, in: rules)

        XCTAssertEqual(matches.count, 1)
    }

    func testRoleFilterRequiresAllConfiguredRoles() {
        let filter = Automations.Filter(id: "f-role", kind: .userHasAllRoles, roleIds: ["moderator", "vip"])
        let rules = [roleFilterRule(filter)]

        XCTAssertEqual(automationService.evaluate(event: messageEvent(roleIds: ["moderator", "vip"]), in: rules).count, 1)
        XCTAssertEqual(automationService.evaluate(event: messageEvent(roleIds: ["moderator"]), in: rules).count, 0)
    }

    func testRoleFilterMatchesNoneOnlyWhenRoleDataIsKnown() {
        let filter = Automations.Filter(id: "f-role", kind: .userHasNoneOfRoles, roleIds: ["muted"])
        let rules = [roleFilterRule(filter)]

        XCTAssertEqual(automationService.evaluate(event: messageEvent(roleIds: ["member"]), in: rules).count, 1)
        XCTAssertEqual(automationService.evaluate(event: messageEvent(roleIds: ["member", "muted"]), in: rules).count, 0)
    }

    func testRoleFiltersFailClosedWhenRoleDataUnavailable() {
        let filters = [
            Automations.Filter(id: "any", kind: .userHasAnyRole, roleIds: ["vip"]),
            Automations.Filter(id: "all", kind: .userHasAllRoles, roleIds: ["vip"]),
            Automations.Filter(id: "none", kind: .userHasNoneOfRoles, roleIds: ["vip"])
        ]
        let event = messageEvent(roleIds: nil)

        for filter in filters {
            let matches = automationService.evaluate(event: event, in: [roleFilterRule(filter)])
            XCTAssertEqual(matches.count, 0, "\(filter.kind) should fail closed without role data")
        }
    }

    // MARK: - Operational Separation & Precedence Tests

    func testBanExecutesWithRenderedReasonAndBypassesOrdinaryAutomations() async {
        let banRule = Automations.Rule(id: "ban-rule", name: "Ban", category: .moderation,
            trigger: .init(kind: .messageCreated), steps: [
                .init(kind: .modifyMember, memberOp: .ban, kickReason: "Spam from {username}", banDeleteMessageSeconds: 3600)
            ])
        let greeting = Automations.Rule(id: "greeting", name: "Greeting", trigger: .init(kind: .messageCreated), steps: [
            .init(kind: .sendMessage, sendTarget: .directMessage, content: "hello")
        ])
        model.automationStore.setRulesForTesting([greeting, banRule])
        let event = SwiftBotEvent.message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: "ban-event", content: "spam", isDirectMessage: false, authorIsBot: false))
        await model.fireAutomations(for: event)
        XCTAssertEqual(accumulator.mockLogs, ["ban:g:u:Spam from tester:3600"])
        XCTAssertTrue(accumulator.mockDMs.isEmpty)
    }

    /// Live messages reach rules through DiscordService, not `fireAutomations`.
    /// The reply rule is stored first, which used to make it run before the ban.
    func testLiveMessagePathAppliesModerationPrecedence() async throws {
        let banRule = Automations.Rule(id: "ban-rule", name: "Ban", category: .moderation,
            trigger: .init(kind: .messageCreated), steps: [
                .init(kind: .modifyMember, memberOp: .ban, kickReason: "Spam from {username}", banDeleteMessageSeconds: 3600)
            ])
        let greeting = Automations.Rule(id: "greeting", name: "Greeting", trigger: .init(kind: .messageCreated), steps: [
            .init(kind: .sendMessage, sendTarget: .directMessage, content: "hello")
        ])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AutomationStore(fileURL: folder.appendingPathComponent("automations.json"))
        store.setRulesForTesting([greeting, banRule])
        let service = DiscordService(session: URLSession(configuration: .ephemeral))
        await service.setOutputAllowed(true)
        await service.setBotTokenForTesting("bot-token-999")
        await service.setAutomationService(automationService, store: store)

        let message = GatewayMessageCreateEvent(
            rawMap: [:], content: "spam", author: ["id": .string("u"), "username": .string("tester")],
            username: "tester", displayName: "tester", channelID: "c", userID: "u",
            guildID: "g", messageID: "live-ban-event", isBot: false, avatarHash: nil)
        await service.processMessageRuleEvent(event: message, channelType: 0)

        XCTAssertEqual(accumulator.mockLogs, ["ban:g:u:Spam from tester:3600"])
        XCTAssertTrue(accumulator.mockDMs.isEmpty, "The ordinary reply must not run once moderation bans the author")
    }

    // MARK: - Live reaction and slash-command triggers

    private func gatewayJSON(_ text: String) throws -> DiscordJSON {
        try JSONDecoder().decode(DiscordJSON.self, from: Data(text.utf8))
    }

    private func reactionPayload(user: String, emoji: String) throws -> DiscordJSON {
        try gatewayJSON(#"""
        {"user_id":"\#(user)","channel_id":"chan-9","message_id":"msg-9","guild_id":"guild-123",
         "member":{"roles":["role-1"],"user":{"id":"\#(user)","username":"name-\#(user)"}},
         "emoji":{"id":null,"name":"\#(emoji)"}}
        """#)
    }

    func testReactionGatewayPayloadRunsTheStarredMessagesTemplate() async throws {
        var starred = try XCTUnwrap(AutomationTemplate.catalog(for: .automation).first { $0.id == "star-reaction-log" }).rule
        starred.id = "starred"
        model.automationStore.setRulesForTesting([starred])

        // Discord sends the star without the variation selector the template carries.
        let first = try XCTUnwrap(AppModel.automationReactionEvent(from: try reactionPayload(user: "user-1", emoji: "⭐"), botUserId: "bot"))
        await model.fireAutomations(for: first)
        let second = try XCTUnwrap(AppModel.automationReactionEvent(from: try reactionPayload(user: "user-2", emoji: "⭐️"), botUserId: "bot"))
        await model.fireAutomations(for: second)
        let other = try XCTUnwrap(AppModel.automationReactionEvent(from: try reactionPayload(user: "user-3", emoji: "👍"), botUserId: "bot"))
        await model.fireAutomations(for: other)

        XCTAssertEqual(accumulator.mockLogs, [
            "name-user-1 starred a message in #test-channel",
            "name-user-2 starred a message in #test-channel"
        ], "Each member's star on the same message is its own run")
        XCTAssertNil(AppModel.automationReactionEvent(from: try reactionPayload(user: "bot", emoji: "⭐"), botUserId: "bot"),
                     "The bot's own reactions never trigger rules")
    }

    func testSlashInteractionRunsTheAutomationCommand() async throws {
        let report = Automations.Rule(id: "report", name: "/report command", trigger: .init(kind: .slashCommand, commandName: "report"),
            steps: [.init(kind: .log, logText: "Report from {username}: {message}")])
        model.automationStore.setRulesForTesting([report])
        let raw = try gatewayJSON(#"""
        {"id":"interaction-1","token":"interaction-token","type":2,"guild_id":"guild-123","channel_id":"chan-9",
         "member":{"roles":[],"user":{"id":"user-1","username":"reporter"}},
         "data":{"name":"report","options":[{"type":3,"name":"text","value":"someone is spamming"}]}}
        """#)
        guard case let .object(map) = raw, case let .object(data)? = map["data"] else { return XCTFail("fixture") }
        let interaction = GatewayInteractionCreateEvent(
            interactionID: "interaction-1", interactionToken: "interaction-token", interactionType: 2,
            commandName: "report", data: data, rawMap: map)

        await model.fireAutomations(for: AppModel.automationSlashEvent(from: interaction, name: "report"))

        XCTAssertEqual(accumulator.mockLogs, ["Report from reporter: /report someone is spamming"])
    }

    func testAutomationSlashCommandsAreRegisteredWithoutTakingBuiltInNames() {
        let rules = Automations.Rule(id: "rules", name: "/rules command", trigger: .init(kind: .slashCommand, commandName: "Rules"), steps: [])
        let clash = Automations.Rule(id: "clash", name: "Clash", trigger: .init(kind: .slashCommand, commandName: "help"), steps: [])
        var disabled = rules
        disabled.id = "off"
        disabled.enabled = false
        disabled.trigger.commandName = "offline"
        model.automationStore.setRulesForTesting([rules, clash, disabled])

        XCTAssertEqual(model.automationSlashCommandNames(), ["rules"])
        let names = model.allSlashCommandDefinitions().compactMap { $0["name"] as? String }
        XCTAssertEqual(names.filter { $0 == "rules" }.count, 1)
        XCTAssertEqual(names.filter { $0 == "help" }.count, 1, "The built-in /help keeps its name")
        XCTAssertFalse(names.contains("offline"))
    }

    func testRemoveTimeoutExecutesWithoutSuppressingOrdinaryAutomations() async {
        let release = Automations.Rule(id: "release", name: "Release", category: .moderation,
            trigger: .init(kind: .messageCreated), steps: [.init(kind: .modifyMember, memberOp: .removeTimeout)])
        let greeting = Automations.Rule(id: "greeting", name: "Greeting", trigger: .init(kind: .messageCreated), steps: [
            .init(kind: .sendMessage, sendTarget: .directMessage, content: "hello")
        ])
        model.automationStore.setRulesForTesting([release, greeting])
        let event = SwiftBotEvent.message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: "release-event", content: "hello", isDirectMessage: false, authorIsBot: false))
        await model.fireAutomations(for: event)
        XCTAssertEqual(accumulator.mockLogs, ["removeTimeout:g:u"])
        XCTAssertEqual(accumulator.mockDMs.count, 1)
    }

    func testNewModerationActionsSimulateWithoutCallingLiveDependencies() async {
        let rule = Automations.Rule(name: "Simulated enforcement", category: .moderation,
            trigger: .init(kind: .messageCreated), steps: [
                .init(kind: .modifyMember, memberOp: .ban, kickReason: "Spam by {username}", banDeleteMessageSeconds: 0),
                .init(kind: .modifyMember, memberOp: .removeTimeout)
            ])
        let event = SwiftBotEvent.message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: "sim-event", content: "hello", isDirectMessage: false, authorIsBot: false))
        let result = await automationService.simulate(rule: rule, event: event)
        XCTAssertTrue(result.triggerMatched && result.filtersMatched)
        XCTAssertEqual(result.stepTraces.count, 2)
        XCTAssertTrue(result.stepTraces[0].detail.contains("Would ban user u"))
        XCTAssertTrue(result.stepTraces[0].detail.contains("Spam by tester"))
        XCTAssertTrue(result.stepTraces[1].detail.contains("Would remove timeout"))
        XCTAssertTrue(accumulator.mockLogs.isEmpty)
    }

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

    func testSimulationTracesEachStepOnItsOwnRowWithoutWaiting() async {
        // log and delay record no dry-run action, which used to shift the
        // send step's detail onto the wrong row; the delay used to be waited out.
        let rule = Automations.Rule(
            id: "r-sim-steps",
            name: "Step Alignment",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [],
            steps: [
                Automations.Step(id: "s-log", kind: .log, logText: "Saw {username}"),
                Automations.Step(id: "s-wait", kind: .delay, delaySeconds: 600),
                Automations.Step(id: "s-send", kind: .sendMessage, sendTarget: .sameChannel, content: "Hi {username}")
            ]
        )
        let event = Automations.SimulationInput.suggested(for: rule).event(for: rule.trigger.kind)

        let started = Date()
        let result = await automationService.simulate(rule: rule, event: event)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        XCTAssertEqual(result.stepTraces.map(\.stepId), ["s-log", "s-wait", "s-send"])
        XCTAssertTrue(result.stepTraces[0].detail.contains("Would log: \"Saw john_doe\""))
        XCTAssertTrue(result.stepTraces[1].detail.contains("Would wait 10m"))
        XCTAssertTrue(result.stepTraces[2].executed)
        XCTAssertTrue(result.stepTraces[2].detail.contains("Would send message"))
        XCTAssertTrue(result.stepTraces[2].detail.contains("Hi john_doe"))
    }

    func testSimulationInputSuggestsValuesThatSatisfyTheRule() {
        let rule = Automations.Rule(
            id: "r-suggest",
            name: "Suggest",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [
                Automations.Filter(id: "f-chan", kind: .inChannel, channelIds: ["123456"]),
                Automations.Filter(id: "f-text", kind: .messageContains, text: "ping")
            ],
            steps: []
        )
        let input = Automations.SimulationInput.suggested(for: rule)
        XCTAssertEqual(input.channelId, "123456")
        XCTAssertEqual(input.messageContent, "ping")
    }

    private func roleFilterRule(_ filter: Automations.Filter) -> Automations.Rule {
        Automations.Rule(
            id: "r-role-\(filter.id)",
            name: "Role Filter",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            filterLogic: .all,
            filters: [filter],
            steps: []
        )
    }

    private func messageEvent(roleIds: [String]?) -> SwiftBotEvent {
        SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-123",
            userId: "user-1",
            username: "bob",
            roleIds: roleIds,
            channelId: "chat-1",
            messageId: UUID().uuidString,
            content: "hello",
            isDirectMessage: false,
            authorIsBot: false
        ))
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
