import XCTest
@testable import SwiftBot

final class SweepWeeklyMVPAnnouncementTests: XCTestCase {
    func testMVPIsDueOnlyOnceDuringItsScheduledWeek() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 20))!
        var announcement = SweepWeeklyMVPAnnouncement(isEnabled: true, weekday: 2, hour: 20)

        XCTAssertTrue(announcement.isDue(at: date, calendar: calendar))
        announcement.lastPostedWeekKey = announcement.weekKey(for: date, calendar: calendar)
        XCTAssertFalse(announcement.isDue(at: date.addingTimeInterval(30), calendar: calendar))
        XCTAssertFalse(announcement.isDue(at: date.addingTimeInterval(7 * 24 * 60 * 60 - 1), calendar: calendar))
    }

    func testMVPMessageMentionsWinnerAndFormatsRollingTotal() {
        let announcement = SweepWeeklyMVPAnnouncement(
            isEnabled: true,
            template: "This week's MVP is {winner} with {duration} this week!"
        )
        let winner = VoiceUserRollingAverage(
            userId: "max-id",
            username: "Max",
            averageSecondsPerDay: 3 * 60 * 60,
            totalSeconds: 21 * 60 * 60,
            sessionCount: 4
        )

        XCTAssertEqual(
            announcement.rendered(winner: winner),
            "This week's MVP is <@max-id> with 21 hours this week!"
        )
    }
}
