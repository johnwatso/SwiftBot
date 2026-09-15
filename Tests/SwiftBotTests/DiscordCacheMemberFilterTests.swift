import XCTest
@testable import SwiftBot

/// SwiftMiner builds its account and invitation pickers from the member list
/// this cache hands out, so anything that is not a person on the server has to
/// be filtered here rather than downstream.
final class DiscordCacheMemberFilterTests: XCTestCase {

    func testMemberListExcludesBots() async {
        let cache = DiscordCache()
        await cache.upsertUser(id: "bot", preferredName: "CatBot", username: "catbot")
        await cache.markBot(id: "bot")
        await cache.upsertUser(id: "person", preferredName: "Dalton", username: "jd81104")
        await cache.markGuildMember(id: "person")

        let members = await cache.humanGuildMembers()

        XCTAssertEqual(members.map(\.id), ["person"])
    }

    /// A user cached from a DM — or left over from a build that predates bot
    /// flagging — was never confirmed to be on the server, and must not be
    /// offered as someone to invite.
    func testMemberListExcludesUsersNeverSeenInAGuild() async {
        let cache = DiscordCache()
        await cache.upsertUser(id: "user-1", preferredName: "alice")
        await cache.upsertUser(id: "person", preferredName: "Dalton", username: "jd81104")
        await cache.markGuildMember(id: "person")

        let members = await cache.humanGuildMembers()

        XCTAssertEqual(members.map(\.id), ["person"])
    }

    /// An account already linked to SwiftMiner is on the server by definition.
    /// It stays in the list so its name and avatar keep resolving even before a
    /// gateway event confirms membership.
    func testLinkedSwiftMinerAccountsSurviveWithoutAGuildEvent() async {
        let cache = DiscordCache()
        await cache.upsertUser(id: "linked", preferredName: "Gabe", username: "gabe")

        let members = await cache.humanGuildMembers(alsoIncluding: ["linked"])

        XCTAssertEqual(members.map(\.id), ["linked"])
    }

    /// Being linked does not outrank being a bot.
    func testLinkedBotIsStillExcluded() async {
        let cache = DiscordCache()
        await cache.upsertUser(id: "bot", preferredName: "CatBot")
        await cache.markBot(id: "bot")

        let members = await cache.humanGuildMembers(alsoIncluding: ["bot"])

        XCTAssertTrue(members.isEmpty)
    }

    func testMemberListCarriesTheRawUsernameWhenKnown() async {
        let cache = DiscordCache()
        await cache.upsertUser(id: "person", preferredName: "Christian", username: "wrexhamfc")
        await cache.markGuildMember(id: "person")

        let member = await cache.humanGuildMembers().first

        XCTAssertEqual(member?.displayName, "Christian")
        XCTAssertEqual(member?.username, "wrexhamfc")
    }
}
