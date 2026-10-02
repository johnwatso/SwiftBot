import XCTest
@testable import SwiftBot

final class ClipPeopleMatcherTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(_ user: String, channel: String, from start: TimeInterval, to end: TimeInterval?) -> VoiceSession {
        var s = VoiceSession(userId: user, username: user, guildId: "g", channelId: channel, channelName: channel, joinedAt: t0.addingTimeInterval(start))
        s.leftAt = end.map { t0.addingTimeInterval($0) }
        return s
    }

    private var clip: DateInterval { DateInterval(start: t0.addingTimeInterval(600), end: t0.addingTimeInterval(690)) }

    func testRecorderBringsInTheirChannelOnly() {
        let sessions = [
            session("john", channel: "squad", from: 0, to: 3_600),
            session("gabe", channel: "squad", from: 300, to: nil),       // joined before the clip, still there
            session("sam", channel: "afk", from: 0, to: 3_600),           // in voice, another channel
            session("alex", channel: "squad", from: 700, to: 900)         // joined after the clip ended
        ]
        let people = ClipPeopleMatcher.people(window: clip, sessions: sessions, ownerID: "john", now: t0.addingTimeInterval(1_000))
        XCTAssertEqual(people, ["gabe", "john"])
    }

    func testRecorderNotInVoiceIsJustThem() {
        let sessions = [session("sam", channel: "squad", from: 0, to: 3_600)]
        XCTAssertEqual(ClipPeopleMatcher.people(window: clip, sessions: sessions, ownerID: "john"), ["john"])
    }

    func testWithoutARecorderOnlyAnObviousChannelCounts() {
        let one = [session("gabe", channel: "squad", from: 0, to: 3_600), session("sam", channel: "squad", from: 0, to: 3_600)]
        XCTAssertEqual(ClipPeopleMatcher.people(window: clip, sessions: one, ownerID: nil), ["gabe", "sam"])

        let two = one + [session("alex", channel: "afk", from: 0, to: 3_600)]
        XCTAssertEqual(ClipPeopleMatcher.people(window: clip, sessions: two, ownerID: nil), [], "Two busy channels: don't guess")
    }

    func testBotsAreLeftOut() {
        let sessions = [session("john", channel: "squad", from: 0, to: 3_600), session("swiftbot", channel: "squad", from: 0, to: 3_600)]
        XCTAssertEqual(ClipPeopleMatcher.people(window: clip, sessions: sessions, ownerID: "john", excluding: ["swiftbot"]), ["john"])
    }

    func testRecordingOwnersSurviveASaveAndLoad() throws {
        var settings = BotSettings()
        settings.recordingSourceOwners = ["Mac|ABC": "412378964087275541"]
        let loaded = try JSONDecoder().decode(BotSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.recordingSourceOwners, settings.recordingSourceOwners)
    }
}
