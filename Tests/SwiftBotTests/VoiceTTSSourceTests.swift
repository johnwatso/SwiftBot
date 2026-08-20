import AVFoundation
import XCTest
@testable import SwiftBot

final class VoiceTTSSourceTests: XCTestCase {

    /// Stand-in for an installed voice. `AVSpeechSynthesisVoice` can't be
    /// constructed with arbitrary identifiers, so voice selection is tested
    /// through the `from:` seams against whatever the host actually has.
    private func installedEnglishVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
    }

    // MARK: - Fallback voice

    /// The fallback exists to survive the selected engine failing. It used to
    /// be resolved with `preferredEnglishVoice()`, which returns the selected
    /// voice on a default configuration — so the retry re-entered the engine
    /// that had just failed and did nothing. A crashed third-party voice
    /// extension took every subsequent read down with it.
    func testFallbackVoiceIsNeverTheSelectedVoice() throws {
        let voices = installedEnglishVoices()
        try XCTSkipIf(voices.count < 2, "needs at least two installed English voices")

        for selected in voices {
            let fallback = VoiceTTSSource.fallbackEnglishVoice(
                from: voices,
                excluding: selected.identifier
            )
            XCTAssertNotNil(fallback)
            XCTAssertNotEqual(fallback?.identifier, selected.identifier)
        }
    }

    /// Third-party voices ship as separate app extensions that can crash on
    /// their own; Apple's are in-process assets. The fallback must prefer a
    /// system voice so it stays available when the extension is the problem.
    func testFallbackVoicePrefersASystemVoice() throws {
        let voices = installedEnglishVoices()
        let systemVoices = voices.filter(VoiceTTSSource.isSystemVoice)
        try XCTSkipIf(systemVoices.isEmpty, "needs at least one installed Apple English voice")

        let fallback = VoiceTTSSource.fallbackEnglishVoice(from: voices, excluding: nil)
        let resolved = try XCTUnwrap(fallback)
        XCTAssertTrue(VoiceTTSSource.isSystemVoice(resolved), "fallback resolved to \(resolved.identifier)")
    }

    /// Excluding the only system voice must still yield *something* other than
    /// the failed selection rather than giving up.
    func testFallbackVoiceFallsBackToANonSystemVoiceWhenItMust() throws {
        let voices = installedEnglishVoices()
        let systemVoices = voices.filter(VoiceTTSSource.isSystemVoice)
        try XCTSkipIf(voices.count == systemVoices.count, "needs at least one third-party English voice")

        let onlyThirdParty = voices.filter { !VoiceTTSSource.isSystemVoice($0) }
        let fallback = VoiceTTSSource.fallbackEnglishVoice(
            from: onlyThirdParty,
            excluding: onlyThirdParty[0].identifier
        )
        if onlyThirdParty.count > 1 {
            XCTAssertNotNil(fallback)
            XCTAssertNotEqual(fallback?.identifier, onlyThirdParty[0].identifier)
        } else {
            XCTAssertNil(fallback)
        }
    }

    func testSystemVoiceDetection() {
        for voice in installedEnglishVoices() {
            XCTAssertEqual(
                VoiceTTSSource.isSystemVoice(voice),
                voice.identifier.hasPrefix("com.apple."),
                "unexpected classification for \(voice.identifier)"
            )
        }
    }

    // MARK: - Render lifecycle

    /// Every render used to strand its `AVSpeechSynthesizer` in a reference
    /// cycle (synthesizer -> write callback -> collector -> completion closure
    /// -> session -> synthesizer), leaking the synthesizer and every buffer it
    /// had rendered for the life of the process. Measured at ~1.3 MB per
    /// announcement, which degrades the speech engine over a long session.
    func testRepeatedRendersDoNotGrowTheFootprint() async throws {
        let source = try VoiceTTSSource()
        // Deliberately not `preferredEnglishVoice()`: that ranks third-party
        // voices first, and those are separate app extensions that can take
        // the test host down with them when they misbehave. The cycle under
        // test is in this file's own object graph, so any voice exercises it —
        // pick an in-process Apple one and keep the test deterministic.
        let voice = try XCTUnwrap(
            VoiceTTSSource.fallbackEnglishVoice(excluding: nil),
            "needs an installed Apple English voice"
        )
        try XCTSkipUnless(VoiceTTSSource.isSystemVoice(voice), "no Apple English voice installed")

        // Warm the engine so first-render asset loading isn't counted.
        for _ in 0..<3 {
            _ = try? await source.render(text: "warm up", voice: voice)
        }

        let before = footprintBytes()
        for index in 0..<12 {
            _ = try? await source.render(text: "announcement number \(index)", voice: voice)
        }
        let after = footprintBytes()

        let growthPerRender = (Int64(after) - Int64(before)) / 12
        // The leak was ~1.3 MB per render and strictly cumulative. A generous
        // ceiling still fails loudly if the cycle comes back, without making
        // the test sensitive to ordinary allocator noise.
        XCTAssertLessThan(
            growthPerRender,
            400_000,
            "footprint grew \(growthPerRender) bytes per render; the synthesizer is leaking again"
        )
    }

    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
