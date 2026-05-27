import XCTest
@testable import SwiftBot

/// Covers `StepKind.aiTransform`: Apple Intelligence step that writes its
/// reply into the execution context's `aiOutput`, which subsequent steps
/// reference via the `{ai_output}` template token.
@MainActor
final class AutomationAITransformTests: XCTestCase {

    // MARK: - Stubs

    /// Deterministic stand-in for Apple Intelligence. Returns
    /// "<prefix> <userMessageContent>" so tests can assert that the rendered
    /// prompt (after {message}/{ai_output} substitution) reached the engine.
    struct PrefixEngine: AIEngine {
        let prefix: String
        func generate(messages: [Message]) async -> String? {
            let prompt = messages.last { $0.role == .user }?.content ?? ""
            return "\(prefix) \(prompt)"
        }
    }

    /// Engine that always returns nil — used to test the no-response branch.
    struct NilEngine: AIEngine {
        func generate(messages: [Message]) async -> String? { nil }
    }

    private final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }

    // MARK: - Helpers

    private func makeService(engine: any AIEngine, capture: LogCapture) -> AutomationService {
        let ai = DiscordAIService(
            engineFactory: { _ in engine },
            appleAvailability: { true }
        )
        let deps = AutomationService.Dependencies(
            sendMessage: { _, _, _ in },
            sendPayloadMessage: { _, _, _ in },
            sendDM: { _, _ in },
            addReaction: { _, _, _, _ in },
            deleteMessage: { _, _, _ in },
            addRole: { _, _, _, _ in },
            removeRole: { _, _, _, _ in },
            timeoutMember: { _, _, _, _ in },
            kickMember: { _, _, _, _ in },
            moveMember: { _, _, _, _ in },
            sendWebhook: { _, _ in },
            resolveChannelName: { _, _ in "general" },
            resolveGuildName: { _ in "TestGuild" },
            log: { capture.append($0) },
            recordAutomationRun: { _, _, _, _, _, _ in }
        )
        return AutomationService(aiService: ai, dependencies: deps)
    }

    private func messageEvent(content: String = "hello world") -> SwiftBotEvent {
        SwiftBotEvent.message(SwiftBotEvent.MessagePayload(
            guildId: "guild-1",
            userId: "user-1",
            username: "tester",
            channelId: "channel-1",
            messageId: "msg-1",
            content: content,
            isDirectMessage: false,
            authorIsBot: false
        ))
    }

    private func rule(steps: [Automations.Step]) -> Automations.Rule {
        Automations.Rule(
            id: "r-ai",
            name: "AI Test Rule",
            enabled: true,
            category: .automation,
            trigger: Automations.Trigger(kind: .messageCreated),
            steps: steps
        )
    }

    // MARK: - Tests

    /// An aiTransform step writes its reply into {ai_output}, and a later
    /// step renders it through the existing token substitution.
    func testAITransformOutputFlowsToLaterStep() async {
        let capture = LogCapture()
        let service = makeService(engine: PrefixEngine(prefix: "SUMMARY:"), capture: capture)

        let r = rule(steps: [
            Automations.Step(id: "s1", kind: .aiTransform, aiPrompt: "Summarise: {message}"),
            Automations.Step(id: "s2", kind: .log, logText: "out=[{ai_output}]")
        ])

        await service.execute(rule: r, event: messageEvent(content: "hello world"), token: "t")

        let logs = capture.snapshot
        XCTAssertTrue(
            logs.contains { $0 == "out=[SUMMARY: Summarise: hello world]" ||
                            $0 == "out=[SUMMARY: hello world]" },
            "Expected aiTransform output to substitute into {ai_output}. Got: \(logs)"
        )
        // The engine's stripLeadingSpeakerPrefix may strip a leading
        // "tester:" from the assistant reply — either form is acceptable.
    }

    /// A second aiTransform step overwrites the first. Documented limitation
    /// of the single-output design (see `ExecutionContext.aiOutput`).
    func testSecondAITransformOverwritesFirst() async {
        let capture = LogCapture()
        let service = makeService(engine: PrefixEngine(prefix: "AI:"), capture: capture)

        let r = rule(steps: [
            Automations.Step(id: "s1", kind: .aiTransform, aiPrompt: "first"),
            Automations.Step(id: "s2", kind: .aiTransform, aiPrompt: "second"),
            Automations.Step(id: "s3", kind: .log, logText: "{ai_output}")
        ])

        await service.execute(rule: r, event: messageEvent(), token: "t")

        let logs = capture.snapshot
        XCTAssertTrue(
            logs.contains { $0 == "AI: second" },
            "Expected the second aiTransform step's output to win. Got: \(logs)"
        )
        XCTAssertFalse(
            logs.contains { $0 == "AI: first" },
            "First aiTransform's output should have been overwritten."
        )
    }

    /// `{ai_output}` referenced before any aiTransform step expands to empty,
    /// matching the convention for missing event tokens.
    func testAIOutputBeforeAITransformExpandsToEmpty() async {
        let capture = LogCapture()
        let service = makeService(engine: PrefixEngine(prefix: "AI:"), capture: capture)

        let r = rule(steps: [
            Automations.Step(id: "s1", kind: .log, logText: "early=[{ai_output}]")
        ])

        await service.execute(rule: r, event: messageEvent(), token: "t")

        XCTAssertTrue(
            capture.snapshot.contains("early=[]"),
            "Expected {ai_output} to expand to empty before any aiTransform step. Got: \(capture.snapshot)"
        )
    }

    /// If Apple Intelligence returns nil, `{ai_output}` falls back to empty
    /// (same as a missing event token) rather than aborting the pipeline.
    func testNilAIResponseExpandsToEmptyAndContinues() async {
        let capture = LogCapture()
        let service = makeService(engine: NilEngine(), capture: capture)

        let r = rule(steps: [
            Automations.Step(id: "s1", kind: .aiTransform, aiPrompt: "anything"),
            Automations.Step(id: "s2", kind: .log, logText: "after=[{ai_output}]")
        ])

        await service.execute(rule: r, event: messageEvent(), token: "t")

        XCTAssertTrue(
            capture.snapshot.contains("after=[]"),
            "Expected pipeline to keep running with empty {ai_output} when AI returned nil. Got: \(capture.snapshot)"
        )
    }

    /// Model-level validation rejects an aiTransform step with an empty
    /// prompt before the runtime ever sees it.
    func testAITransformValidationRequiresPrompt() {
        let bad = Automations.Step(id: "x", kind: .aiTransform, aiPrompt: "   ")
        XCTAssertThrowsError(try bad.validate())

        let good = Automations.Step(id: "y", kind: .aiTransform, aiPrompt: "real prompt")
        XCTAssertNoThrow(try good.validate())
    }
}
