import XCTest
@testable import SwiftBot

@MainActor
final class AutomationRecoveryTests: XCTestCase {
    actor Counter { var value = 0; func increment() { value += 1 } }
    actor Recorder { var values: [String] = []; func record(_ value: String) { values.append(value) } }
    actor RuleBox {
        var rule: Automations.Rule
        init(_ rule: Automations.Rule) { self.rule = rule }
        func set(_ next: Automations.Rule) { rule = next }
    }
    private func engine(
        counter: Counter, url: URL? = nil, failingSend: Bool = false,
        webhooks: Recorder? = nil,
        canExecute: @escaping @Sendable () async -> Bool = { true },
        ruleValid: @escaping @Sendable (Automations.Rule) async -> Bool = { _ in true },
        eventValid: @escaping @Sendable (Automations.Trigger, String, String) async -> Bool = { _, _, _ in true }
    ) -> AutomationService {
        let deps = AutomationService.Dependencies(
            canExecute: canExecute, scheduledRuleStillValid: ruleValid, scheduledEventStillValid: eventValid,
            sendMessage: { _, _, _ in
                if failingSend { throw NSError(domain: "Test", code: 403) }
                await counter.increment()
            },
            sendPayloadMessage: { _, _, _ in await counter.increment() },
            sendDM: { _, _ in }, addReaction: { _, _, _, _ in }, deleteMessage: { _, _, _ in },
            addRole: { _, _, _, _ in }, removeRole: { _, _, _, _ in }, timeoutMember: { _, _, _, _ in },
            kickMember: { _, _, _, _ in }, moveMember: { _, _, _, _ in }, sendWebhook: { url, _ in await webhooks?.record(url) },
            resolveChannelName: { _, _ in "general" }, resolveGuildName: { _ in "guild" }, log: { _ in },
            recordAutomationRun: { _, _, _, _, _, _ in }
        )
        return AutomationService(aiService: DiscordAIService(), dependencies: deps, journalURL: url)
    }
    private func rule(delay: Int = 0) -> Automations.Rule {
        Automations.Rule(id: "recovery", name: "Recovery", enabled: true, trigger: .init(kind: .messageCreated), steps: [
            .init(id: "delay", kind: .delay, delaySeconds: delay),
            .init(id: "send", kind: .sendMessage, content: "recovered")
        ])
    }
    private var event: SwiftBotEvent {
        .message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: "unique-event", content: "hello", isDirectMessage: false, authorIsBot: false))
    }

    func testCompletedMessageRunDoesNotRepeat() async {
        let counter = Counter()
        let service = engine(counter: counter)
        await service.execute(rule: rule(), event: event, token: "test-token")
        await service.execute(rule: rule(), event: event, token: "test-token")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testPausedDelayResumesOnAnotherNodeFromCheckpoint() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let original = engine(counter: counter, url: url)
        let work = Task { await original.execute(rule: rule(delay: 2), event: event, token: "test-token") }
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([AutomationExecutionCheckpoint].self, from: data), records.first?.wakeAt != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let drained = await original.pauseAndDrain()
        await work.value
        XCTAssertTrue(drained)
        let prior = await counter.value
        XCTAssertEqual(prior, 0)
        let backup = engine(counter: counter, url: url)
        await backup.resumePendingExecutions(token: "test-token", rules: [rule(delay: 2)])
        for _ in 0..<60 {
            if await counter.value == 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let recovered = await counter.value
        XCTAssertEqual(recovered, 1)
        let data = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-token"))
    }

    func testUnacknowledgedActionIsHeldForReview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var journal = AutomationExecutionJournal(fileURL: url)
        var record = AutomationExecutionCheckpoint(id: "recovery:unique-event", rule: rule(), event: event)
        record.nextStep = 1
        record.inFlightStep = 1
        try journal.save(record)
        let counter = Counter()
        let service = engine(counter: counter, url: url)
        await service.execute(rule: rule(), event: event, token: "test-token")
        await service.resumePendingExecutions(token: "test-token", rules: [rule()])
        try? await Task.sleep(for: .milliseconds(50))
        let count = await counter.value
        XCTAssertEqual(count, 0)
    }

    func testNestedConditionGroupsAndNot() throws {
        let service = engine(counter: Counter())
        var grouped = rule()
        grouped.filters = []
        grouped.conditionGroups = [
            .init(id: "root", logic: .all, filters: [.init(kind: .messageContains, text: "hello")]),
            .init(id: "choice", parentId: "root", logic: .any, filters: [.init(kind: .userIsOneOf, userIds: ["u"]), .init(kind: .fromBot, boolValue: true)]),
            .init(id: "exclude", parentId: "root", logic: .none, filters: [.init(kind: .messageContains, text: "bad")])
        ]
        try grouped.validate()
        XCTAssertEqual(service.evaluate(event: event, in: [grouped]).count, 1)
        grouped.conditionGroups?[2].filters[0].text = "hello"
        XCTAssertTrue(service.evaluate(event: event, in: [grouped]).isEmpty)
        grouped.conditionGroups?[0].parentId = "choice"
        XCTAssertThrowsError(try grouped.validate())
    }

    func testCountersDriveOtherwiseAndDoNotCountDuplicateEvents() async throws {
        let counter = Counter()
        let service = engine(counter: counter)
        let counting = Automations.Rule(id: "counting", name: "Escalate", trigger: .init(kind: .messageCreated), steps: [
            .init(id: "remember", kind: .incrementCounter, counterName: "incidents", counterScope: .user, counterLifetimeSeconds: 600),
            .init(kind: .branch, conditions: [.init(kind: .counterAtLeast, intValue: 3, counterName: "incidents", counterScope: .user)]),
            .init(kind: .sendMessage, content: "Escalate"),
            .init(kind: .otherwise),
            .init(kind: .log, logText: "Not yet"),
            .init(kind: .endBranch)
        ])
        try counting.validate()
        for id in ["one", "one", "two", "three"] {
            let input = SwiftBotEvent.message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: id, content: "hello", isDirectMessage: false, authorIsBot: false))
            await service.execute(rule: counting, event: input, token: "test")
        }
        let sends = await counter.value
        XCTAssertEqual(sends, 1)
        let diagnostics = await service.runDiagnostics()
        XCTAssertTrue(diagnostics.contains { $0.traces.contains { $0.detail == "Skipped: other branch selected" } })
    }

    func testSimulationDoesNotMutateRememberedCounters() async throws {
        let service = engine(counter: Counter())
        let remember = Automations.Rule(name: "Remember", trigger: .init(kind: .messageCreated), steps: [.init(kind: .incrementCounter, counterName: "incidents", counterLifetimeSeconds: 600)])
        let check = Automations.Rule(name: "Check", trigger: .init(kind: .messageCreated), filters: [.init(kind: .counterAtLeast, intValue: 1, counterName: "incidents")], steps: [.init(kind: .log, logText: "exists")])
        _ = await service.simulate(rule: remember, event: event)
        let before = await service.matchingRules(event: event, in: [check])
        XCTAssertTrue(before.isEmpty)
        await service.execute(rule: remember, event: event, token: "test")
        let after = await service.matchingRules(event: event, in: [check])
        XCTAssertEqual(after.count, 1)
    }

    func testCooldownSurvivesRestartAndIsScopedToUser() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(AutomationExecutionJournal.fileName)
        let counter = Counter()
        var cooled = rule()
        cooled.cooldown = .init(seconds: 600, scope: .user)
        await engine(counter: counter, url: url).execute(rule: cooled, event: event, token: "test")
        let recovered = engine(counter: counter, url: url)
        let duplicateUser = SwiftBotEvent.message(.init(guildId: "g", userId: "u", username: "tester", channelId: "c", messageId: "second", content: "hello", isDirectMessage: false, authorIsBot: false))
        let differentUser = SwiftBotEvent.message(.init(guildId: "g", userId: "other", username: "other", channelId: "c", messageId: "third", content: "hello", isDirectMessage: false, authorIsBot: false))
        await recovered.execute(rule: cooled, event: duplicateUser, token: "test")
        await recovered.execute(rule: cooled, event: differentUser, token: "test")
        let sends = await counter.value
        XCTAssertEqual(sends, 2)
    }

    func testCounterExpiryAndScope() {
        var memory = AutomationMemory()
        let now = Date()
        let key = AutomationMemory.scopeKey(name: "incidents", scope: .user, ruleId: "r", event: event)
        memory.counters[key] = [now.addingTimeInterval(-1), now.addingTimeInterval(60)]
        XCTAssertEqual(memory.count(name: "incidents", scope: .user, ruleId: "r", event: event, now: now), 1)
        XCTAssertEqual(memory.count(name: "incidents", scope: .user, ruleId: "r", event: event, now: now.addingTimeInterval(61)), 0)
    }

    func testDailySchedulePreservesTimeAcrossAucklandDaylightSaving() throws {
        let schedule = Automations.Schedule(startAt: "2026-09-25T21:00:00Z", timeZone: "Pacific/Auckland", repeatKind: .daily)
        try schedule.validate()
        let after = try XCTUnwrap(Automations.Schedule.parse("2026-09-26T22:00:00Z"))
        let occurrence = try XCTUnwrap(schedule.latestOccurrence(at: after))
        XCTAssertEqual(occurrence, Automations.Schedule.parse("2026-09-26T20:00:00Z"))
        XCTAssertEqual(schedule.nextOccurrence(after: after), Automations.Schedule.parse("2026-09-27T20:00:00Z"))
    }

    func testScheduledEventTimesDeduplicateAndCancel() async throws {
        let counter = Counter()
        let service = engine(counter: counter)
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        let serverEvent = DiscordScheduledEvent(id: "event", guildId: "g", name: "Season 12", description: "Live", scheduledStartTime: iso, scheduledEndTime: nil, status: 1, image: nil, userCount: nil)
        var announcement = Automations.Rule(id: "announcement", name: "Season", category: .events, trigger: .init(kind: .scheduledEvent, guildId: "g", eventId: "event"), steps: [.init(kind: .sendMessage, sendTarget: .specificChannel, channelId: "c", content: "Live", embed: .init(title: "{eventName} is now live!"))])
        await service.runScheduledRules([announcement], events: [serverEvent], token: "test", now: now)
        for _ in 0..<30 { if await counter.value == 1 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        await service.runScheduledRules([announcement], events: [serverEvent], token: "test", now: now.addingTimeInterval(10))
        var sends = await counter.value
        XCTAssertEqual(sends, 1)
        let movedEvent = DiscordScheduledEvent(id: "event", guildId: "g", name: "Season 12", description: nil,
            scheduledStartTime: ISO8601DateFormatter().string(from: now.addingTimeInterval(3600)), scheduledEndTime: nil, status: 1, image: nil, userCount: nil)
        await service.runScheduledRules([announcement], events: [movedEvent], token: "test", now: now.addingTimeInterval(3600))
        try? await Task.sleep(for: .milliseconds(30))
        sends = await counter.value
        XCTAssertEqual(sends, 1, "Rescheduling an already announced event must not publish it again")
        announcement.id = "cancelled"
        let cancelled = DiscordScheduledEvent(id: "event", guildId: "g", name: "Season 12", description: nil, scheduledStartTime: iso, scheduledEndTime: nil, status: 4, image: nil, userCount: nil)
        await service.runScheduledRules([announcement], events: [cancelled], token: "test", now: now)
        sends = await counter.value
        XCTAssertEqual(sends, 1)
        announcement.id = "missed"
        await service.runScheduledRules([announcement], events: [serverEvent], token: "test", now: now.addingTimeInterval(301))
        sends = await counter.value
        XCTAssertEqual(sends, 1)
        announcement.id = "offset"
        announcement.trigger.eventOffsetSeconds = -3600
        await service.runScheduledRules([announcement], events: [serverEvent], token: "test", now: now.addingTimeInterval(-3600))
        for _ in 0..<30 { if await counter.value == 2 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        sends = await counter.value
        XCTAssertEqual(sends, 2)
        announcement.id = "custom"
        announcement.trigger.eventCustomTime = ISO8601DateFormatter().string(from: now.addingTimeInterval(7200))
        await service.runScheduledRules([announcement], events: [serverEvent], token: "test", now: now.addingTimeInterval(7200))
        for _ in 0..<30 { if await counter.value == 3 { break }; try? await Task.sleep(for: .milliseconds(10)) }
        sends = await counter.value
        XCTAssertEqual(sends, 3)
    }

    func testLegacyRulesStillDecodeAndUnbalancedBranchIsRejected() throws {
        let data = try JSONEncoder().encode(rule())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["conditionGroups", "cooldown", "failurePolicy"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(Automations.Rule.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.steps.count, 2)
        var invalid = decoded
        invalid.steps = [.init(kind: .otherwise)]
        XCTAssertThrowsError(try invalid.validate())
    }

    func testFailurePolicyStopsLaterStepsAndReportsError() async {
        let service = engine(counter: Counter(), failingSend: true)
        var failing = Automations.Rule(id: "failure", name: "Fail", trigger: .init(kind: .messageCreated), steps: [
            .init(kind: .sendMessage, sendTarget: .sameChannel, content: "Failure"),
            .init(kind: .incrementCounter, counterName: "after-send")
        ], failurePolicy: .stopOnError)
        let check = Automations.Rule(name: "Check", trigger: .init(kind: .messageCreated),
            filters: [.init(kind: .counterAtLeast, intValue: 1, counterName: "after-send")], steps: [.init(kind: .log, logText: "Found")])
        await service.execute(rule: failing, event: event, token: "test")
        var matches = await service.matchingRules(event: event, in: [check])
        XCTAssertTrue(matches.isEmpty)
        let diagnostics = await service.runDiagnostics()
        XCTAssertEqual(diagnostics.first?.status, "Failed")
        XCTAssertEqual(diagnostics.first?.traces.count, 1)
        failing.id = "continue"
        failing.failurePolicy = .continueOnError
        await service.execute(rule: failing, event: event, token: "test")
        matches = await service.matchingRules(event: event, in: [check])
        XCTAssertEqual(matches.count, 1)
    }

    func testScheduledEffectsRecheckEventAndOwnership() async {
        let counter = Counter()
        var payload = SwiftBotEvent.MessagePayload(guildId: "g", userId: "", username: "Schedule", channelId: "c",
            messageId: "schedule:123", content: "", isDirectMessage: false, authorIsBot: false)
        payload.automationTrigger = .scheduledEvent
        let announcement = Automations.Rule(name: "Event", category: .events, trigger: .init(kind: .scheduledEvent, guildId: "g", eventId: "e"),
            steps: [.init(kind: .sendMessage, sendTarget: .specificChannel, channelId: "c", content: "Live")])
        let cancelled = engine(counter: counter, eventValid: { _, _, _ in false })
        await cancelled.execute(rule: announcement, event: .message(payload), token: "test")
        let diagnostics = await cancelled.runDiagnostics()
        XCTAssertTrue(diagnostics.first?.errors.first?.contains("cancelled") == true)
        let disabled = engine(counter: counter, ruleValid: { _ in false })
        await disabled.execute(rule: announcement, event: .message(payload), token: "test")
        let cancelledRules = await disabled.runDiagnostics()
        XCTAssertTrue(cancelledRules.first?.errors.first?.contains("disabled") == true)
        let standby = engine(counter: counter, canExecute: { false })
        await standby.execute(rule: announcement, event: .message(payload), token: "test")
        let sends = await counter.value
        XCTAssertEqual(sends, 0)
        let records = await standby.runDiagnostics()
        XCTAssertTrue(records.isEmpty)
    }

    func testCorruptMemoryStopsExecution() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("invalid".utf8).write(to: folder.appendingPathComponent(AutomationMemory.fileName))
        let counter = Counter()
        await engine(counter: counter, url: folder.appendingPathComponent(AutomationExecutionJournal.fileName))
            .execute(rule: rule(), event: event, token: "test")
        let sends = await counter.value
        XCTAssertEqual(sends, 0)
    }

    func testSavedBranchDecisionSurvivesRestart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(AutomationExecutionJournal.fileName)
        let counter = Counter()
        let branching = Automations.Rule(id: "branch", name: "Branch", trigger: .init(kind: .messageCreated), steps: [
            .init(id: "if", kind: .branch, conditions: [.init(kind: .counterBelow, intValue: 1, counterName: "incidents")]),
            .init(id: "wait", kind: .delay, delaySeconds: 1),
            .init(id: "send", kind: .sendMessage, content: "Original branch"),
            .init(id: "else", kind: .otherwise),
            .init(id: "log", kind: .log, logText: "Changed state"),
            .init(id: "end", kind: .endBranch)
        ])
        let original = engine(counter: counter, url: url)
        let pending = Task { await original.execute(rule: branching, event: event, token: "test") }
        var checkpointReached = false
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([AutomationExecutionCheckpoint].self, from: data),
               records.first?.wakeAt != nil { checkpointReached = true; break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(checkpointReached)
        _ = await original.pauseAndDrain()
        await pending.value
        var memory = AutomationMemory()
        memory.counters[AutomationMemory.scopeKey(name: "incidents", scope: .user, ruleId: branching.id, event: event)] = [Date().addingTimeInterval(600)]
        try JSONEncoder().encode(memory).write(to: folder.appendingPathComponent(AutomationMemory.fileName))
        let recovered = engine(counter: counter, url: url)
        await recovered.resumePendingExecutions(token: "test", rules: [branching])
        for _ in 0..<60 {
            if await counter.value == 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        let sends = await counter.value
        XCTAssertEqual(sends, 1)
    }

    // MARK: - Scheduled runs and edits

    /// Mirrors AppModel's `scheduledRuleStillValid` against a rule the test edits.
    private func scheduledEngine(counter: Counter, current: RuleBox) -> AutomationService {
        engine(counter: counter, ruleValid: { admitted in
            let rule = await current.rule
            return rule.enabled && rule.isExecutionEquivalent(to: admitted)
        })
    }

    private func delayedSchedule(id: String) -> (Automations.Rule, SwiftBotEvent) {
        let rule = Automations.Rule(id: id, name: "Timer", trigger: .init(kind: .schedule, guildId: "g",
            schedule: .init(startAt: ISO8601DateFormatter().string(from: Date()), timeZone: "Pacific/Auckland", repeatKind: .interval, intervalSeconds: 60)),
            steps: [.init(kind: .delay, delaySeconds: 1), .init(kind: .sendMessage, sendTarget: .specificChannel, channelId: "c", content: "Scheduled")])
        var payload = SwiftBotEvent.MessagePayload(guildId: "g", userId: "", username: "Schedule", channelId: "c",
            messageId: "schedule:\(id)", content: "", isDirectMessage: false, authorIsBot: false)
        payload.automationTrigger = .schedule
        return (rule, .message(payload))
    }

    private func settle(_ service: AutomationService) async -> AutomationRunDiagnostic? {
        for _ in 0..<60 {
            if let record = await service.runDiagnostics().first, record.status != "Waiting", record.status != "Running" { return record }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return await service.runDiagnostics().first
    }

    func testEditedScheduledConditionsCancelAPendingRun() async throws {
        let counter = Counter()
        let (scheduled, event) = delayedSchedule(id: "conditions")
        let current = RuleBox(scheduled)
        let service = scheduledEngine(counter: counter, current: current)
        await service.execute(rule: scheduled, event: event, token: "test")
        var edited = scheduled
        edited.conditionGroups = [.init(id: "root", logic: .all, filters: [.init(kind: .messageContains, text: "never")])]
        await current.set(edited)

        let record = await settle(service)
        XCTAssertTrue(record?.errors.first?.contains("edited") == true)
        let sends = await counter.value
        XCTAssertEqual(sends, 0)
    }

    func testEditedFailurePolicyCancelsAPendingRun() async throws {
        let counter = Counter()
        let (scheduled, event) = delayedSchedule(id: "policy")
        let current = RuleBox(scheduled)
        let service = scheduledEngine(counter: counter, current: current)
        await service.execute(rule: scheduled, event: event, token: "test")
        var edited = scheduled
        edited.failurePolicy = .stopOnError
        await current.set(edited)

        _ = await settle(service)
        let sends = await counter.value
        XCTAssertEqual(sends, 0)
    }

    func testRenamingAScheduledRuleKeepsItsPendingRun() async throws {
        let counter = Counter()
        let (scheduled, event) = delayedSchedule(id: "renamed")
        let current = RuleBox(scheduled)
        let service = scheduledEngine(counter: counter, current: current)
        await service.execute(rule: scheduled, event: event, token: "test")
        var edited = scheduled
        edited.name = "Renamed timer"
        await current.set(edited)

        let record = await settle(service)
        XCTAssertEqual(record?.status, "Success")
        let sends = await counter.value
        XCTAssertEqual(sends, 1)
    }

    // MARK: - Webhook credentials

    func testWebhookURLsStayInTheKeychain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let secret = "https://hooks.example.com/services/fixture-secret-token"
        let rulesURL = folder.appendingPathComponent("automations.json")
        let store = AutomationStore(fileURL: rulesURL)
        store.upsert(Automations.Rule(id: "hook", name: "Forward", trigger: .init(kind: .messageCreated), steps: [
            .init(id: "post", kind: .webhook, webhookUrl: secret, webhookContent: "{message}")
        ]))
        await store.saveNow()

        let saved = try XCTUnwrap(store.rules.first)
        let credentialId = try XCTUnwrap(saved.steps.first?.webhookCredentialId)
        XCTAssertNil(saved.steps.first?.webhookUrl)
        XCTAssertEqual(AutomationWebhookVault.url(for: credentialId), secret)
        XCTAssertFalse(try String(contentsOf: rulesURL, encoding: .utf8).contains("fixture-secret-token"))
        XCTAssertEqual(AutomationWebhookVault.urls(for: store.rules), [credentialId: secret], "What a Standby pulls over /v1/mesh/credentials")
        XCTAssertNoThrow(try saved.validate(), "A saved step validates without its URL")

        // The run resolves the URL; the journal keeps only the reference.
        let journalURL = folder.appendingPathComponent(AutomationExecutionJournal.fileName)
        let webhooks = Recorder()
        await engine(counter: Counter(), url: journalURL, webhooks: webhooks).execute(rule: saved, event: event, token: "test")
        let posted = await webhooks.values
        XCTAssertEqual(posted, [secret])
        XCTAssertFalse(try String(contentsOf: journalURL, encoding: .utf8).contains("fixture-secret-token"))

        // A blank URL keeps the saved one; a new URL replaces and deletes it.
        store.upsert(saved)
        XCTAssertEqual(store.rules.first?.steps.first?.webhookCredentialId, credentialId)
        var replaced = saved
        replaced.steps[0].webhookUrl = "https://hooks.example.com/services/rotated-token"
        store.upsert(replaced)
        XCTAssertNotEqual(store.rules.first?.steps.first?.webhookCredentialId, credentialId)
        XCTAssertNil(AutomationWebhookVault.url(for: credentialId))
        store.remove(id: "hook")
        await store.saveNow()
    }

    func testInlineWebhookURLsFromOlderFilesAreMovedToTheKeychain() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = Automations.Rule(id: "legacy", name: "Legacy", trigger: .init(kind: .messageCreated), steps: [
            .init(kind: .webhook, webhookUrl: "https://hooks.example.com/services/legacy-secret-token")
        ])
        let rulesURL = folder.appendingPathComponent("automations.json")
        try JSONEncoder().encode([legacy]).write(to: rulesURL)
        let journalURL = folder.appendingPathComponent(AutomationExecutionJournal.fileName)
        try JSONEncoder().encode([AutomationExecutionCheckpoint(id: "legacy:old", rule: legacy, event: event)]).write(to: journalURL)

        let store = AutomationStore(fileURL: rulesURL)
        store.load()
        await store.saveNow()
        let journal = AutomationExecutionJournal(fileURL: journalURL)

        XCTAssertNotNil(store.rules.first?.steps.first?.webhookCredentialId)
        XCTAssertNotNil(journal.records["legacy:old"]?.rule.steps.first?.webhookCredentialId)
        for url in [rulesURL, journalURL] {
            XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("legacy-secret-token"), url.lastPathComponent)
        }
    }

    func testIntervalScheduleRunsEachOccurrenceOnce() async throws {
        let counter = Counter()
        let service = engine(counter: counter)
        let now = Date()
        let scheduled = Automations.Rule(name: "Timer", trigger: .init(kind: .schedule, guildId: "g",
            schedule: .init(startAt: ISO8601DateFormatter().string(from: now), timeZone: "Pacific/Auckland", repeatKind: .interval, intervalSeconds: 60)),
            steps: [.init(kind: .sendMessage, sendTarget: .specificChannel, channelId: "c", content: "Scheduled")])
        try scheduled.validate()
        for seconds in [0.0, 1.0, 60.0] {
            await service.runScheduledRules([scheduled], events: [], token: "test", now: now.addingTimeInterval(seconds))
            let expected = seconds < 60 ? 1 : 2
            for _ in 0..<30 {
                if await counter.value == expected { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let sends = await counter.value
        XCTAssertEqual(sends, 2)
        XCTAssertTrue(service.evaluate(event: event, in: [scheduled]).isEmpty)
    }

}
