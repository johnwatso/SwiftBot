import XCTest
@testable import SwiftBot

@MainActor
final class WelcomeFlowServiceTests: XCTestCase {

    func testPublicAndDMWelcomeAreSent() async {
        let service = WelcomeFlowService()
        service.seedMemberCount(guildID: "guild-1", count: 41)

        var publicMessages: [(channelID: String, message: WelcomeFlowService.PublicMessage)] = []
        var directMessages: [(userID: String, content: String)] = []

        var settings = WelcomeFlowSettings()
        settings.publicWelcomeEnabled = true
        settings.publicChannelId = "welcome-channel"
        settings.publicMessageTemplate = "Welcome {userMention} to {server}! You are #{memberCount}."
        settings.dmWelcomeEnabled = true
        settings.dmMessageTemplate = "Hey {username}, welcome to {guildName}."

        let result = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { channelID, message in
                publicMessages.append((channelID, message))
                return true
            },
            sendDirectMessage: { userID, content in
                directMessages.append((userID, content))
            },
            grantRole: { _, _, _ in },
            fetchInvites: { _ in nil },
            log: { _ in }
        )

        XCTAssertTrue(result.publicMessageSent)
        XCTAssertTrue(result.directMessageSent)
        XCTAssertFalse(result.autoRoleGranted)
        XCTAssertEqual(publicMessages.first?.channelID, "welcome-channel")
        XCTAssertEqual(publicMessages.first?.message.content, "Welcome <@user-1> to Test Guild! You are #42.")
        XCTAssertNil(publicMessages.first?.message.embed)
        XCTAssertEqual(directMessages.first?.userID, "user-1")
        XCTAssertEqual(directMessages.first?.content, "Hey Taylor, welcome to Test Guild.")
    }

    func testPublicWelcomeCanRenderAsEmbed() async {
        let service = WelcomeFlowService()
        service.seedMemberCount(guildID: "guild-1", count: 41)

        var publicMessages: [(channelID: String, message: WelcomeFlowService.PublicMessage)] = []

        var settings = WelcomeFlowSettings()
        settings.publicWelcomeEnabled = true
        settings.publicChannelId = "welcome-channel"
        settings.publicMessageFormat = .embed
        settings.publicEmbedTitleTemplate = "Welcome to {server}"
        settings.publicMessageTemplate = "Hey {userMention}, you are member #{memberCount}."
        settings.publicEmbedFooterTemplate = "Member #{memberCount}"

        let result = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { channelID, message in
                publicMessages.append((channelID, message))
                return true
            },
            sendDirectMessage: { _, _ in },
            grantRole: { _, _, _ in },
            fetchInvites: { _ in nil },
            log: { _ in }
        )

        XCTAssertTrue(result.publicMessageSent)
        XCTAssertEqual(publicMessages.first?.channelID, "welcome-channel")
        XCTAssertNil(publicMessages.first?.message.content)
        XCTAssertEqual(publicMessages.first?.message.embed?.title, "Welcome to Test Guild")
        XCTAssertEqual(publicMessages.first?.message.embed?.description, "Hey <@user-1>, you are member #42.")
        XCTAssertEqual(publicMessages.first?.message.embed?.footer, "Member #42")
    }

    func testDuplicateJoinIsSuppressed() async {
        let service = WelcomeFlowService()
        var sendCount = 0

        var settings = WelcomeFlowSettings()
        settings.publicWelcomeEnabled = true
        settings.publicChannelId = "welcome-channel"

        _ = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { _, _ in
                sendCount += 1
                return true
            },
            sendDirectMessage: { _, _ in },
            grantRole: { _, _, _ in },
            fetchInvites: { _ in nil },
            log: { _ in }
        )

        let duplicate = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { _, _ in
                sendCount += 1
                return true
            },
            sendDirectMessage: { _, _ in },
            grantRole: { _, _, _ in },
            fetchInvites: { _ in nil },
            log: { _ in }
        )

        XCTAssertTrue(duplicate.isDuplicate)
        XCTAssertEqual(sendCount, 1)
    }

    func testAutoRoleIsGrantedAfterJoin() async {
        let service = WelcomeFlowService()
        var grantedRoles: [(guildID: String, userID: String, roleID: String)] = []

        var settings = WelcomeFlowSettings()
        settings.autoRoleEnabled = true
        settings.autoRoleId = "role-1"

        let result = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { _, _ in true },
            sendDirectMessage: { _, _ in },
            grantRole: { guildID, userID, roleID in
                grantedRoles.append((guildID, userID, roleID))
            },
            fetchInvites: { _ in nil },
            log: { _ in }
        )

        XCTAssertTrue(result.autoRoleGranted)
        XCTAssertFalse(result.publicMessageSent)
        XCTAssertFalse(result.directMessageSent)
        XCTAssertEqual(grantedRoles.first?.guildID, "guild-1")
        XCTAssertEqual(grantedRoles.first?.userID, "user-1")
        XCTAssertEqual(grantedRoles.first?.roleID, "role-1")
    }

    func testInviteSpecificRuleGrantsMatchingRole() async {
        let service = WelcomeFlowService()
        service.seedInvites(guildID: "guild-1", invites: [
            .init(code: "dabois", channelID: "general", channelName: "general", inviterID: "owner", uses: 2)
        ])

        var grantedRoles: [(guildID: String, userID: String, roleID: String)] = []
        var settings = WelcomeFlowSettings()
        settings.nextStepRules = [
            WelcomeFlowRule(name: "Dabois", inviteCode: "dabois", roleId: "role-dabois"),
            WelcomeFlowRule(name: "Other", inviteCode: "other", roleId: "role-other"),
            WelcomeFlowRule(name: "Fallback", inviteCode: "", roleId: "role-fallback")
        ]

        let result = await service.handleMemberJoin(
            joinEvent(),
            settings: settings,
            serverName: "Test Guild",
            sendPublicMessage: { _, _ in true },
            sendDirectMessage: { _, _ in },
            grantRole: { guildID, userID, roleID in
                grantedRoles.append((guildID, userID, roleID))
            },
            fetchInvites: { _ in
                [
                    .init(code: "dabois", channelID: "general", channelName: "general", inviterID: "owner", uses: 3),
                    .init(code: "other", channelID: "rules", channelName: "rules", inviterID: "owner", uses: 5)
                ]
            },
            log: { _ in }
        )

        XCTAssertEqual(result.grantedRoleIDs, ["role-dabois", "role-fallback"])
        XCTAssertEqual(grantedRoles.map(\.roleID), ["role-dabois", "role-fallback"])
    }

    func testLegacyBehaviorMigratesIntoWelcomeFlowSettings() {
        var legacy = BotBehaviorSettings()
        legacy.memberJoinWelcomeEnabled = true
        legacy.memberJoinWelcomeChannelId = "legacy-channel"
        legacy.memberJoinWelcomeTemplate = "Hello {username}"

        let migrated = WelcomeFlowSettings(legacyBehavior: legacy)

        XCTAssertTrue(migrated.publicWelcomeEnabled)
        XCTAssertEqual(migrated.publicChannelId, "legacy-channel")
        XCTAssertEqual(migrated.publicMessageTemplate, "Hello {username}")
        XCTAssertFalse(migrated.dmWelcomeEnabled)
    }

    private func joinEvent(
        guildID: String = "guild-1",
        userID: String = "user-1",
        username: String = "Taylor"
    ) -> GatewayMemberJoinEvent {
        GatewayMemberJoinEvent(
            guildID: guildID,
            userID: userID,
            rawUsername: username,
            joinedAt: Date(timeIntervalSince1970: 0)
        )
    }
}
