import XCTest
@testable import SwiftBot

/// P1 — DM AI timeout path: verifies that on hard-timeout the outcome is `.handledFallback`
/// and no trailing help-prompt is emitted by the DM caller.
///
/// Uses DEBUG overrides on AppModel (timeout intervals) and ClusterCoordinator (AI delay)
/// so the test completes in ~200 ms instead of 30 s.
@MainActor
final class DMTimeoutTests: XCTestCase {

    // MARK: - Test 1: Hard timeout produces .handledFallback

    func testHardTimeoutOutcomeIsHandledFallback() async {
        let model = AppModel()

        // AI will take 10s — well beyond the 150 ms hard timeout below.
        await model.testCluster.testSetAIReplyOverride(response: "slow reply", delaySeconds: 10)

        // Compress timing: soft notice at 50 ms, hard timeout at 150 ms, refresh at 60 s.
        model._testSoftNoticeDelayNs  = 50_000_000
        model._testHardTimeoutNs      = 150_000_000
        model._testTypingRefreshNs    = 60_000_000_000

        let outcome = await model.generateAIReplyWithTimeout(
            channelId: "test-channel",
            messages: [],
            serverName: nil,
            channelName: nil,
            wikiContext: nil
        )

        guard case .handledFallback = outcome else {
            XCTFail("Expected .handledFallback when AI exceeds hard timeout; got \(outcome)")
            return
        }

        // Clean up so no background work leaks between tests.
        await model.testCluster.testSetAIReplyOverride(response: nil)
    }

    // MARK: - Test 2: Fast AI produces .reply, not .handledFallback

    func testFastAIProducesReply() async {
        let model = AppModel()

        await model.testCluster.testSetAIReplyOverride(response: "quick answer", delaySeconds: 0)

        model._testSoftNoticeDelayNs  = 10_000_000_000
        model._testHardTimeoutNs      = 30_000_000_000
        model._testTypingRefreshNs    = 60_000_000_000

        let outcome = await model.generateAIReplyWithTimeout(
            channelId: "test-channel",
            messages: [],
            serverName: nil,
            channelName: nil,
            wikiContext: nil
        )

        guard case .reply(let text) = outcome else {
            XCTFail("Expected .reply when AI responds promptly; got \(outcome)")
            return
        }
        XCTAssertEqual(text, "quick answer")

        await model.testCluster.testSetAIReplyOverride(response: nil)
    }

    // MARK: - Test 3: Engine nil → .noReply (not .handledFallback)

    func testEngineNilProducesNoReply() async {
        let model = AppModel()

        // Empty string sentinel in testSetAIReplyOverride → returns nil from generateAIReply.
        await model.testCluster.testSetAIReplyOverride(response: "", delaySeconds: 0)

        model._testSoftNoticeDelayNs  = 10_000_000_000
        model._testHardTimeoutNs      = 30_000_000_000
        model._testTypingRefreshNs    = 60_000_000_000

        let outcome = await model.generateAIReplyWithTimeout(
            channelId: "test-channel",
            messages: [],
            serverName: nil,
            channelName: nil,
            wikiContext: nil
        )

        guard case .noReply = outcome else {
            XCTFail("Expected .noReply when engine returns nil; got \(outcome)")
            return
        }

        await model.testCluster.testSetAIReplyOverride(response: nil)
    }
}
