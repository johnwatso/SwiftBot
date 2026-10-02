import XCTest
@testable import SwiftBot

final class OperatorAlertTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func testAlertWaitsForTheDelayThenFiresOnce() {
        var tracker = OperatorIssueTracker()
        XCTAssertNil(tracker.observe("discord", isProblem: true, after: 300, now: t0))
        XCTAssertNil(tracker.observe("discord", isProblem: true, after: 300, now: t0.addingTimeInterval(120)), "Not yet five minutes")
        XCTAssertEqual(tracker.observe("discord", isProblem: true, after: 300, now: t0.addingTimeInterval(300)), .raise)
        XCTAssertNil(tracker.observe("discord", isProblem: true, after: 300, now: t0.addingTimeInterval(360)), "Only once per problem")
        XCTAssertEqual(tracker.observe("discord", isProblem: false, after: 300, now: t0.addingTimeInterval(400)), .resolve)
    }

    func testBlipsThatClearBeforeTheDelayStayQuiet() {
        var tracker = OperatorIssueTracker()
        XCTAssertNil(tracker.observe("node|Studio", isProblem: true, after: 180, now: t0))
        XCTAssertNil(tracker.observe("node|Studio", isProblem: false, after: 180, now: t0.addingTimeInterval(60)), "No all-clear for an alert never sent")
    }

    func testARepeatWithinHalfAnHourIsHeldBack() {
        var tracker = OperatorIssueTracker()
        XCTAssertEqual(tracker.observe("errors", isProblem: true, after: 0, now: t0), .raise)
        XCTAssertEqual(tracker.observe("errors", isProblem: false, after: 0, now: t0.addingTimeInterval(60)), .resolve)
        XCTAssertNil(tracker.observe("errors", isProblem: true, after: 0, now: t0.addingTimeInterval(120)), "Flapping: held back")
        XCTAssertNil(tracker.observe("errors", isProblem: false, after: 0, now: t0.addingTimeInterval(180)), "…and so is its all-clear")
        XCTAssertEqual(tracker.observe("errors", isProblem: true, after: 0, now: t0.addingTimeInterval(OperatorIssueTracker.quietPeriod + 60)), .raise)
    }

    func testErrorLinesAreCountedInTheWindow() {
        let formatter = ISO8601DateFormatter()
        let stamp = { (offset: TimeInterval) in "[\(formatter.string(from: self.t0.addingTimeInterval(offset)))]" }
        let lines = [
            "\(stamp(-900)) [ERR] old one",
            "\(stamp(-300)) ❌ Patchy: failed",
            "\(stamp(-200)) [OK] all good",
            "\(stamp(-100)) [ERR] Failed saving settings"
        ]
        XCTAssertEqual(OperatorIssueTracker.errorLines(in: lines, since: t0.addingTimeInterval(-600)).count, 2)
    }

    func testOperatorsSurviveASaveAndLoad() throws {
        var settings = BotSettings()
        settings.operators.operatorsByNode = ["Studio": "280129381292318720"]
        settings.operators.enabledAlerts = [.discordDisconnected, .roleChanges]
        let loaded = try JSONDecoder().decode(BotSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(loaded.operators, settings.operators)
        XCTAssertEqual(BotSettings().operators.enabledAlerts, Set(OperatorAlertKind.allCases), "Every alert on by default")
    }
}
