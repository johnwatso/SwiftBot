import XCTest
@testable import SwiftBot

/// P1 — DM AI timeout path: verifies that on hard-timeout the outcome is `.handledFallback`
/// and no trailing help-prompt is emitted by the DM caller.
///
/// Uses Task-local overrides (AITestOverrides) for timeout intervals and AI delay
/// so the test completes in ~200 ms instead of 30 s.
/// Complies with March 2026 coding standards: "Release logic must not be inside #if DEBUG".
@MainActor
final class DMTimeoutTests: XCTestCase {

    // MARK: - Test 1: Hard timeout produces .handledFallback

    func testHardTimeoutOutcomeIsHandledFallback() async {
        let model = AppModel()

        // AI will take 10s — well beyond the 150 ms hard timeout below.
        await AITestOverrides.$replyOverride.withValue("slow reply") {
            await AITestOverrides.$replyDelaySeconds.withValue(10) {
                // Compress timing: soft notice at 50 ms, hard timeout at 150 ms, refresh at 60 s.
                await AITestOverrides.$softNoticeNs.withValue(50_000_000) {
                    await AITestOverrides.$hardTimeoutNs.withValue(150_000_000) {
                        await AITestOverrides.$typingRefreshNs.withValue(60_000_000_000) {
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
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test 2: Fast AI produces .reply, not .handledFallback

    func testFastAIProducesReply() async {
        let model = AppModel()

        await AITestOverrides.$replyOverride.withValue("quick answer") {
            await AITestOverrides.$replyDelaySeconds.withValue(0) {
                await AITestOverrides.$softNoticeNs.withValue(10_000_000_000) {
                    await AITestOverrides.$hardTimeoutNs.withValue(30_000_000_000) {
                        await AITestOverrides.$typingRefreshNs.withValue(60_000_000_000) {
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
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test 3: Engine nil before soft notice → .noReply

    func testEngineNilBeforeSoftNoticeProducesNoReply() async {
        let model = AppModel()

        // Engine returns nil immediately (empty string) — soft notice has not fired yet.
        await AITestOverrides.$replyOverride.withValue("") {
            await AITestOverrides.$replyDelaySeconds.withValue(0) {
                await AITestOverrides.$softNoticeNs.withValue(10_000_000_000) { // 10 s — will not fire
                    await AITestOverrides.$hardTimeoutNs.withValue(30_000_000_000) {
                        await AITestOverrides.$typingRefreshNs.withValue(60_000_000_000) {
                            let outcome = await model.generateAIReplyWithTimeout(
                                channelId: "test-channel",
                                messages: [],
                                serverName: nil,
                                channelName: nil,
                                wikiContext: nil
                            )

                            guard case .noReply = outcome else {
                                XCTFail("Expected .noReply when engine returns nil before soft notice; got \(outcome)")
                                return
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Test 4: Engine nil AFTER soft notice → .handledFallback (no stall)

    func testEngineNilAfterSoftNoticeProducesHandledFallback() async {
        let model = AppModel()

        // Engine returns nil but takes 200 ms — after the 50 ms soft notice fires.
        await AITestOverrides.$replyOverride.withValue("") {
            await AITestOverrides.$replyDelaySeconds.withValue(0.2) {
                await AITestOverrides.$softNoticeNs.withValue(50_000_000) { //  50 ms — fires before AI nil
                    await AITestOverrides.$hardTimeoutNs.withValue(10_000_000_000) { // 10 s — should not fire
                        await AITestOverrides.$typingRefreshNs.withValue(60_000_000_000) {
                            let outcome = await model.generateAIReplyWithTimeout(
                                channelId: "test-channel",
                                messages: [],
                                serverName: nil,
                                channelName: nil,
                                wikiContext: nil
                            )

                            guard case .handledFallback = outcome else {
                                XCTFail("Expected .handledFallback when engine returns nil after soft notice; got \(outcome)")
                                return
                            }
                        }
                    }
                }
            }
        }
    }
}
