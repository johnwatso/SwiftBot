import XCTest
@testable import SwiftBot

final class AutomationConflictDetectorTests: XCTestCase {

    func testDuplicateVisibleResponsesAreReportedForOverlappingRules() {
        let first = messageRule(
            id: "welcome-1",
            name: "Welcome One",
            filters: [
                Automations.Filter(kind: .inChannel, channelIds: ["chat"])
            ],
            steps: [
                Automations.Step(kind: .sendMessage, sendTarget: .sameChannel, content: "Hello")
            ]
        )
        let second = messageRule(
            id: "welcome-2",
            name: "Welcome Two",
            filters: [
                Automations.Filter(kind: .inChannel, channelIds: ["chat"])
            ],
            steps: [
                Automations.Step(kind: .sendMessage, sendTarget: .sameChannel, content: "Hi")
            ]
        )

        let findings = AutomationConflictDetector.findings(in: [first, second])

        XCTAssertTrue(findings.contains { $0.title == "Two rules may respond to the same event" })
    }

    func testDistinctChannelsDoNotReportDuplicateResponses() {
        let first = messageRule(
            id: "chan-1",
            name: "Channel One",
            filters: [
                Automations.Filter(kind: .inChannel, channelIds: ["chat-1"])
            ],
            steps: [
                Automations.Step(kind: .sendMessage, sendTarget: .sameChannel, content: "Hello")
            ]
        )
        let second = messageRule(
            id: "chan-2",
            name: "Channel Two",
            filters: [
                Automations.Filter(kind: .inChannel, channelIds: ["chat-2"])
            ],
            steps: [
                Automations.Step(kind: .sendMessage, sendTarget: .sameChannel, content: "Hi")
            ]
        )

        let findings = AutomationConflictDetector.findings(in: [first, second])

        XCTAssertFalse(findings.contains { $0.title == "Two rules may respond to the same event" })
    }

    func testModerationDeleteWarnsWhenAnotherOverlappingRuleResponds() {
        let moderation = messageRule(
            id: "delete-spam",
            name: "Delete Spam",
            category: .moderation,
            filters: [
                Automations.Filter(kind: .messageContains, text: "spam")
            ],
            steps: [
                Automations.Step(kind: .modifyMessage, messageOp: .delete)
            ]
        )
        let response = messageRule(
            id: "reply-spam",
            name: "Reply To Spam",
            filters: [
                Automations.Filter(kind: .messageContains, text: "spam")
            ],
            steps: [
                Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "Please stop")
            ]
        )

        let findings = AutomationConflictDetector.findings(in: [moderation, response])

        XCTAssertTrue(findings.contains { $0.title == "Moderation may prevent another rule from responding" })
    }

    func testOppositeRoleMutationsAreReported() {
        let add = memberRule(
            id: "add-role",
            name: "Add Verified",
            steps: [
                Automations.Step(kind: .modifyMember, memberOp: .addRole, roleId: "verified")
            ]
        )
        let remove = memberRule(
            id: "remove-role",
            name: "Remove Verified",
            steps: [
                Automations.Step(kind: .modifyMember, memberOp: .removeRole, roleId: "verified")
            ]
        )

        let findings = AutomationConflictDetector.findings(in: [add, remove])

        XCTAssertTrue(findings.contains { $0.title == "Rules may fight over the same role" })
    }

    func testStepsAfterDestructiveActionAreReportedWithinRule() {
        let rule = messageRule(
            id: "delete-then-reply",
            name: "Delete Then Reply",
            steps: [
                Automations.Step(kind: .modifyMessage, messageOp: .delete),
                Automations.Step(kind: .sendMessage, sendTarget: .replyToTrigger, content: "Gone")
            ]
        )

        let findings = AutomationConflictDetector.findings(in: [rule])

        XCTAssertTrue(findings.contains { $0.title == "Steps after a destructive action may not run as expected" })
    }

    private func messageRule(
        id: String,
        name: String,
        category: Automations.Category = .automation,
        filters: [Automations.Filter] = [],
        steps: [Automations.Step]
    ) -> Automations.Rule {
        Automations.Rule(
            id: id,
            name: name,
            category: category,
            trigger: Automations.Trigger(kind: .messageCreated),
            filters: filters,
            steps: steps
        )
    }

    private func memberRule(
        id: String,
        name: String,
        steps: [Automations.Step]
    ) -> Automations.Rule {
        Automations.Rule(
            id: id,
            name: name,
            category: .moderation,
            trigger: Automations.Trigger(kind: .memberJoined),
            steps: steps
        )
    }
}
