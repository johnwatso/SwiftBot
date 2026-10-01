import XCTest
@testable import SwiftBot

final class AIActivityFactsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let members = [
        AIActivityFacts.Member(id: "1", name: "Sam Carter", username: "samc"),
        AIActivityFacts.Member(id: "2", name: "jonwatso", username: nil),
        AIActivityFacts.Member(id: "3", name: "Max", username: "maxpower"),
        AIActivityFacts.Member(id: "4", name: "Max Two", username: "m2")
    ]

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func testFindsMembersByMentionNameUsernameAndUniqueFirstName() {
        XCTAssertEqual(AIActivityFacts.mentionedMembers(in: "what time does sam usually jump on", members: members, botUserID: nil).map(\.id), ["1"])
        XCTAssertEqual(AIActivityFacts.mentionedMembers(in: "is <@2> on tonight?", members: members, botUserID: nil).map(\.id), ["2"])
        XCTAssertEqual(AIActivityFacts.mentionedMembers(in: "when is @maxpower on", members: members, botUserID: nil).map(\.id), ["3"])
        // Two members are called Max, so "max" alone names nobody in particular…
        XCTAssertEqual(AIActivityFacts.mentionedMembers(in: "max damage when", members: members, botUserID: nil).map(\.id), ["3"],
                       "…but it still matches the member whose whole name is Max")
        XCTAssertTrue(AIActivityFacts.mentionedMembers(in: "<@9> when", members: members, botUserID: "9").isEmpty)
    }

    func testOnlyActivityQuestionsGetFacts() {
        XCTAssertTrue(AIActivityFacts.isActivityQuestion("what time does sam usually jump on"))
        XCTAssertTrue(AIActivityFacts.isActivityQuestion("how often am I in vc?"))
        XCTAssertFalse(AIActivityFacts.isActivityQuestion("tell sam a joke"))
        XCTAssertTrue(AIActivityFacts.asksAboutSelf("when am I usually online"))
        XCTAssertTrue(AIActivityFacts.asksAboutServer("when is the server busiest"))
    }

    func testUsualStartFindsTheEveningCluster() throws {
        let starts = [date(day: 1, hour: 19, minute: 50), date(day: 2, hour: 20, minute: 10), date(day: 4, hour: 20, minute: 5),
                      date(day: 5, hour: 19, minute: 55), date(day: 7, hour: 13)]
        let usual = try XCTUnwrap(AIActivityFacts.usualStart(of: starts, timeZone: utc))
        XCTAssertEqual(usual.minutes, 20 * 60)
        XCTAssertEqual(usual.share, 0.8, accuracy: 0.001)
    }

    func testUsualStartWrapsPastMidnight() throws {
        let starts = [date(day: 1, hour: 23, minute: 30), date(day: 2, hour: 0, minute: 30), date(day: 3, hour: 23, minute: 45), date(day: 4, hour: 0, minute: 15)]
        let usual = try XCTUnwrap(AIActivityFacts.usualStart(of: starts, timeZone: utc))
        XCTAssertEqual(usual.minutes, 0, "Centred on midnight, not on noon")
        XCTAssertNil(AIActivityFacts.usualStart(of: Array(starts.prefix(2)), timeZone: utc), "Two sessions aren't a pattern")
    }

    func testDescribeSaysWhenSamIsUsuallyOn() {
        var record = AIActivityFacts.MemberRecord(member: members[0])
        record.sessions = (1...6).map { day in
            var session = VoiceSession(userId: "1", username: "Sam", guildId: "g", channelId: "c", channelName: "General", joinedAt: date(day: day, hour: 20))
            session.leftAt = date(day: day, hour: 22)
            return session
        }
        let line = AIActivityFacts.describe(record, now: date(day: 10, hour: 12), timeZone: utc, isAsker: false)
        XCTAssertTrue(line.contains("usually joins around 8:00 PM"), line)
        XCTAssertTrue(line.contains("12 h total"), line)
        XCTAssertTrue(line.contains("favourite voice channel General"), line)
    }

    func testOptedOutMembersAreNotDescribed() {
        var record = AIActivityFacts.MemberRecord(member: members[0])
        record.optedOut = true
        let line = AIActivityFacts.describe(record, now: Date(), timeZone: utc, isAsker: false)
        XCTAssertTrue(line.contains("opted out"))
        XCTAssertFalse(line.contains("voice"))
    }

    func testSettingSurvivesASaveAndLoad() throws {
        var settings = BotSettings()
        XCTAssertTrue(settings.aiActivityAnswersEnabled, "On by default")
        settings.aiActivityAnswersEnabled = false
        let loaded = try JSONDecoder().decode(BotSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(loaded.aiActivityAnswersEnabled)
    }
}
