import AVFoundation
import Foundation

enum VoiceAnnouncerPhase: String, Codable, Sendable, Equatable {
    case idle
    case queued
    case rendering
    case sending
    case paused
    case recovering
    case failed

    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .queued: return "Queued"
        case .rendering: return "Rendering"
        case .sending: return "Sending"
        case .paused: return "Paused"
        case .recovering: return "Recovering"
        case .failed: return "Failed"
        }
    }
}

struct VoiceAnnouncerHealth: Sendable, Equatable {
    var phase: VoiceAnnouncerPhase = .idle
    var queueDepth: Int = 0
    var recentCount: Int = 0
    var retryStreak: Int = 0
    var lastQueuedAt: Date?
    var lastSpokenAt: Date?
    var lastFailureAt: Date?
    var lastFailureReason: String?
    var lastRecoveryAt: Date?
    var activeStartedAt: Date?
    var activeCharacterCount: Int?
    var lastBatchSize: Int = 0
    var isPaused: Bool = false
    var isDraining: Bool = false

    func isStalled(now: Date = Date(), threshold: TimeInterval = 60) -> Bool {
        guard !isPaused else { return false }
        switch phase {
        case .rendering, .sending:
            guard let activeStartedAt else { return false }
            return now.timeIntervalSince(activeStartedAt) >= threshold
        case .queued:
            guard queueDepth > 0, let lastQueuedAt else { return false }
            return now.timeIntervalSince(lastQueuedAt) >= threshold
        case .failed:
            return true
        case .idle, .paused, .recovering:
            return false
        }
    }
}

enum AnnouncerSpeechSanitizer {
    static let maxCharacters = 360

    static func sanitized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        text = replace(pattern: "```[\\s\\S]*?```", in: text, with: " code block ")
        text = replace(pattern: "`([^`\\n]{1,100})`", in: text, with: "$1")
        text = replace(pattern: "\\[([^\\]\\n]{1,120})\\]\\(([^\\)\\n]+)\\)", in: text, with: "$1")
        text = replaceCustomEmoji(in: text)
        text = replace(pattern: "<@!?\\d+>", in: text, with: "user")
        text = replace(pattern: "<@&\\d+>", in: text, with: "role")
        text = replace(pattern: "<#\\d+>", in: text, with: "channel")
        text = replace(pattern: "<t:\\d+(?::[A-Za-z])?>", in: text, with: "time")
        text = replace(pattern: "(https?://|www\\.)\\S+", in: text, with: "link")
        text = replace(pattern: "(^|\\n)>\\s*", in: text, with: "$1")
        text = replace(pattern: "[*_~]{1,3}", in: text, with: "")
        text = replace(pattern: "[\\r\\n\\t]+", in: text, with: ". ")
        text = replace(pattern: "[\\p{Cc}\\p{Cf}]", in: text, with: "")
        text = collapseEmojiRuns(in: text)
        text = replace(pattern: "\\s+", in: text, with: " ")
        text = replace(pattern: "\\s+([,.;:!?])", in: text, with: "$1")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        return truncate(text, to: maxCharacters)
    }

    private static func replace(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func replaceCustomEmoji(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<a?:([A-Za-z0-9_]+):\\d+>") else {
            return text
        }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            let name = text[nameRange].replacingOccurrences(of: "_", with: " ")
            result.replaceSubrange(fullRange, with: name)
        }
        return result
    }

    private static func collapseEmojiRuns(in text: String) -> String {
        var result = ""
        var emojiRun = 0
        for character in text {
            let isEmoji = character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            if isEmoji {
                emojiRun += 1
                if emojiRun == 1 {
                    result.append(character)
                } else if emojiRun == 4 {
                    result.append(" emoji")
                }
            } else {
                emojiRun = 0
                result.append(character)
            }
        }
        return result
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let slice = String(text.prefix(limit))
        if let lastSpace = slice.lastIndex(of: " ") {
            let head = String(slice[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head + "..." }
        }
        return slice.trimmingCharacters(in: .whitespaces) + "..."
    }
}

enum AnnouncerAudioGuardrails {
    static func validateAndRepair(_ buffer: AVAudioPCMBuffer) throws -> SendableAudioBuffer {
        guard buffer.frameLength > 0 else {
            throw VoicePipelineError.audioRenderInvalid("speech rendered no audio frames")
        }
        guard abs(buffer.format.sampleRate - OpusFrameEncoder.sampleRate) < 0.5,
              buffer.format.channelCount == OpusFrameEncoder.channelCount,
              let channelData = buffer.floatChannelData else {
            throw VoicePipelineError.audioRenderInvalid("speech rendered in an unsupported audio format")
        }

        let peak = try peakSample(in: buffer, channelData: channelData)
        guard peak >= 0.000_01 else {
            throw VoicePipelineError.audioRenderInvalid("speech rendered silence")
        }
        if peak > 0.98 {
            scale(buffer, channelData: channelData, by: 0.92 / peak)
        }
        return SendableAudioBuffer(buffer: buffer)
    }

    private static func peakSample(
        in buffer: AVAudioPCMBuffer,
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>
    ) throws -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var peak: Float = 0

        if buffer.format.isInterleaved {
            let samples = frames * channels
            let data = channelData[0]
            for index in 0..<samples {
                let value = data[index]
                guard value.isFinite else {
                    throw VoicePipelineError.audioRenderInvalid("speech rendered invalid samples")
                }
                peak = max(peak, abs(value))
            }
        } else {
            for channel in 0..<channels {
                let data = channelData[channel]
                for index in 0..<frames {
                    let value = data[index]
                    guard value.isFinite else {
                        throw VoicePipelineError.audioRenderInvalid("speech rendered invalid samples")
                    }
                    peak = max(peak, abs(value))
                }
            }
        }

        return peak
    }

    private static func scale(
        _ buffer: AVAudioPCMBuffer,
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        by factor: Float
    ) {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)

        if buffer.format.isInterleaved {
            let samples = frames * channels
            let data = channelData[0]
            for index in 0..<samples {
                data[index] *= factor
            }
        } else {
            for channel in 0..<channels {
                let data = channelData[channel]
                for index in 0..<frames {
                    data[index] *= factor
                }
            }
        }
    }
}
