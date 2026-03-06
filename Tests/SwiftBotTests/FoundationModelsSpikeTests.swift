import XCTest
import Darwin
@testable import SwiftBot
#if canImport(FoundationModels)
import FoundationModels
#endif

/// P1.1 — Foundation Models feasibility spike.
/// Measures quality, latency, memory, and stability for SystemLanguageModel.default.
///
/// Pass criteria (ratified #delivery id=568, extended id=570):
///   - Median latency per response <= 3 000 ms
///   - p95 latency <= 5 000 ms
///   - Resident memory delta < 200 MB
///   - Peak resident memory recorded in output (informational)
///   - >= 4 / 5 prompts pass quality heuristic
///   - Per-prompt hard timeout: 15 s (timed-out prompt counts as quality fail)
///   - timeoutCount reported in JSON
///
/// Skipped (not failed) on hardware where Apple Intelligence is unavailable.
final class FoundationModelsSpikeTests: XCTestCase {

    // MARK: - Prompt suite

    private let promptSuite: [(label: String, prompt: String, systemPrompt: String)] = [
        (
            "help-answer",
            "What does the /help command do in SwiftBot?",
            "You are SwiftBot, a helpful Discord assistant. Reply concisely."
        ),
        (
            "conversational",
            "Hey, can you summarise what happened in #general today?",
            "You are SwiftBot, a helpful Discord assistant. Reply concisely."
        ),
        (
            "command-explain",
            "Explain the difference between /kick and /ban in a Discord server.",
            "You are SwiftBot, a helpful Discord assistant. Reply concisely."
        ),
        (
            "multi-turn",
            "Remind me again — what is the prefix for slash commands?",
            "You are SwiftBot. The user previously asked about command prefixes. Reply concisely."
        ),
        (
            "off-topic-deflect",
            "Write me a 500-word essay on the history of cheese.",
            "You are SwiftBot, a focused Discord assistant. Politely decline off-topic requests in one sentence."
        ),
    ]

    // MARK: - Pass thresholds (id=568)

    private let maxMedianLatencyMs: Double = 3_000
    private let maxP95LatencyMs: Double = 5_000
    private let maxMemoryDeltaMB: Int = 200
    private let minQualityPasses: Int = 4
    private let promptTimeoutSeconds: Double = 15

    // MARK: - Spike test

    func testFoundationModelsFeasibilitySpike() async throws {
#if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26.0+")
        }

        let model = SystemLanguageModel.default
        let availabilityTier: String
        switch model.availability {
        case .available:
            availabilityTier = "available"
        default:
            throw XCTSkip("SystemLanguageModel unavailable on this hardware (no Apple Intelligence)")
        }

        let memBefore = currentResidentMB()
        var peakResidentMB = memBefore
        var latenciesMs: [Double] = []
        var qualityPasses = 0
        var timeoutCount = 0
        var results: [[String: Any]] = []

        for suite in promptSuite {
            let session = LanguageModelSession(model: model)
            let start = Date()
            var timedOut = false

            let response: String
            do {
                response = try await withPromptTimeout(seconds: promptTimeoutSeconds) {
                    let reply = try await session.respond(to: suite.prompt)
                    return reply.content
                }
            } catch is PromptTimeoutError {
                response = ""
                timedOut = true
                timeoutCount += 1
            } catch {
                response = ""
            }

            let latencyMs = Date().timeIntervalSince(start) * 1_000
            let qualityOK = !timedOut && qualityCheck(response: response)
            if qualityOK { qualityPasses += 1 }
            latenciesMs.append(min(latencyMs, promptTimeoutSeconds * 1_000))

            let currentMem = currentResidentMB()
            if currentMem > peakResidentMB { peakResidentMB = currentMem }

            results.append([
                "label": suite.label,
                "latencyMs": Int(latencyMs),
                "timedOut": timedOut,
                "qualityPass": qualityOK,
                "responseLength": response.count,
                "responseSnippet": String(response.prefix(80))
            ])
        }

        let memAfter = currentResidentMB()
        let memDeltaMB = max(0, memAfter - memBefore)
        let medianLatencyMs = median(latenciesMs)
        let p95LatencyMs = percentile(latenciesMs, p: 0.95)

        let passed = medianLatencyMs <= maxMedianLatencyMs
                  && p95LatencyMs <= maxP95LatencyMs
                  && memDeltaMB < maxMemoryDeltaMB
                  && qualityPasses >= minQualityPasses
                  && timeoutCount == 0

        // Machine-readable JSON artifact (captured by CI / @gemini validation)
        let report: [String: Any] = [
            "spike": "FoundationModels-P1.1",
            "passed": passed,
            "availabilityTier": availabilityTier,
            "medianLatencyMs": Int(medianLatencyMs),
            "p95LatencyMs": Int(p95LatencyMs),
            "memoryDeltaMB": memDeltaMB,
            "peakResidentMB": peakResidentMB,
            "qualityPasses": "\(qualityPasses)/\(promptSuite.count)",
            "timeoutCount": timeoutCount,
            "thresholds": [
                "maxMedianLatencyMs": Int(maxMedianLatencyMs),
                "maxP95LatencyMs": Int(maxP95LatencyMs),
                "maxMemoryDeltaMB": maxMemoryDeltaMB,
                "minQualityPasses": minQualityPasses,
                "promptTimeoutSeconds": Int(promptTimeoutSeconds)
            ],
            "prompts": results
        ]

        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print("\n--- FoundationModels Spike Report ---\n\(json)\n---")
        }

        XCTAssertEqual(timeoutCount, 0,
            "\(timeoutCount) prompt(s) timed out (> \(Int(promptTimeoutSeconds))s)")
        XCTAssertLessThanOrEqual(medianLatencyMs, maxMedianLatencyMs,
            "Median latency \(Int(medianLatencyMs))ms exceeds \(Int(maxMedianLatencyMs))ms")
        XCTAssertLessThanOrEqual(p95LatencyMs, maxP95LatencyMs,
            "p95 latency \(Int(p95LatencyMs))ms exceeds \(Int(maxP95LatencyMs))ms")
        XCTAssertLessThan(memDeltaMB, maxMemoryDeltaMB,
            "Memory delta \(memDeltaMB)MB exceeds \(maxMemoryDeltaMB)MB")
        XCTAssertGreaterThanOrEqual(qualityPasses, minQualityPasses,
            "Only \(qualityPasses)/\(promptSuite.count) prompts passed quality heuristic")
#else
        throw XCTSkip("FoundationModels framework not importable on this platform")
#endif
    }

    // MARK: - Timeout helper

    private struct PromptTimeoutError: Error {}

    private func withPromptTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PromptTimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Quality heuristic

    /// Non-empty, plausible length, no bare error token.
    private func qualityCheck(response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 10 else { return false }
        let lower = trimmed.lowercased()
        // Reject responses that are literally just an error keyword
        let bareErrors = ["error", "exception", "nil", "null", "undefined", "fatal"]
        if trimmed.count < 60 && bareErrors.contains(lower) { return false }
        return true
    }

    // MARK: - Statistics

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let idx = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[min(idx, sorted.count - 1)]
    }

    // MARK: - Memory

    private func currentResidentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size) / (1024 * 1024)
    }
}
