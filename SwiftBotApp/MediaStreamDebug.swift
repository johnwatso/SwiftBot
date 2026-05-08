import Foundation
import os

/// Lightweight diagnostics for media playback streaming.
///
/// Enabled by setting the `SWIFTBOT_DEBUG_STREAM` environment variable to a
/// truthy value (`1`, `true`, `yes`). When enabled, every range request that
/// `/api/media/stream` services emits a single log line with offset, length,
/// status, and read latency, so we can pinpoint whether buffering stalls are
/// caused by big chunk reads, transcoder warm-up, or something further up the
/// stack.
enum StreamDebug {
    static let enabled: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["SWIFTBOT_DEBUG_STREAM"] else {
            return false
        }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }()

    private static let logger = Logger(subsystem: "com.swiftbot.media", category: "stream")

    struct Context: Sendable {
        let itemID: String
        let source: String
        let rangeHeader: String
    }

    static func context(itemID: String, source: String, rangeHeader: String?) -> Context {
        Context(
            itemID: itemID,
            source: source,
            rangeHeader: rangeHeader?.isEmpty == false ? rangeHeader! : "(none)"
        )
    }

    static func log(
        context: Context,
        offset: UInt64,
        requestedLength: UInt64,
        deliveredLength: UInt64,
        fileSize: UInt64,
        status: String,
        elapsedMs: Double
    ) {
        guard enabled else { return }
        logger.debug(
            "[stream] item=\(context.itemID, privacy: .public) src=\(context.source, privacy: .public) range=\(context.rangeHeader, privacy: .public) offset=\(offset) requested=\(requestedLength) delivered=\(deliveredLength) total=\(fileSize) status=\(status, privacy: .public) elapsedMs=\(String(format: "%.1f", elapsedMs), privacy: .public)"
        )
    }
}
