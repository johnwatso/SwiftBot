import XCTest
@testable import SwiftBot

final class SwiftMinerDMSenderTests: XCTestCase {

    private actor Spy {
        var sentEmbeds: [(userId: String, embed: [String: Any])] = []
        var welcomedUserIds: Set<String> = []
        var completedUserIds: Set<String> = []
        var infoLogs: [String] = []
        var errorLogs: [String] = []
        var events: [String] = []
        var discordNames: [String: String] = [:]

        func recordSend(userId: String, embed: [String: Any]) {
            sentEmbeds.append((userId, embed))
        }

        func markWelcomed(_ userId: String) {
            welcomedUserIds.insert(userId)
        }

        func markCompleted(_ userId: String) {
            completedUserIds.insert(userId)
        }

        func logInfo(_ message: String) {
            infoLogs.append(message)
        }

        func logError(_ message: String) {
            errorLogs.append(message)
        }

        func recordEvent(_ message: String) {
            events.append(message)
        }

        func setDiscordName(_ userId: String, name: String) {
            discordNames[userId] = name
        }
    }

    private func makeSender(spy: Spy) -> SwiftMinerDMSender {
        SwiftMinerDMSender(dependencies: .init(
            sendDMEmbed: { userId, embed in
                await spy.recordSend(userId: userId, embed: embed)
            },
            discordNameForUserId: { userId in
                await spy.discordNames[userId]
            },
            hasUserBeenWelcomed: { userId in
                await spy.welcomedUserIds.contains(userId)
            },
            hasUserCompletedOnboarding: { userId in
                await spy.completedUserIds.contains(userId)
            },
            markUserWelcomed: { userId in
                await spy.markWelcomed(userId)
            },
            markUserCompletedOnboarding: { userId in
                await spy.markCompleted(userId)
            },
            logInfo: { message in
                await spy.logInfo(message)
            },
            logError: { message in
                await spy.logError(message)
            },
            recordEvent: { message in
                await spy.recordEvent(message)
            }
        ))
    }

    // MARK: - Basic Send

    func testSendDeliversEmbed() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .linked, twitchUsername: "tester")
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.userId, "user-1")
    }

    func testSendFailureReturnsFalse() async {
        let spy = Spy()
        let sender = SwiftMinerDMSender(dependencies: .init(
            sendDMEmbed: { _, _ in throw NSError(domain: "Test", code: 1) },
            discordNameForUserId: { _ in nil },
            hasUserBeenWelcomed: { _ in true },
            hasUserCompletedOnboarding: { _ in true },
            markUserWelcomed: { _ in },
            markUserCompletedOnboarding: { _ in },
            logInfo: { _ in },
            logError: { _ in },
            recordEvent: { _ in }
        ))

        let request = SwiftMinerDMRequest(messageType: .linked)
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertFalse(ok)
    }

    // MARK: - Welcome Prepend

    func testFirstSetupPrependsWelcome() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .setup, activationCode: "CODE")
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 2, "Should send welcome then setup")
        let welcomed = await spy.welcomedUserIds
        XCTAssertTrue(welcomed.contains("user-1"))
    }

    func testFirstLinkedPrependsWelcome() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .linked, twitchUsername: "tester")
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 2, "Should send welcome then linked")
    }

    func testSecondSetupDoesNotRepeatWelcome() async {
        let spy = Spy()
        await spy.markWelcomed("user-1")
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .setup)
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 1, "Should only send setup, no duplicate welcome")
    }

    func testReauthDoesNotSendWelcome() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .reauth)
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 1)
        let welcomed = await spy.welcomedUserIds
        XCTAssertFalse(welcomed.contains("user-1"))
    }

    func testDebugModeDoesNotSendWelcomePrepend() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .setup, debug: true, activationCode: "CODE")
        let ok = await sender.send(request: request, discordUserId: "user-1")

        XCTAssertTrue(ok)
        let sent = await spy.sentEmbeds
        XCTAssertEqual(sent.count, 1, "Debug should not trigger welcome prepend")
    }

    // MARK: - Onboarding State Transitions

    func testSetupDoesNotMarkOnboardingCompleted() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .setup)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let completed = await spy.completedUserIds
        XCTAssertFalse(completed.contains("user-1"), "Setup should not mark onboarding as completed")
    }

    func testLinkedMarksOnboardingCompleted() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .linked)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let completed = await spy.completedUserIds
        XCTAssertTrue(completed.contains("user-1"), "Linked should mark onboarding as completed")
    }

    func testWelcomeMarksUserAsWelcomed() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .welcome)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let welcomed = await spy.welcomedUserIds
        XCTAssertTrue(welcomed.contains("user-1"))
    }

    // MARK: - Debug Isolation

    func testDebugModeDoesNotMutateWelcomeState() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .welcome, debug: true)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let welcomed = await spy.welcomedUserIds
        XCTAssertFalse(welcomed.contains("user-1"))
    }

    func testDebugModeDoesNotMutateCompletionState() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .linked, debug: true)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let completed = await spy.completedUserIds
        XCTAssertFalse(completed.contains("user-1"))
    }

    func testDebugModeMarksEventAsDebug() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let request = SwiftMinerDMRequest(messageType: .linked, debug: true)
        _ = await sender.send(request: request, discordUserId: "user-1")

        let events = await spy.events
        XCTAssertTrue(events.first?.contains("DEBUG") == true)
    }

    // MARK: - Preview (No Side Effects)

    func testPreviewDoesNotSendAnything() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        let embed = await sender.preview(request: .init(messageType: .dropClaimed), discordUserId: "user-1")

        XCTAssertFalse(embed.isEmpty)
        let sent = await spy.sentEmbeds
        XCTAssertTrue(sent.isEmpty, "Preview should never call sendDMEmbed")
    }

    func testPreviewDoesNotMutateState() async {
        let spy = Spy()
        let sender = makeSender(spy: spy)

        _ = await sender.preview(request: .init(messageType: .welcome), discordUserId: "user-1")

        let welcomed = await spy.welcomedUserIds
        XCTAssertFalse(welcomed.contains("user-1"))
    }
}
