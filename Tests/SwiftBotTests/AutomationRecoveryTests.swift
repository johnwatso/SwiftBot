import XCTest
@testable import SwiftBot

@MainActor
final class AutomationRecoveryTests: XCTestCase {
    actor Counter { var value = 0; func increment() { value += 1 } }
    private func engine(counter: Counter, url: URL? = nil) -> AutomationService {
        let deps = AutomationService.Dependencies(
            sendMessage: { _, _, _ in await counter.increment() },
            sendPayloadMessage: { _, _, _ in await counter.increment() },
            sendDM: { _, _ in }, addReaction: { _, _, _, _ in }, deleteMessage: { _, _, _ in },
            addRole: { _, _, _, _ in }, removeRole: { _, _, _, _ in }, timeoutMember: { _, _, _, _ in },
            kickMember: { _, _, _, _ in }, moveMember: { _, _, _, _ in }, sendWebhook: { _, _ in },
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
}
