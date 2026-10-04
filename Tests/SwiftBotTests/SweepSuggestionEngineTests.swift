import XCTest
@testable import SwiftBot

final class SweepSuggestionEngineTests: XCTestCase {
    private func message(_ index: Int, content: String, bot: Bool = false, author: String = "Sam") -> SweepFetchedMessage {
        SweepFetchedMessage(
            id: "\(index)",
            authorID: bot ? "bot-\(author)" : "user-\(author)",
            authorName: author,
            isBot: bot,
            content: content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 - index * 60)),
            isPinned: false,
            hasReactions: false
        )
    }

    private func analyse(_ messages: [SweepFetchedMessage]) -> [SweepSuggestion] {
        SweepSuggestionEngine.analyse(guildID: "g", guildName: "Server", channelID: "c", channelName: "general", messages: messages)
    }

    func testShortRepeatedChatIsNotADuplicateProblem() {
        let chat = (0..<60).map { message($0, content: ["lol", "gg", "nice", "same"][$0 % 4]) }
        XCTAssertTrue(analyse(chat).isEmpty)
    }

    func testRepeatedLongMessagesSuggestDeduplicate() {
        var messages = (0..<40).map { message($0, content: "Unique conversation message number \($0)") }
        messages += (40..<52).map { message($0, content: "Join our giveaway at example.com today!") }
        let suggestions = analyse(messages)
        XCTAssertEqual(suggestions.map(\.strategyKind), [.deduplicate])
    }

    func testBotHeavyChannelGetsOneSuggestionOnly() {
        // Matches reduce-noise, dedupe and keep-latest at once.
        let messages = (0..<40).map { message($0, content: "Build finished for SwiftBot main", bot: true, author: "CI") }
        XCTAssertEqual(analyse(messages).count, 1)
    }

    func testGroupsCountEveryActionWithFewExamples() {
        let actions = (0..<25).map { index in
            SweepAction(kind: .delete, messageID: "\(index)", preview: "Old post \(index)", reason: "Older than 48h",
                        authorName: index < 20 ? "Patchy" : "GitHub", isBot: true)
        } + [SweepAction(kind: .skip, messageID: "p", preview: "Rules", reason: "Pinned — protected", authorName: "Mod", isBot: false)]

        let groups = SweepActionGroup.summarise(actions)

        XCTAssertEqual(groups.map(\.count), [25, 1])
        XCTAssertEqual(groups[0].botCount, 25)
        XCTAssertEqual(groups[0].authors.map(\.name), ["Patchy", "GitHub"])
        XCTAssertEqual(groups[0].examples.count, SweepActionGroup.maxExamples)
        XCTAssertEqual(groups[1].kind, .skip)
    }

    func testMergeAddsLaterPasses() {
        let pass = (0..<5).map { SweepAction(kind: .delete, messageID: "\($0)", preview: "x", reason: "Channel cleared", authorName: "Sam") }
        let merged = SweepActionGroup.merge(SweepActionGroup.summarise(pass), with: pass)
        XCTAssertEqual(merged.first?.count, 10)
        XCTAssertEqual(merged.first?.authors.first?.count, 10)
    }
}
