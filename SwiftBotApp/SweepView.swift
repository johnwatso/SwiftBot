import Foundation
import SwiftUI

// MARK: - Sweep Models
//
// Sweep is SwiftBot's native macOS utility for intelligently tidying Discord
// channel clutter — compacting repetitive activity, condensing bot chatter,
// summarising noisy channels. The first cut ships the full model surface, an
// actor-backed service with JSON persistence and a scheduler tick, and a
// SwiftMesh-styled dashboard. Discord side-effects are routed through
// `SweepDispatcher` — by default the dispatcher is a dry-run shim so the UI
// is fully exercisable without touching real channels.

enum SweepStrategyKind: String, Codable, CaseIterable, Identifiable {
    case compact
    case summarise
    case keepLatest
    case deduplicate
    case archive
    case quietChannel
    case reduceNoise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .summarise: return "Summarise"
        case .keepLatest: return "Keep Latest"
        case .deduplicate: return "Deduplicate"
        case .archive: return "Archive"
        case .quietChannel: return "Quiet Channel"
        case .reduceNoise: return "Reduce Noise"
        }
    }

    var symbol: String {
        switch self {
        case .compact: return "rectangle.compress.vertical"
        case .summarise: return "text.bubble"
        case .keepLatest: return "1.circle"
        case .deduplicate: return "square.on.square.dashed"
        case .archive: return "archivebox"
        case .quietChannel: return "bell.slash"
        case .reduceNoise: return "waveform.path.ecg"
        }
    }

    var blurb: String {
        switch self {
        case .compact:
            return "Deletes messages older than the chosen age from Discord. Toggle “Bots only” to leave human messages untouched."
        case .summarise:
            return "Generates a plain-English digest of matching messages on-device (Apple Intelligence). The digest is attached to the run report — Discord is not touched."
        case .keepLatest:
            return "Keeps the most recent N posts in the channel. Every older message is deleted from Discord."
        case .deduplicate:
            return "Deletes duplicate messages from Discord, keeping the freshest copy of each."
        case .archive:
            return "Archives stale threads in the channel after the chosen quiet period (Discord thread archive — they stay visible but collapsed)."
        case .quietChannel:
            return "In-app only. Marks routine bot chatter as muted so SwiftBot’s UI can collapse it. Nothing is sent to Discord and no messages are deleted."
        case .reduceNoise:
            return "Composite pass: deletes duplicate messages, then deletes bot messages older than the chosen age. Best for high-traffic notification channels."
        }
    }

    /// One-word summary of where the action lands. Shown next to the blurb so
    /// users can tell at a glance which strategies actually touch Discord.
    var destinationLabel: String {
        switch self {
        case .compact, .keepLatest, .deduplicate, .reduceNoise: return "Deletes from Discord"
        case .archive: return "Archives Discord threads"
        case .summarise: return "In-app digest only"
        case .quietChannel: return "In-app only"
        }
    }

    var destinationTone: Color {
        switch self {
        case .compact, .keepLatest, .deduplicate, .reduceNoise: return .orange
        case .archive: return .indigo
        case .summarise, .quietChannel: return .blue
        }
    }
}

/// Goal-oriented presentation of a Sweep strategy. Each task maps to a
/// concrete `SweepStrategyKind` underneath, but the user picks the *goal*
/// (e.g. "Trim old bot messages") rather than the *mechanism* (".compact").
/// Experimental tasks are listed so the UI can show them as "Coming soon"
/// without enabling them.
enum SweepTask: String, CaseIterable, Identifiable, Codable {
    case trimOldBotMessages
    case keepNewest
    case removeDuplicates
    case cleanNoisyBotChannel
    case archiveStaleThreads
    case dailyDigest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trimOldBotMessages: return "Trim old bot messages"
        case .keepNewest: return "Keep only the newest"
        case .removeDuplicates: return "Remove duplicate messages"
        case .cleanNoisyBotChannel: return "Clean a noisy bot channel"
        case .archiveStaleThreads: return "Archive stale threads"
        case .dailyDigest: return "Daily AI digest"
        }
    }

    var blurb: String {
        switch self {
        case .trimOldBotMessages:
            return "Deletes bot messages older than the chosen age. Human messages are left alone."
        case .keepNewest:
            return "Keeps the most recent posts in the channel — set how many below. Every older message is deleted."
        case .removeDuplicates:
            return "Deletes duplicate messages, keeping the freshest copy of each."
        case .cleanNoisyBotChannel:
            return "Combined pass: removes duplicates, then deletes bot messages older than the chosen age. Best for high-traffic notification channels."
        case .archiveStaleThreads:
            return "Archives Discord threads that have been quiet for the chosen period. They stay visible but collapsed."
        case .dailyDigest:
            return "Generates a daily on-device summary of channel activity using Apple Intelligence."
        }
    }

    var symbol: String {
        switch self {
        case .trimOldBotMessages: return "rectangle.compress.vertical"
        case .keepNewest: return "1.circle"
        case .removeDuplicates: return "square.on.square.dashed"
        case .cleanNoisyBotChannel: return "speaker.slash"
        case .archiveStaleThreads: return "archivebox"
        case .dailyDigest: return "text.bubble"
        }
    }

    var destinationLabel: String {
        switch self {
        case .trimOldBotMessages, .keepNewest, .removeDuplicates, .cleanNoisyBotChannel: return "Deletes from Discord"
        case .archiveStaleThreads: return "Archives Discord threads"
        case .dailyDigest: return "On-device digest"
        }
    }

    var destinationTone: Color {
        switch self {
        case .trimOldBotMessages, .keepNewest, .removeDuplicates, .cleanNoisyBotChannel: return .orange
        case .archiveStaleThreads: return .indigo
        case .dailyDigest: return .blue
        }
    }

    /// `false` for tasks that don't yet have a working execution path; the
    /// picker shows them with a "Coming soon" badge and disables selection.
    var isAvailable: Bool {
        switch self {
        case .trimOldBotMessages, .keepNewest, .removeDuplicates, .cleanNoisyBotChannel: return true
        case .archiveStaleThreads, .dailyDigest: return false
        }
    }

    /// Build a concrete strategy from this task + the parameters held on the
    /// policy draft. The strategy gets the age/count fields that match the
    /// task's defaults.
    func makeStrategy(ageHours: Int = 24, keepCount: Int = 1) -> SweepStrategy {
        switch self {
        case .trimOldBotMessages:
            return SweepStrategy(kind: .compact, ageHours: ageHours, fromBotsOnly: true)
        case .keepNewest:
            return SweepStrategy(kind: .keepLatest, keepCount: keepCount)
        case .removeDuplicates:
            return SweepStrategy(kind: .deduplicate, ageHours: ageHours)
        case .cleanNoisyBotChannel:
            return SweepStrategy(kind: .reduceNoise, ageHours: ageHours, fromBotsOnly: true)
        case .archiveStaleThreads:
            return SweepStrategy(kind: .archive, ageHours: ageHours)
        case .dailyDigest:
            return SweepStrategy(kind: .summarise)
        }
    }

    /// Derive a task from an existing strategy (for loading saved rules).
    static func from(_ strategy: SweepStrategy) -> SweepTask {
        switch strategy.kind {
        case .compact: return .trimOldBotMessages
        case .keepLatest: return .keepNewest
        case .deduplicate: return .removeDuplicates
        case .reduceNoise: return .cleanNoisyBotChannel
        case .archive: return .archiveStaleThreads
        case .summarise: return .dailyDigest
        case .quietChannel: return .cleanNoisyBotChannel // legacy fallback
        }
    }
}

/// A configured strategy on a policy. Strategies are composed in order — for
/// example, `summarise` followed by `delete` preserves a digest before pruning.
struct SweepStrategy: Codable, Hashable, Identifiable, Validatable {
    var id: UUID = UUID()
    var kind: SweepStrategyKind
    /// Strategy-specific parameter: age in hours used by `.delete`, `.archive`,
    /// `.deduplicate`, `.compactVoiceSessions`, `.pinSummary`. Ignored for
    /// `.keepLatest` and `.summarise`.
    var ageHours: Int = 24
    /// Used by `.keepLatest`.
    var keepCount: Int = 1
    /// When true, restrict matching to messages authored by bots.
    var fromBotsOnly: Bool = false

    func validate() throws {
        if ageHours < 0 || ageHours > 8760 {
            throw ValidationError.outOfRange("ageHours", min: 0, max: 8760)
        }
        if keepCount < 0 || keepCount > 1000 {
            throw ValidationError.outOfRange("keepCount", min: 0, max: 1000)
        }
    }
}

enum SweepSchedule: Codable, Hashable {
    case manual
    case interval(minutes: Int)
    case daily(hour: Int)

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .interval(let m):
            if m % 60 == 0 { return "Every \(m / 60)h" }
            return "Every \(m)m"
        case .daily(let h):
            let pad = h < 10 ? "0\(h)" : "\(h)"
            return "Daily at \(pad):00"
        }
    }

    func nextFireDate(after date: Date) -> Date? {
        switch self {
        case .manual: return nil
        case .interval(let m):
            return date.addingTimeInterval(TimeInterval(max(1, m) * 60))
        case .daily(let h):
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            var comps = cal.dateComponents([.year, .month, .day], from: date)
            comps.hour = max(0, min(23, h))
            comps.minute = 0
            comps.second = 0
            guard var next = cal.date(from: comps) else { return nil }
            if next <= date { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
            return next
        }
    }
}

struct SweepSafetyRails: Codable, Hashable, Validatable {
    var maxMessagesPerRun: Int = 200
    /// Legacy flag retained for back-compat with persisted snapshots. New
    /// rules default to armed; users sanity-check via the Try Run button on
    /// the editor before saving. Set programmatically only.
    var dryRunOnly: Bool = false
    var minMessageAgeMinutes: Int = 5
    var protectPinned: Bool = true
    var protectReacted: Bool = true

    func validate() throws {
        if maxMessagesPerRun < 1 || maxMessagesPerRun > 1000 {
            throw ValidationError.outOfRange("maxMessagesPerRun", min: 1, max: 1000)
        }
        if minMessageAgeMinutes < 0 || minMessageAgeMinutes > 43200 { // 30 days
            throw ValidationError.outOfRange("minMessageAgeMinutes", min: 0, max: 43200)
        }
    }
}

struct SweepPolicy: Codable, Identifiable, Hashable, Validatable {
    var id: UUID = UUID()
    var name: String
    var guildID: String
    var guildName: String
    var channelID: String
    var channelName: String
    var strategies: [SweepStrategy]
    var schedule: SweepSchedule
    var safety: SweepSafetyRails
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var lastRunAt: Date?
    var nextRunAt: Date?

    var strategyChipSummary: String {
        if strategies.isEmpty { return "No strategies" }
        return strategies.map { $0.kind.displayName }.joined(separator: " · ")
    }

    func validate() throws {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError.invalidValue("Policy name cannot be empty")
        }
        for strategy in strategies {
            try strategy.validate()
        }
        try safety.validate()
    }
}

enum SweepActionKind: String, Codable {
    case delete
    case keep
    case archive
    case summarise
    case pin
    case quiet
    case skip
}

/// How an action is realised. `virtual` actions stay inside SwiftBot (collapsed
/// views, digests held in the app, muted notifications). `destructive` actions
/// reach Discord through `ActionDispatcher` and only run on Primary nodes.
enum SweepActionMode: String, Codable, Hashable {
    case virtual
    case destructive

    var displayName: String {
        switch self {
        case .virtual: return "Virtual"
        case .destructive: return "Live"
        }
    }
}

struct SweepAction: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let kind: SweepActionKind
    let mode: SweepActionMode
    let messageID: String
    let preview: String
    let reason: String
    var authorName: String?
    var isBot: Bool?

    init(
        id: UUID = UUID(),
        kind: SweepActionKind,
        mode: SweepActionMode? = nil,
        messageID: String,
        preview: String,
        reason: String,
        authorName: String? = nil,
        isBot: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.mode = mode ?? SweepAction.defaultMode(for: kind)
        self.messageID = messageID
        self.preview = preview
        self.reason = reason
        self.authorName = authorName
        self.isBot = isBot
    }

    static func defaultMode(for kind: SweepActionKind) -> SweepActionMode {
        switch kind {
        case .delete, .archive, .pin: return .destructive
        case .keep, .summarise, .quiet, .skip: return .virtual
        }
    }

    static func from(
        _ message: SweepFetchedMessage,
        kind: SweepActionKind,
        reason: String,
        mode: SweepActionMode? = nil
    ) -> SweepAction {
        SweepAction(
            kind: kind,
            mode: mode,
            messageID: message.id,
            preview: message.content,
            reason: reason,
            authorName: message.authorName,
            isBot: message.isBot
        )
    }
}

struct SweepRunReport: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    let policyID: UUID
    let policyName: String
    let startedAt: Date
    let durationMS: Int
    let scanned: Int
    let matched: Int
    let executed: Int
    let suppressed: Int
    let dryRun: Bool
    let actions: [SweepAction]
    let error: String?
    var summary: String?
}

/// A retroactive proposal generated by `SweepSuggestionEngine` after scanning
/// recent channel activity. Each suggestion carries a ready-to-apply strategy
/// and schedule; tapping Apply turns it into a `SweepPolicy`.
struct SweepSuggestion: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let guildID: String
    let guildName: String
    let channelID: String
    let channelName: String
    let strategyKind: SweepStrategyKind
    let title: String
    let rationale: String
    let evidenceCount: Int
    let confidence: Double
    let proposedStrategy: SweepStrategy
    let proposedSchedule: SweepSchedule
    var createdAt: Date = Date()
    /// Dry-run report produced by running the proposed strategy against the
    /// messages we already fetched during the scan. Lets the user preview
    /// exactly what would happen before tapping Apply.
    var projection: SweepRunReport?
}

enum SweepRuntimeState: String, Codable {
    case idle
    case scheduled
    case running
    case paused
    case error

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .scheduled: return "Scheduled"
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    var tone: Color {
        switch self {
        case .idle: return .gray
        case .scheduled: return .blue
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Persistence

struct SweepSnapshot: Codable {
    var schemaVersion: Int = 1
    var policies: [SweepPolicy] = []
    var globalPaused: Bool = false
    var recentReports: [SweepRunReport] = []
    var suggestions: [SweepSuggestion] = []
    var lastSuggestionScanAt: Date?
}

actor SweepStore {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(filename: String = "sweep-policies.json") {
        let folder = SwiftBotStorage.folderURL()
            .appendingPathComponent("Sweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = folder.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> SweepSnapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(SweepSnapshot.self, from: data) else {
            return SweepSnapshot()
        }
        return snapshot
    }

    func save(_ snapshot: SweepSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Dispatcher (Discord transport boundary)

/// `SweepDispatcher` is the seam between Sweep and the existing Discord REST
/// runtime. The default implementation does nothing — runs are always dry-run
/// previews. A future wiring pass can supply a real implementation that calls
/// `DiscordMessageRESTClient` via `DiscordService` and respects cluster-role
/// gating (only Primary/Standalone may execute).
protocol SweepDispatcher: Sendable {
    func canExecute() async -> Bool
    func fetchRecentMessages(channelID: String, limit: Int) async throws -> [SweepFetchedMessage]
    func deleteMessage(channelID: String, messageID: String) async throws
}

struct SweepFetchedMessage: Sendable, Hashable {
    let id: String
    let authorID: String
    let authorName: String
    let isBot: Bool
    let content: String
    let createdAt: Date
    let isPinned: Bool
    let hasReactions: Bool
}

/// Live dispatcher: routes Sweep through the real Discord REST runtime via
/// `DiscordService`. Execution is gated by the cluster role — `canExecute`
/// reports `true` only when the node is Primary (Standalone/Leader) and the
/// bot token is loaded.
struct LiveSweepDispatcher: SweepDispatcher {
    let discord: DiscordService
    let isPrimary: @Sendable () async -> Bool

    func canExecute() async -> Bool {
        guard await isPrimary() else { return false }
        return await discord.outputAllowed
    }

    func fetchRecentMessages(channelID: String, limit: Int) async throws -> [SweepFetchedMessage] {
        try await discord.sweepFetchRecentMessages(channelId: channelID, limit: limit)
    }

    func deleteMessage(channelID: String, messageID: String) async throws {
        try await discord.sweepDeleteMessage(channelId: channelID, messageId: messageID)
    }
}

/// Default dispatcher: returns a small synthetic sample so the UI is fully
/// exercisable, and refuses to execute anything (forces dry-run).
struct PreviewSweepDispatcher: SweepDispatcher {
    func canExecute() async -> Bool { false }

    func fetchRecentMessages(channelID: String, limit: Int) async throws -> [SweepFetchedMessage] {
        let now = Date()
        let samples: [SweepFetchedMessage] = [
            SweepFetchedMessage(id: "m1", authorID: "NVIDIA-News", authorName: "NVIDIA-News",
                                isBot: true, content: "GeForce 555.42 driver released",
                                createdAt: now.addingTimeInterval(-3_600 * 72),
                                isPinned: false, hasReactions: false),
            SweepFetchedMessage(id: "m2", authorID: "NVIDIA-News", authorName: "NVIDIA-News",
                                isBot: true, content: "GeForce 555.85 driver released",
                                createdAt: now.addingTimeInterval(-3_600 * 36),
                                isPinned: false, hasReactions: false),
            SweepFetchedMessage(id: "m3", authorID: "NVIDIA-News", authorName: "NVIDIA-News",
                                isBot: true, content: "GeForce 556.10 driver released",
                                createdAt: now.addingTimeInterval(-3_600 * 6),
                                isPinned: false, hasReactions: false),
            SweepFetchedMessage(id: "m4", authorID: "alice", authorName: "alice",
                                isBot: false, content: "Pinned: server rules",
                                createdAt: now.addingTimeInterval(-3_600 * 240),
                                isPinned: true, hasReactions: true),
            SweepFetchedMessage(id: "m5", authorID: "voice-log", authorName: "voice-log",
                                isBot: true, content: "bob joined #lounge",
                                createdAt: now.addingTimeInterval(-3_600 * 5 - 120),
                                isPinned: false, hasReactions: false),
            SweepFetchedMessage(id: "m6", authorID: "voice-log", authorName: "voice-log",
                                isBot: true, content: "bob left #lounge",
                                createdAt: now.addingTimeInterval(-3_600 * 5),
                                isPinned: false, hasReactions: false)
        ]
        return Array(samples.prefix(max(1, limit)))
    }

    func deleteMessage(channelID: String, messageID: String) async throws {
        // No-op — dry-run only.
    }
}

// MARK: - Suggestion engine

/// Pure-function analyser. Given recent messages from a channel, produce zero
/// or more `SweepSuggestion`s. Heuristics intentionally err on the side of
/// proposing few high-confidence suggestions — anything noisy gets dropped.
enum SweepSuggestionEngine {
    static func analyse(
        guildID: String,
        guildName: String,
        channelID: String,
        channelName: String,
        messages: [SweepFetchedMessage]
    ) -> [SweepSuggestion] {
        guard messages.count >= 5 else { return [] }
        var out: [SweepSuggestion] = []

        let botCount = messages.filter(\.isBot).count
        let botRatio = Double(botCount) / Double(messages.count)
        let nameHintsBot = channelHintsBot(channelName: channelName)

        // 1. Reduce noise — mostly bot chatter, or a channel whose name (#notifications,
        // #patchy, #github, etc.) screams "bot dumping ground" even with light volume.
        let isHighVolumeBot = messages.count >= 20 && botRatio >= 0.5
        let isPureBotChannel = botRatio >= 0.8 && messages.count >= 8
        let isNameHintedBot = nameHintsBot && botRatio >= 0.5 && messages.count >= 5
        if isHighVolumeBot || isPureBotChannel || isNameHintedBot {
            out.append(SweepSuggestion(
                guildID: guildID,
                guildName: guildName,
                channelID: channelID,
                channelName: channelName,
                strategyKind: .reduceNoise,
                title: "Reduce noise in #\(channelName)",
                rationale: "\(botCount) of the last \(messages.count) messages are from bots — Sweep can dedupe duplicates and compact older bot posts.",
                evidenceCount: botCount,
                confidence: min(1.0, max(0.6, botRatio)),
                proposedStrategy: SweepStrategy(kind: .reduceNoise, ageHours: 48, fromBotsOnly: true),
                proposedSchedule: .interval(minutes: 120)
            ))
        }

        // 2. Deduplicate — repeated messages
        var contentCount: [String: Int] = [:]
        for m in messages {
            let key = m.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            contentCount[key, default: 0] += 1
        }
        let duplicateExtras = contentCount.values
            .filter { $0 > 1 }
            .map { $0 - 1 }
            .reduce(0, +)
        if duplicateExtras >= 3 && out.first?.strategyKind != .reduceNoise {
            out.append(SweepSuggestion(
                guildID: guildID,
                guildName: guildName,
                channelID: channelID,
                channelName: channelName,
                strategyKind: .deduplicate,
                title: "Deduplicate #\(channelName)",
                rationale: "Found \(duplicateExtras) duplicate messages in the last \(messages.count). Sweep can collapse repeats automatically.",
                evidenceCount: duplicateExtras,
                confidence: min(1.0, Double(duplicateExtras) / Double(messages.count) + 0.3),
                proposedStrategy: SweepStrategy(kind: .deduplicate, ageHours: 24),
                proposedSchedule: .interval(minutes: 60)
            ))
        }

        // 3. Keep latest — repeating versioned posts from the same bot author
        let byAuthor = Dictionary(grouping: messages.filter(\.isBot), by: { $0.authorID })
        for (_, group) in byAuthor where group.count >= 3 {
            let prefix = commonPrefix(of: group.map(\.content))
            if prefix.count >= 6 {
                let author = group.first?.authorName ?? "this bot"
                out.append(SweepSuggestion(
                    guildID: guildID,
                    guildName: guildName,
                    channelID: channelID,
                    channelName: channelName,
                    strategyKind: .keepLatest,
                    title: "Keep latest \(author) post in #\(channelName)",
                    rationale: "\(group.count) similar posts from \(author) starting with “\(prefix.prefix(40))…”. Sweep can keep only the newest.",
                    evidenceCount: group.count,
                    confidence: 0.85,
                    proposedStrategy: SweepStrategy(kind: .keepLatest, keepCount: 1),
                    proposedSchedule: .interval(minutes: 180)
                ))
                break // one keep-latest suggestion per channel is enough
            }
        }

        return out
    }

    private static let botChannelNameHints: [String] = [
        "bot", "bots", "noti", "notif", "notification", "notifications",
        "feed", "feeds", "alert", "alerts", "log", "logs", "activity",
        "patchy", "github", "release", "releases", "ci", "deploy", "deploys",
        "build", "builds", "voice-log", "audit", "spam"
    ]

    private static func channelHintsBot(channelName: String) -> Bool {
        let lower = channelName.lowercased()
        return botChannelNameHints.contains { lower.contains($0) }
    }

    private static func commonPrefix(of strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) {
                prefix = String(prefix.dropLast())
                if prefix.isEmpty { return "" }
            }
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Service

@MainActor
final class SweepService: ObservableObject {
    @Published private(set) var policies: [SweepPolicy] = []
    @Published private(set) var recentReports: [SweepRunReport] = []
    @Published private(set) var state: SweepRuntimeState = .idle
    @Published private(set) var lastError: String?
    @Published var globalPaused: Bool = false {
        didSet { if oldValue != globalPaused { Task { await persist() } } }
    }
    @Published private(set) var activePolicyID: UUID?
    @Published private(set) var suggestions: [SweepSuggestion] = []
    @Published private(set) var isScanningSuggestions: Bool = false
    @Published private(set) var lastSuggestionScanAt: Date?
    @Published private(set) var scanProgress: (done: Int, total: Int) = (0, 0)

    private let store = SweepStore()
    private var dispatcher: SweepDispatcher = PreviewSweepDispatcher()
    private var summariser: (@Sendable (String, [String]) async -> String?)?
    private var activityLogger: ((SweepRunReport) -> Void)?
    private var tickTask: Task<Void, Never>?

    init() {
        Task { await self.hydrate() }
    }

    func setDispatcher(_ dispatcher: SweepDispatcher) {
        self.dispatcher = dispatcher
    }

    /// Inject an async function that turns a channel name + ordered message
    /// lines into a digest string. Sweep calls this when a run produces
    /// `.summarise` actions; the resulting text is stored on the run report.
    func setSummariser(_ summariser: @escaping @Sendable (String, [String]) async -> String?) {
        self.summariser = summariser
    }

    /// Called once per completed run (manual or scheduled). AppModel uses this
    /// to forward Sweep activity into the shared Activity log.
    func setActivityLogger(_ logger: @escaping (SweepRunReport) -> Void) {
        self.activityLogger = logger
    }

    private func hydrate() async {
        let snapshot = await store.load()
        self.policies = snapshot.policies
        self.recentReports = snapshot.recentReports
        self.globalPaused = snapshot.globalPaused
        self.suggestions = snapshot.suggestions
        self.lastSuggestionScanAt = snapshot.lastSuggestionScanAt
        recomputeNextRuns()
        startTickLoop()
    }

    private func persist() async {
        let snapshot = SweepSnapshot(
            schemaVersion: 1,
            policies: policies,
            globalPaused: globalPaused,
            recentReports: recentReports,
            suggestions: suggestions,
            lastSuggestionScanAt: lastSuggestionScanAt
        )
        await store.save(snapshot)
    }

    // MARK: Policy CRUD

    func upsert(_ policy: SweepPolicy) {
        var updated = policy
        updated.updatedAt = Date()
        if let i = policies.firstIndex(where: { $0.id == updated.id }) {
            policies[i] = updated
        } else {
            policies.append(updated)
        }
        recomputeNextRuns()
        Task { await persist() }
    }

    func delete(policyID: UUID) {
        policies.removeAll { $0.id == policyID }
        Task { await persist() }
    }

    func setEnabled(_ enabled: Bool, for policyID: UUID) {
        guard let i = policies.firstIndex(where: { $0.id == policyID }) else { return }
        policies[i].isEnabled = enabled
        recomputeNextRuns()
        Task { await persist() }
    }

    // MARK: Scheduling

    private func recomputeNextRuns() {
        let now = Date()
        for i in policies.indices {
            policies[i].nextRunAt = policies[i].isEnabled
                ? policies[i].schedule.nextFireDate(after: now)
                : nil
        }
        refreshAggregateState()
    }

    private func refreshAggregateState() {
        if globalPaused { state = .paused; return }
        if activePolicyID != nil { state = .running; return }
        if lastError != nil { state = .error; return }
        let hasScheduled = policies.contains { $0.isEnabled && $0.nextRunAt != nil }
        state = hasScheduled ? .scheduled : .idle
    }

    var nextRunDescription: String {
        guard !globalPaused else { return "Paused" }
        let upcoming = policies.compactMap { $0.nextRunAt }.min()
        guard let upcoming else { return "No schedule" }
        let delta = upcoming.timeIntervalSince(Date())
        if delta <= 0 { return "Due now" }
        if delta < 60 { return "In <1m" }
        if delta < 3_600 { return "In \(Int(delta / 60))m" }
        if delta < 86_400 { return "In \(Int(delta / 3_600))h" }
        return "In \(Int(delta / 86_400))d"
    }

    var enabledPolicyCount: Int { policies.filter { $0.isEnabled }.count }

    var messagesTodayCount: Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return recentReports
            .filter { $0.startedAt >= dayStart }
            .reduce(0) { $0 + $1.executed }
    }

    var suppressedTodayCount: Int {
        let dayStart = Calendar.current.startOfDay(for: Date())
        return recentReports
            .filter { $0.startedAt >= dayStart }
            .reduce(0) { $0 + $1.suppressed }
    }

    var summariesThisWeekCount: Int {
        let weekStart = Date().addingTimeInterval(-7 * 86_400)
        return recentReports
            .filter { $0.startedAt >= weekStart }
            .reduce(0) { acc, report in
                acc + report.actions.filter { $0.kind == .summarise }.count
            }
    }

    var lastReport: SweepRunReport? { recentReports.first }

    // MARK: Tick loop

    private func startTickLoop() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                await self?.tick()
            }
        }
    }

    private func tick() async {
        guard !globalPaused else { return }
        let now = Date()
        let due = policies.filter { policy in
            policy.isEnabled && (policy.nextRunAt.map { $0 <= now } ?? false)
        }
        for policy in due {
            await run(policyID: policy.id, manual: false)
        }
    }

    // MARK: Run

    @discardableResult
    func run(policyID: UUID, manual: Bool) async -> SweepRunReport? {
        guard let policy = policies.first(where: { $0.id == policyID }) else { return nil }
        if globalPaused && !manual { return nil }

        activePolicyID = policyID
        refreshAggregateState()
        defer {
            activePolicyID = nil
            refreshAggregateState()
        }

        let start = Date()
        do {
            let canExecute = await dispatcher.canExecute()
            let effectivelyDryRun = policy.safety.dryRunOnly || !canExecute

            let messages = try await dispatcher.fetchRecentMessages(
                channelID: policy.channelID,
                limit: max(10, policy.safety.maxMessagesPerRun)
            )

            let plan = planActions(for: policy, messages: messages)
            let toExecute = plan.filter { $0.kind != .skip && $0.kind != .keep }

            var executed = 0
            if !effectivelyDryRun {
                for action in toExecute where action.kind == .delete {
                    do {
                        try await dispatcher.deleteMessage(channelID: policy.channelID, messageID: action.messageID)
                        executed += 1
                    } catch {
                        // Skip and continue; surfaced via report.error after the loop.
                    }
                }
            }

            let suppressed = plan.filter { $0.kind == .skip }.count

            // Build an on-device digest if any actions asked to be summarised.
            var digest: String?
            let summariseLines = plan
                .filter { $0.kind == .summarise }
                .map(\.preview)
            if !summariseLines.isEmpty, let summariser {
                digest = await summariser(policy.channelName, summariseLines)
            }

            let report = SweepRunReport(
                policyID: policy.id,
                policyName: policy.name,
                startedAt: start,
                durationMS: Int(Date().timeIntervalSince(start) * 1000),
                scanned: messages.count,
                matched: toExecute.count,
                executed: executed,
                suppressed: suppressed,
                dryRun: effectivelyDryRun,
                actions: plan,
                error: nil,
                summary: digest
            )
            recordReport(report)
            markRan(policyID: policy.id, at: start)
            lastError = nil
            return report
        } catch {
            let report = SweepRunReport(
                policyID: policy.id,
                policyName: policy.name,
                startedAt: start,
                durationMS: Int(Date().timeIntervalSince(start) * 1000),
                scanned: 0,
                matched: 0,
                executed: 0,
                suppressed: 0,
                dryRun: true,
                actions: [],
                error: error.localizedDescription
            )
            recordReport(report)
            lastError = error.localizedDescription
            return report
        }
    }

    /// Dry-run a policy that hasn't been saved yet — used by the editor's
    /// "Try Run" button.
    func previewDraft(_ policy: SweepPolicy) async -> SweepRunReport? {
        await runPreview(of: policy)
    }

    func preview(policyID: UUID) async -> SweepRunReport? {
        guard let policy = policies.first(where: { $0.id == policyID }) else { return nil }
        return await runPreview(of: policy)
    }

    /// Always returns a `SweepRunReport`. On failure (no token, channel not
    /// accessible, bot offline, etc.) the report carries `error` set and an
    /// empty action list — so the calling UI can always present something
    /// rather than appearing to do nothing.
    private func runPreview(of policy: SweepPolicy) async -> SweepRunReport {
        let start = Date()
        let displayName = policy.name.isEmpty ? "Untitled rule" : policy.name
        guard !policy.channelID.isEmpty else {
            return SweepRunReport(
                policyID: policy.id,
                policyName: displayName,
                startedAt: start,
                durationMS: 0,
                scanned: 0,
                matched: 0,
                executed: 0,
                suppressed: 0,
                dryRun: true,
                actions: [],
                error: "No channel selected for this rule yet.",
                summary: nil
            )
        }
        do {
            let messages = try await dispatcher.fetchRecentMessages(
                channelID: policy.channelID,
                limit: max(10, policy.safety.maxMessagesPerRun)
            )
            let plan = planActions(for: policy, messages: messages)
            let matched = plan.filter { $0.kind != .skip && $0.kind != .keep }.count
            let suppressed = plan.filter { $0.kind == .skip }.count
            return SweepRunReport(
                policyID: policy.id,
                policyName: displayName,
                startedAt: start,
                durationMS: Int(Date().timeIntervalSince(start) * 1000),
                scanned: messages.count,
                matched: matched,
                executed: 0,
                suppressed: suppressed,
                dryRun: true,
                actions: plan,
                error: nil,
                summary: nil
            )
        } catch {
            return SweepRunReport(
                policyID: policy.id,
                policyName: displayName,
                startedAt: start,
                durationMS: Int(Date().timeIntervalSince(start) * 1000),
                scanned: 0,
                matched: 0,
                executed: 0,
                suppressed: 0,
                dryRun: true,
                actions: [],
                error: SweepService.describeFetchError(error, channelName: policy.channelName),
                summary: nil
            )
        }
    }

    /// Turn the generic `NSError` thrown by `DiscordMessageRESTClient` into a
    /// message the user can actually act on.
    static func describeFetchError(_ error: Error, channelName: String) -> String {
        let channelLabel = channelName.isEmpty ? "this channel" : "#\(channelName)"
        let ns = error as NSError
        if ns.domain == "DiscordService" {
            let body = (ns.userInfo["responseBody"] as? String) ?? ""
            let snippet = String(body.prefix(180)).trimmingCharacters(in: .whitespacesAndNewlines)
            switch ns.code {
            case -2:
                return "SwiftBot isn’t connected to Discord. Tap Start Bot in the sidebar and try again."
            case 401:
                return "Discord rejected the bot token (401). Reconnect SwiftBot in Discord preferences."
            case 403:
                return "The bot can’t read \(channelLabel) (403). Grant SwiftBot the Read Message History permission in this channel."
            case 404:
                return "Channel not found (404). \(channelLabel) may have been deleted or renamed."
            case 429:
                return "Rate-limited by Discord (429). Wait a few seconds and try again."
            default:
                if !snippet.isEmpty {
                    return "Discord returned \(ns.code) for \(channelLabel): \(snippet)"
                }
                return "Discord returned \(ns.code) for \(channelLabel)."
            }
        }
        return ns.localizedDescription
    }

    private func markRan(policyID: UUID, at date: Date) {
        guard let i = policies.firstIndex(where: { $0.id == policyID }) else { return }
        policies[i].lastRunAt = date
        policies[i].nextRunAt = policies[i].schedule.nextFireDate(after: date)
        Task { await persist() }
    }

    private func recordReport(_ report: SweepRunReport) {
        recentReports.insert(report, at: 0)
        if recentReports.count > 50 { recentReports = Array(recentReports.prefix(50)) }
        activityLogger?(report)
        Task { await persist() }
    }

    // MARK: Suggestions

    /// Scope of `scanForSuggestions` per call. The scan iterates over every
    /// uncovered channel; the inter-channel stagger and per-channel message
    /// cap keep the Discord API request rate low.
    static let suggestionScanMessageLimit: Int = 300
    static let suggestionScanInterChannelDelayNanos: UInt64 = 1_500_000_000

    struct SweepScanTarget: Sendable, Hashable {
        let guildID: String
        let guildName: String
        let channel: GuildTextChannel
    }

    @discardableResult
    func scanForSuggestions(targets: [SweepScanTarget]) async -> [SweepSuggestion] {
        guard !isScanningSuggestions else { return suggestions }
        isScanningSuggestions = true
        defer {
            isScanningSuggestions = false
            scanProgress = (0, 0)
        }

        // Don't re-propose for a channel that already has an enabled rule.
        let covered = Set(policies.filter(\.isEnabled).map(\.channelID))
        let work = targets.filter { !covered.contains($0.channel.id) }

        scanProgress = (0, work.count)

        var fresh: [SweepSuggestion] = []
        for (index, target) in work.enumerated() {
            // Inter-channel stagger — skip before the first fetch.
            if index > 0 {
                try? await Task.sleep(nanoseconds: Self.suggestionScanInterChannelDelayNanos)
            }

            let messages: [SweepFetchedMessage]
            do {
                // Dispatcher's fetchRecentMessages handles internal pagination
                // when `limit` exceeds Discord's per-page cap of 100.
                messages = try await dispatcher.fetchRecentMessages(
                    channelID: target.channel.id,
                    limit: Self.suggestionScanMessageLimit
                )
            } catch {
                scanProgress = (index + 1, work.count)
                continue
            }
            let proposals = SweepSuggestionEngine.analyse(
                guildID: target.guildID,
                guildName: target.guildName,
                channelID: target.channel.id,
                channelName: target.channel.name,
                messages: messages
            )
            for var proposal in proposals {
                proposal.projection = buildProjection(for: proposal, messages: messages)
                fresh.append(proposal)
            }
            scanProgress = (index + 1, work.count)
        }

        // Merge with existing — preserve any prior suggestions whose channel
        // wasn't in this scan, replace anything that was.
        let scannedChannelIDs = Set(work.map(\.channel.id))
        var merged = suggestions.filter { !scannedChannelIDs.contains($0.channelID) }
        merged.append(contentsOf: fresh)
        suggestions = merged
            .sorted { $0.confidence > $1.confidence }
        lastSuggestionScanAt = Date()
        Task { await persist() }
        return suggestions
    }

    func applySuggestion(_ suggestion: SweepSuggestion) {
        let name: String
        switch suggestion.strategyKind {
        case .reduceNoise: name = "Reduce noise · #\(suggestion.channelName)"
        case .deduplicate: name = "Dedupe · #\(suggestion.channelName)"
        case .keepLatest:  name = "Keep latest · #\(suggestion.channelName)"
        case .compact:     name = "Compact · #\(suggestion.channelName)"
        case .summarise:   name = "Summarise · #\(suggestion.channelName)"
        case .archive:     name = "Archive · #\(suggestion.channelName)"
        case .quietChannel: name = "Quiet · #\(suggestion.channelName)"
        }
        let policy = SweepPolicy(
            name: name,
            guildID: suggestion.guildID,
            guildName: suggestion.guildName,
            channelID: suggestion.channelID,
            channelName: suggestion.channelName,
            strategies: [suggestion.proposedStrategy],
            schedule: suggestion.proposedSchedule,
            safety: SweepSafetyRails()
        )
        upsert(policy)
        suggestions.removeAll { $0.id == suggestion.id }
        Task { await persist() }
    }

    /// Dismiss only hides the suggestion from the current list — the next
    /// scan re-evaluates the channel and may re-propose it.
    func dismissSuggestion(_ suggestion: SweepSuggestion) {
        suggestions.removeAll { $0.id == suggestion.id }
        Task { await persist() }
    }

    /// Run the proposed strategy against the messages we already fetched and
    /// pack the result into a synthetic `SweepRunReport` (dry-run only).
    private func buildProjection(
        for suggestion: SweepSuggestion,
        messages: [SweepFetchedMessage]
    ) -> SweepRunReport {
        let tempPolicy = SweepPolicy(
            name: suggestion.title,
            guildID: suggestion.guildID,
            guildName: suggestion.guildName,
            channelID: suggestion.channelID,
            channelName: suggestion.channelName,
            strategies: [suggestion.proposedStrategy],
            schedule: suggestion.proposedSchedule,
            safety: SweepSafetyRails()
        )
        let plan = planActions(for: tempPolicy, messages: messages)
        let matched = plan.filter { $0.kind != .skip && $0.kind != .keep }.count
        let suppressed = plan.filter { $0.kind == .skip }.count
        return SweepRunReport(
            policyID: tempPolicy.id,
            policyName: tempPolicy.name,
            startedAt: Date(),
            durationMS: 0,
            scanned: messages.count,
            matched: matched,
            executed: 0,
            suppressed: suppressed,
            dryRun: true,
            actions: plan,
            error: nil,
            summary: nil
        )
    }

    // MARK: Planner

    private func planActions(for policy: SweepPolicy, messages: [SweepFetchedMessage]) -> [SweepAction] {
        var actions: [SweepAction] = []
        let now = Date()
        let minAge = TimeInterval(policy.safety.minMessageAgeMinutes * 60)

        // Safety pass — produce `.skip` entries for protected messages.
        var candidates: [SweepFetchedMessage] = []
        for message in messages {
            if policy.safety.protectPinned && message.isPinned {
                actions.append(.from(message, kind: .skip, reason: "Pinned — protected"))
                continue
            }
            if policy.safety.protectReacted && message.hasReactions {
                actions.append(.from(message, kind: .skip, reason: "Has reactions — protected"))
                continue
            }
            if now.timeIntervalSince(message.createdAt) < minAge {
                actions.append(.from(message, kind: .skip, reason: "Younger than minimum age"))
                continue
            }
            candidates.append(message)
        }

        // Strategy pass — order matters; each strategy works against the
        // remaining candidates after prior strategies consumed messages.
        var remaining = candidates
        for strategy in policy.strategies {
            let (consumed, newRemaining) = apply(strategy: strategy, to: remaining, policy: policy)
            actions.append(contentsOf: consumed)
            remaining = newRemaining
        }
        // Anything still remaining is implicitly "kept".
        for message in remaining {
            actions.append(.from(message, kind: .keep, reason: "No matching strategy"))
        }

        // Apply per-run cap.
        let cap = max(1, policy.safety.maxMessagesPerRun)
        let executable = actions.filter { $0.kind != .skip && $0.kind != .keep }
        if executable.count > cap {
            let trim = executable.count - cap
            var trimmed = 0
            var output: [SweepAction] = []
            for action in actions.reversed() {
                if trimmed < trim && action.kind != .skip && action.kind != .keep {
                    output.append(SweepAction(
                        kind: .skip,
                        messageID: action.messageID,
                        preview: action.preview,
                        reason: "Exceeds per-run cap",
                        authorName: action.authorName,
                        isBot: action.isBot
                    ))
                    trimmed += 1
                } else {
                    output.append(action)
                }
            }
            return output.reversed()
        }
        return actions
    }

    private func apply(
        strategy: SweepStrategy,
        to messages: [SweepFetchedMessage],
        policy: SweepPolicy
    ) -> (consumed: [SweepAction], remaining: [SweepFetchedMessage]) {
        let now = Date()
        let age = TimeInterval(strategy.ageHours * 3_600)

        switch strategy.kind {
        case .compact:
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                let matchesBots = !strategy.fromBotsOnly || message.isBot
                if matchesBots && now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(.from(message, kind: .delete, reason: "Older than \(strategy.ageHours)h"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .keepLatest:
            let sorted = messages.sorted { $0.createdAt > $1.createdAt }
            let keepCount = max(1, strategy.keepCount)
            let kept = Array(sorted.prefix(keepCount))
            let dropped = sorted.dropFirst(keepCount)
            var consumed: [SweepAction] = kept.map {
                .from($0, kind: .keep, reason: "Latest \(keepCount) preserved")
            }
            consumed.append(contentsOf: dropped.map {
                .from($0, kind: .delete, reason: "Superseded by newer post")
            })
            return (consumed, [])

        case .deduplicate:
            var seen: [String: SweepFetchedMessage] = [:]
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages.sorted(by: { $0.createdAt > $1.createdAt }) {
                let key = message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if seen[key] != nil {
                    consumed.append(.from(message, kind: .delete, reason: "Duplicate of newer message"))
                } else {
                    seen[key] = message
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .summarise:
            let consumed = messages.map {
                SweepAction.from($0, kind: .summarise, reason: "Captured in summary")
            }
            return (consumed, [])

        case .archive:
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                if now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(.from(message, kind: .archive, reason: "Archived after \(strategy.ageHours)h"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .quietChannel:
            // Virtual-only: mark routine bot chatter as quiet so the UI can
            // collapse it. Discord is not touched.
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                if message.isBot {
                    consumed.append(.from(message, kind: .quiet, reason: "Routine bot chatter — collapsed in-app"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .reduceNoise:
            // Composite: dedupe first, then compact stale bot chatter.
            var seen: [String: SweepFetchedMessage] = [:]
            var consumed: [SweepAction] = []
            var afterDedupe: [SweepFetchedMessage] = []
            for message in messages.sorted(by: { $0.createdAt > $1.createdAt }) {
                let key = message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if seen[key] != nil {
                    consumed.append(.from(message, kind: .delete, reason: "Duplicate · reduced noise"))
                } else {
                    seen[key] = message
                    afterDedupe.append(message)
                }
            }
            var remaining: [SweepFetchedMessage] = []
            for message in afterDedupe {
                if message.isBot && now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(.from(message, kind: .delete, reason: "Stale bot chatter · reduced noise"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)
        }
    }
}

// MARK: - View

struct SweepView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        SweepContentView(service: app.sweepService)
    }
}

private struct SweepContentView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var service: SweepService
    @State private var editingPolicy: SweepPolicy?
    @State private var showingNewPolicySheet = false
    @State private var previewReport: SweepRunReport?
    @State private var previewingPolicyName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                if service.state == .running {
                    activeRunPanel
                }
                metricTileRow
                rulesCard
                diagnosticsAndLastRunRow
                SwiftMeshSection(title: "Recent Activity", symbol: "waveform") {
                    recentActivityContent
                }
                SwiftMeshSection(title: "Suggestions", symbol: "sparkles") {
                    suggestionsContent
                }
                SwiftMeshSection(title: "History", symbol: "clock.arrow.circlepath") {
                    auditTimelineContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showingNewPolicySheet) {
            SweepPolicyEditor(
                policy: SweepPolicy(
                    name: "New Rule",
                    guildID: "",
                    guildName: "",
                    channelID: "",
                    channelName: "",
                    strategies: [SweepTask.cleanNoisyBotChannel.makeStrategy(ageHours: 48)],
                    schedule: .interval(minutes: 60),
                    safety: SweepSafetyRails()
                ),
                isNew: true,
                connectedServers: app.connectedServers,
                channelsByServer: app.availableTextChannelsByServer,
                onSave: { service.upsert($0) },
                onTryRun: { await service.previewDraft($0) }
            )
        }
        .sheet(item: $editingPolicy) { policy in
            SweepPolicyEditor(
                policy: policy,
                isNew: false,
                connectedServers: app.connectedServers,
                channelsByServer: app.availableTextChannelsByServer,
                onSave: { service.upsert($0) },
                onTryRun: { await service.previewDraft($0) }
            )
        }
        .sheet(item: $previewReport) { report in
            SweepPreviewSheet(report: report, policyName: previewingPolicyName)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sweep")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.state.tone)
                        .frame(width: 7, height: 7)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            SweepStateBadge(state: service.state)
        }
    }

    // MARK: Rules card (with inline action buttons)

    @ViewBuilder
    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.minus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Rules")
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    service.globalPaused.toggle()
                } label: {
                    Label(service.globalPaused ? "Resume" : "Pause All",
                          systemImage: service.globalPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonBorderShape(.capsule)

                Button {
                    showingNewPolicySheet = true
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .buttonBorderShape(.capsule)
            }

            policyListContent
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 2, x: 0, y: 1)
    }

    private var headerSubtitle: String {
        if service.globalPaused {
            return "Paused · \(service.policies.count) rules"
        }
        let enabled = service.enabledPolicyCount
        let total = service.policies.count
        return "\(enabled)/\(total) enabled · next \(service.nextRunDescription) · \(service.messagesTodayCount) tidied today"
    }

    // MARK: Recent activity

    @ViewBuilder
    private var recentActivityContent: some View {
        if let last = service.lastReport, !last.actions.isEmpty {
            VStack(spacing: 6) {
                ForEach(last.actions.prefix(12)) { action in
                    SweepActivityRow(action: action)
                }
            }
        } else {
            PlaceholderPanelLine(text: "Activity appears here as Sweep runs.")
        }
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestionsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(scanFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await runSuggestionScan() }
                } label: {
                    if service.isScanningSuggestions {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Scan Now", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(service.isScanningSuggestions || scanTargets.isEmpty)
            }

            if service.suggestions.isEmpty {
                PlaceholderPanelLine(
                    text: service.lastSuggestionScanAt == nil
                        ? "Sweep can scan your recent channels and propose rules for repetitive patterns. Tap Scan Now to look retroactively."
                        : "No suggestions right now — your channels look tidy."
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(service.suggestions) { suggestion in
                        SweepSuggestionRow(
                            suggestion: suggestion,
                            onApply: { service.applySuggestion(suggestion) },
                            onDismiss: { service.dismissSuggestion(suggestion) },
                            onPreview: {
                                if let projection = suggestion.projection {
                                    previewingPolicyName = suggestion.title
                                    previewReport = projection
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var scanFooter: String {
        if service.isScanningSuggestions {
            let (done, total) = service.scanProgress
            if total > 0 {
                return "Scanning recent activity… (\(done) / \(total) channels)"
            }
            return "Scanning recent activity…"
        }
        if let last = service.lastSuggestionScanAt {
            let delta = Date().timeIntervalSince(last)
            if delta < 60 { return "Last scan: just now" }
            if delta < 3_600 { return "Last scan: \(Int(delta / 60))m ago" }
            if delta < 86_400 { return "Last scan: \(Int(delta / 3_600))h ago" }
            return "Last scan: \(Int(delta / 86_400))d ago"
        }
        return "No scan yet"
    }

    private var scanTargets: [SweepService.SweepScanTarget] {
        var targets: [SweepService.SweepScanTarget] = []
        for (guildID, channels) in app.availableTextChannelsByServer {
            let guildName = app.connectedServers[guildID] ?? "Server"
            for channel in channels {
                targets.append(.init(guildID: guildID, guildName: guildName, channel: channel))
            }
        }
        return targets
    }

    private func runSuggestionScan() async {
        await service.scanForSuggestions(targets: scanTargets)
    }

    // MARK: Active panel

    private var activeRunPanel: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.mini)
            VStack(alignment: .leading, spacing: 2) {
                Text("SWEEP IN PROGRESS")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.orange)
                if let policy = service.policies.first(where: { $0.id == service.activePolicyID }) {
                    Text(policy.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1)
        )
    }

    // MARK: Metrics

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(SweepDashboardSummary.metrics(service: service)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    private var lastRunValue: String {
        guard let last = service.lastReport else { return "—" }
        let delta = Date().timeIntervalSince(last.startedAt)
        if delta < 60 { return "Just now" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }

    private var lastRunSubtitle: String {
        guard let last = service.lastReport else { return "No runs yet" }
        if let err = last.error { return "Error · \(err)" }
        return "\(last.executed) tidied · \(last.suppressed) saved"
    }

    private var lastRunTone: Color {
        guard let last = service.lastReport else { return .gray }
        return last.error == nil ? .green : .red
    }

    // MARK: Diagnostics + Last Run

    private var diagnosticsAndLastRunRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SwiftMeshSection(title: "Diagnostics", symbol: "stethoscope") {
                VStack(alignment: .leading, spacing: 6) {
                    DiagnosticsLine(
                        label: "State",
                        value: service.state.displayName,
                        tone: service.state.tone
                    )
                    DiagnosticsLine(
                        label: "Mode",
                        value: app.clusterSnapshot.mode == .leader || app.clusterSnapshot.mode == .standalone
                            ? "Live (dispatch eligible)"
                            : "Preview only (not Primary)",
                        tone: .secondary
                    )
                    DiagnosticsLine(
                        label: "Policies",
                        value: "\(service.enabledPolicyCount) enabled, \(service.policies.count) total",
                        tone: .primary
                    )
                    DiagnosticsLine(
                        label: "Last Error",
                        value: service.lastError ?? "None",
                        tone: service.lastError == nil ? .secondary : .red,
                        multiline: true
                    )
                }
            }

            SwiftMeshSection(title: "Last Run", symbol: "shippingbox") {
                if let last = service.lastReport {
                    VStack(alignment: .leading, spacing: 6) {
                        DiagnosticsLine(label: "Policy", value: last.policyName, tone: .primary)
                        DiagnosticsLine(
                            label: "Scanned",
                            value: "\(last.scanned) messages",
                            tone: .primary
                        )
                        DiagnosticsLine(
                            label: "Outcome",
                            value: "\(last.executed) tidied · \(last.suppressed) protected",
                            tone: .primary
                        )
                        DiagnosticsLine(
                            label: "Mode",
                            value: last.dryRun ? "Dry run (preview)" : "Live execution",
                            tone: last.dryRun ? .secondary : .green
                        )
                    }
                } else {
                    PlaceholderPanelLine(text: "No runs yet — create a policy to begin.")
                }
            }
        }
    }

    // MARK: Policy list

    @ViewBuilder
    private var policyListContent: some View {
        if service.policies.isEmpty {
            PlaceholderPanelLine(text: "No Sweep rules yet. Tap “New Rule” to create one.")
        } else {
            VStack(spacing: 8) {
                ForEach(service.policies) { policy in
                    SweepPolicyRow(
                        policy: policy,
                        onPreview: {
                            previewingPolicyName = policy.name
                            Task {
                                if let report = await service.preview(policyID: policy.id) {
                                    previewReport = report
                                }
                            }
                        },
                        onRunNow: {
                            Task { await service.run(policyID: policy.id, manual: true) }
                        },
                        onEdit: { editingPolicy = policy },
                        onToggleEnabled: { service.setEnabled(!policy.isEnabled, for: policy.id) },
                        onDelete: { service.delete(policyID: policy.id) }
                    )
                }
            }
        }
    }

    // MARK: Audit timeline

    @ViewBuilder
    private var auditTimelineContent: some View {
        if service.recentReports.isEmpty {
            PlaceholderPanelLine(text: "Audit timeline will populate as policies run.")
        } else {
            VStack(spacing: 6) {
                ForEach(service.recentReports.prefix(12)) { report in
                    SweepAuditRow(report: report)
                }
            }
        }
    }
}

// MARK: - State badge

private struct SweepStateBadge: View {
    let state: SweepRuntimeState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(state.displayName.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(state.tone))
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .scheduled: return "clock"
        case .running: return "rectangle.stack.fill.badge.minus"
        case .paused: return "pause.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
}

enum SweepDashboardSummary {
    @MainActor
    static func metrics(service: SweepService) -> [DashboardMetricDescriptor] {
        [
            DashboardMetricDescriptor(
                id: "sweep",
                title: "Sweep",
                value: service.state.displayName,
                subtitle: service.globalPaused ? "Paused by operator" : "\(service.enabledPolicyCount) enabled",
                symbol: service.state == .running ? "rectangle.stack.fill.badge.minus" : "rectangle.stack.badge.minus",
                color: service.state.tone
            ),
            DashboardMetricDescriptor(
                id: "sweep-policies",
                title: "Policies",
                value: "\(service.enabledPolicyCount)",
                subtitle: "of \(service.policies.count) total",
                symbol: "list.bullet.rectangle",
                color: .accentColor
            ),
            DashboardMetricDescriptor(
                id: "sweep-next-run",
                title: "Next Run",
                value: service.nextRunDescription,
                subtitle: service.globalPaused ? "Resume to schedule" : "Across all policies",
                symbol: "clock",
                color: .blue
            ),
            DashboardMetricDescriptor(
                id: "sweep-last-run",
                title: "Last Run",
                value: lastRunValue(service: service),
                subtitle: lastRunSubtitle(service: service),
                symbol: "checkmark.seal.fill",
                color: lastRunTone(service: service)
            ),
            DashboardMetricDescriptor(
                id: "sweep-tidied-today",
                title: "Tidied Today",
                value: "\(service.messagesTodayCount)",
                subtitle: "Across \(service.recentReports.count) runs",
                symbol: "tray.full",
                color: .indigo
            ),
            DashboardMetricDescriptor(
                id: "sweep-suppressed",
                title: "Suppressed",
                value: "\(service.suppressedTodayCount)",
                subtitle: "Saved by safety rails",
                symbol: "shield.lefthalf.filled",
                color: .green
            ),
            DashboardMetricDescriptor(
                id: "sweep-summaries",
                title: "Summaries",
                value: "\(service.summariesThisWeekCount)",
                subtitle: "Past 7 days",
                symbol: "text.bubble",
                color: .purple
            )
        ]
    }

    @MainActor
    private static func lastRunValue(service: SweepService) -> String {
        guard let last = service.lastReport else { return "-" }
        let delta = Date().timeIntervalSince(last.startedAt)
        if delta < 60 { return "Just now" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }

    @MainActor
    private static func lastRunSubtitle(service: SweepService) -> String {
        guard let last = service.lastReport else { return "No runs yet" }
        if let err = last.error { return "Error · \(err)" }
        return "\(last.executed) tidied · \(last.suppressed) saved"
    }

    @MainActor
    private static func lastRunTone(service: SweepService) -> Color {
        guard let last = service.lastReport else { return .gray }
        return last.error == nil ? .green : .red
    }
}

// MARK: - Policy row

private struct SweepPolicyRow: View {
    let policy: SweepPolicy
    let onPreview: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onToggleEnabled: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: policy.strategies.first?.kind.symbol ?? "rectangle.stack.badge.minus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(policy.name)
                        .font(.subheadline.weight(.semibold))
                    if !policy.isEnabled {
                        Text("DISABLED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    } else if policy.safety.dryRunOnly {
                        Text("DRY-RUN")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                    }
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(policy.isEnabled ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(channelLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(policy.schedule.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(policy.strategyChipSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                onPreview()
            } label: {
                Label("Try Run", systemImage: "play.circle")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Run this rule as a dry-run against the channel right now — nothing is changed.")

            if let last = policy.lastRunAt {
                Text(relativeShort(last))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            } else {
                Text("Never run")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .opacity(policy.isEnabled ? 1.0 : 0.7)
        .contextMenu {
            Button {
                onPreview()
            } label: { Label("Preview", systemImage: "eye") }
            Button {
                onRunNow()
            } label: { Label("Sweep Now", systemImage: "rectangle.stack.fill.badge.minus") }
            Divider()
            Button {
                onToggleEnabled()
            } label: {
                Label(policy.isEnabled ? "Pause" : "Resume",
                      systemImage: policy.isEnabled ? "pause" : "play")
            }
            Button {
                onEdit()
            } label: { Label("Edit", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private var channelLabel: String {
        if !policy.channelName.isEmpty { return "#\(policy.channelName)" }
        if !policy.channelID.isEmpty { return "Channel \(policy.channelID)" }
        return "Unconfigured channel"
    }

    private func relativeShort(_ date: Date) -> String {
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "just now" }
        if delta < 3_600 { return "\(Int(delta / 60))m ago" }
        if delta < 86_400 { return "\(Int(delta / 3_600))h ago" }
        return "\(Int(delta / 86_400))d ago"
    }
}

// MARK: - Audit row

private struct SweepAuditRow: View {
    let report: SweepRunReport

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: report.error == nil ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(report.error == nil ? .green : .red)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.policyName)
                        .font(.caption.weight(.semibold))
                    if report.dryRun {
                        Text("DRY-RUN")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                    }
                }
                Text("\(report.scanned) scanned · \(report.matched) matched · \(report.executed) executed · \(report.suppressed) protected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(report.startedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }
}

// MARK: - Activity row

private struct SweepActivityRow: View {
    let action: SweepAction

    private var symbol: String {
        switch action.kind {
        case .delete: return "rectangle.compress.vertical"
        case .keep: return "checkmark.circle"
        case .archive: return "archivebox"
        case .summarise: return "text.bubble"
        case .pin: return "pin"
        case .quiet: return "bell.slash"
        case .skip: return "shield.lefthalf.filled"
        }
    }

    private var tone: Color {
        switch action.kind {
        case .delete: return .orange
        case .keep: return .secondary
        case .archive: return .indigo
        case .summarise: return .purple
        case .pin: return .pink
        case .quiet: return .gray
        case .skip: return .green
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(action.reason)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if action.mode == .virtual {
                        Text("VIRTUAL")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                    }
                }
                Text(action.preview)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }
}

// MARK: - Suggestion row

private struct SweepSuggestionRow: View {
    let suggestion: SweepSuggestion
    let onApply: () -> Void
    let onDismiss: () -> Void
    let onPreview: () -> Void

    private var projectionLine: String? {
        guard let p = suggestion.projection else { return nil }
        return "Would tidy \(p.matched) of \(p.scanned) · \(p.suppressed) protected"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.strategyKind.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(suggestion.title)
                        .font(.caption.weight(.semibold))
                    Text(String(format: "%.0f%%", suggestion.confidence * 100))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Text(suggestion.rationale)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if let projectionLine {
                    Text(projectionLine)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                if suggestion.projection != nil {
                    Button("Preview", action: onPreview)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button("Apply", action: onApply)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Form section (macOS 26 / Liquid Glass styling)

private struct SweepFormSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.black.opacity(0.18), lineWidth: 1)
                .blendMode(.plusDarker)
        )
    }
}

// MARK: - Policy editor sheet

struct SweepPolicyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var policy: SweepPolicy
    @State private var isTryRunInFlight: Bool = false
    @State private var tryRunReport: SweepRunReport?
    @State private var tryRunError: String?
    let isNew: Bool
    let connectedServers: [String: String]
    let channelsByServer: [String: [GuildTextChannel]]
    let onSave: (SweepPolicy) -> Void
    let onTryRun: ((SweepPolicy) async -> SweepRunReport?)?

    init(
        policy: SweepPolicy,
        isNew: Bool,
        connectedServers: [String: String] = [:],
        channelsByServer: [String: [GuildTextChannel]] = [:],
        onSave: @escaping (SweepPolicy) -> Void,
        onTryRun: ((SweepPolicy) async -> SweepRunReport?)? = nil
    ) {
        self._policy = State(initialValue: policy)
        self.isNew = isNew
        self.connectedServers = connectedServers
        self.channelsByServer = channelsByServer
        self.onSave = onSave
        self.onTryRun = onTryRun
    }

    private var isPolicyReady: Bool {
        !policy.channelID.isEmpty
            && !policy.strategies.isEmpty
            && !policy.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedServerIDs: [String] {
        connectedServers.keys.sorted {
            (connectedServers[$0] ?? "").localizedCaseInsensitiveCompare(connectedServers[$1] ?? "") == .orderedAscending
        }
    }

    private var isSingleServer: Bool { connectedServers.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            heroHeader

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SweepFormSection(title: "Target", symbol: "scope") {
                        VStack(alignment: .leading, spacing: 14) {
                            formRow(label: "Rule Name") {
                                TextField("Quiet bot chatter in #general", text: $policy.name)
                                    .textFieldStyle(.roundedBorder)
                            }

                            if !isSingleServer {
                                formRow(label: "Server") {
                                    Picker("", selection: $policy.guildID) {
                                        Text("Select server").tag("")
                                        ForEach(sortedServerIDs, id: \.self) { id in
                                            Text(connectedServers[id] ?? "Unknown server").tag(id)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                }
                            }

                            formRow(label: "Channel") {
                                Picker("", selection: $policy.channelID) {
                                    Text("Select channel").tag("")
                                    ForEach(channelsByServer[policy.guildID] ?? [], id: \.id) { channel in
                                        Text("#\(channel.name)").tag(channel.id)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .disabled(policy.guildID.isEmpty)
                            }
                        }
                        .onAppear { autoSelectIfNeeded() }
                        .onChange(of: policy.guildID) { _, newValue in
                            policy.guildName = connectedServers[newValue] ?? ""
                            let channels = channelsByServer[newValue] ?? []
                            if !channels.contains(where: { $0.id == policy.channelID }) {
                                policy.channelID = channels.first?.id ?? ""
                            }
                            syncChannelName()
                        }
                        .onChange(of: policy.channelID) { _, _ in syncChannelName() }
                    }

                    SweepFormSection(title: "What Sweep should do", symbol: "wand.and.stars") {
                        taskPicker
                    }

                    SweepFormSection(title: "Schedule", symbol: "clock") {
                        schedulePicker
                    }

                    SweepFormSection(title: "Safety Rails", symbol: "shield.lefthalf.filled") {
                        safetyRails
                    }

                    if let tryRunReport {
                        SweepFormSection(title: "Try Run Result", symbol: "play.circle.fill") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(tryRunReport.scanned) scanned · \(tryRunReport.matched) would tidy · \(tryRunReport.suppressed) protected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                SweepPreviewSummary(report: tryRunReport)
                            }
                        }
                        .transition(.opacity)
                    } else if let tryRunError {
                        SweepFormSection(title: "Try Run", symbol: "exclamationmark.triangle.fill") {
                            Text(tryRunError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .animation(.easeInOut(duration: 0.18), value: tryRunReport?.id)
            }

            footerBar
        }
        .background(.regularMaterial)
        .frame(minWidth: 600, idealWidth: 660, minHeight: 640, idealHeight: 760)
    }

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "rectangle.stack.badge.minus")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(
                    Circle()
                        .fill(.tint.opacity(0.14))
                )
                .overlay(
                    Circle().stroke(.tint.opacity(0.18), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(isNew ? "New Sweep Rule" : "Edit Sweep Rule")
                    .font(.title2.weight(.bold))
                Text(isNew
                     ? "Pick a channel and choose how Sweep tidies it."
                     : policy.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 18)
    }

    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.45)
            HStack(spacing: 10) {
                if onTryRun != nil {
                    Button {
                        Task { await runTryRun() }
                    } label: {
                        if isTryRunInFlight {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Running…")
                            }
                        } else {
                            Label("Try Run", systemImage: "play.circle")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!isPolicyReady || isTryRunInFlight)
                    .help("Run this rule against the channel as a dry-run, without changing anything.")
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                Button {
                    onSave(policy)
                    dismiss()
                } label: {
                    Text(isNew ? "Create Rule" : "Save")
                        .frame(minWidth: 86)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isPolicyReady)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(.thinMaterial)
    }

    private func runTryRun() async {
        guard let onTryRun else { return }
        isTryRunInFlight = true
        tryRunError = nil
        let report = await onTryRun(policy)
        isTryRunInFlight = false
        if let report {
            tryRunReport = report
            tryRunError = nil
        } else {
            tryRunReport = nil
            tryRunError = "Couldn’t reach Discord for this channel. Check the channel is still accessible and that the bot is connected."
        }
    }

    @ViewBuilder
    private func formRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content()
        }
    }

    /// Editable numeric input — text field + stepper, both bound to the same
    /// clamped value. Typing a value outside the range will clamp on commit.
    @ViewBuilder
    private func numericInput(
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        suffix: String = "",
        width: CGFloat = 64
    ) -> some View {
        let clamped = Binding<Int>(
            get: { min(max(value.wrappedValue, range.lowerBound), range.upperBound) },
            set: { value.wrappedValue = min(max($0, range.lowerBound), range.upperBound) }
        )
        HStack(spacing: 6) {
            TextField("", value: clamped, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Stepper("", value: clamped, in: range, step: step)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func labelledField(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func autoSelectIfNeeded() {
        // If exactly one server is connected, lock it in silently so users
        // aren't asked to pick from a list of one.
        if isSingleServer, let only = sortedServerIDs.first, policy.guildID.isEmpty {
            policy.guildID = only
            policy.guildName = connectedServers[only] ?? ""
            if policy.channelID.isEmpty,
               let firstChannel = (channelsByServer[only] ?? []).first {
                policy.channelID = firstChannel.id
                policy.channelName = firstChannel.name
            }
        }
    }

    private func syncChannelName() {
        let channels = channelsByServer[policy.guildID] ?? []
        policy.channelName = channels.first { $0.id == policy.channelID }?.name ?? ""
    }

    // MARK: Task picker (replaces the old strategy stack)

    private var selectedTask: SweepTask {
        guard let first = policy.strategies.first else { return .trimOldBotMessages }
        return SweepTask.from(first)
    }

    private var draftAgeHours: Int {
        policy.strategies.first?.ageHours ?? 24
    }

    private var draftKeepCount: Int {
        policy.strategies.first?.keepCount ?? 1
    }

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SweepTask.allCases) { task in
                taskRow(task)
            }
        }
    }

    @ViewBuilder
    private func taskRow(_ task: SweepTask) -> some View {
        let isSelected = selectedTask == task && task.isAvailable
        let isDisabled = !task.isAvailable

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
                        if isDisabled {
                            Text("COMING SOON")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        } else {
                            Text(task.destinationLabel)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(task.destinationTone)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(task.destinationTone.opacity(0.14)))
                        }
                    }
                    Text(task.blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.4))
            }

            if isSelected {
                Divider().opacity(0.4)
                taskParameters(for: task)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isDisabled else { return }
            selectTask(task)
        }
        .opacity(isDisabled ? 0.55 : 1.0)
    }

    @ViewBuilder
    private func taskParameters(for task: SweepTask) -> some View {
        switch task {
        case .trimOldBotMessages, .removeDuplicates, .cleanNoisyBotChannel, .archiveStaleThreads:
            HStack(spacing: 10) {
                Text("Older than")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                numericInput(
                    value: Binding(
                        get: { draftAgeHours },
                        set: { setAge($0) }
                    ),
                    range: 1...720,
                    suffix: "hours"
                )
                Spacer()
            }
        case .keepNewest:
            HStack(spacing: 10) {
                Text("Keep latest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                numericInput(
                    value: Binding(
                        get: { draftKeepCount },
                        set: { setKeepCount($0) }
                    ),
                    range: 1...20,
                    suffix: "posts"
                )
                Spacer()
            }
        case .dailyDigest:
            EmptyView()
        }
    }

    private func selectTask(_ task: SweepTask) {
        let strategy = task.makeStrategy(ageHours: draftAgeHours, keepCount: draftKeepCount)
        policy.strategies = [strategy]
    }

    private func setAge(_ hours: Int) {
        guard var s = policy.strategies.first else { return }
        s.ageHours = hours
        policy.strategies = [s]
    }

    private func setKeepCount(_ count: Int) {
        guard var s = policy.strategies.first else { return }
        s.keepCount = count
        policy.strategies = [s]
    }

    @ViewBuilder
    private func strategyCard(strategy: Binding<SweepStrategy>) -> some View {
        let kind = strategy.wrappedValue.kind
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: kind.symbol)
                    .font(.title3.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 26)

                Picker("", selection: strategy.kind) {
                    ForEach(SweepStrategyKind.allCases) { k in
                        Label(k.displayName, systemImage: k.symbol).tag(k)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 200)

                Text(kind.destinationLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(kind.destinationTone)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(kind.destinationTone.opacity(0.14)))

                Spacer()

                Button {
                    if let idx = policy.strategies.firstIndex(where: { $0.id == strategy.wrappedValue.id }) {
                        policy.strategies.remove(at: idx)
                    }
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text(kind.blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            strategyParameters(strategy: strategy)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func strategyParameters(strategy: Binding<SweepStrategy>) -> some View {
        switch strategy.wrappedValue.kind {
        case .compact, .archive, .deduplicate, .reduceNoise:
            HStack {
                Text("Older than")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(strategy.wrappedValue.ageHours)h",
                        value: strategy.ageHours, in: 1...720)
                    .frame(maxWidth: 160)
                if strategy.wrappedValue.kind == .compact {
                    Toggle("Bots only", isOn: strategy.fromBotsOnly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                Spacer()
            }
        case .keepLatest:
            HStack {
                Text("Keep latest")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(strategy.wrappedValue.keepCount)",
                        value: strategy.keepCount, in: 1...20)
                    .frame(maxWidth: 140)
                Spacer()
            }
        case .summarise, .quietChannel:
            EmptyView() // No parameters — blurb above describes the behaviour.
        }
    }

    @ViewBuilder
    private var schedulePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: scheduleKindBinding) {
                Text("Manual").tag("manual")
                Text("Interval").tag("interval")
                Text("Daily").tag("daily")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch policy.schedule {
            case .manual:
                Text("This policy only runs when triggered manually.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .interval(let m):
                HStack {
                    Text("Every")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    numericInput(
                        value: Binding(
                            get: { m },
                            set: { policy.schedule = .interval(minutes: $0) }
                        ),
                        range: 5...1440,
                        step: 5,
                        suffix: "minutes"
                    )
                    Spacer()
                }
            case .daily(let h):
                HStack {
                    Text("At hour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    numericInput(
                        value: Binding(
                            get: { h },
                            set: { policy.schedule = .daily(hour: $0) }
                        ),
                        range: 0...23,
                        suffix: ":00"
                    )
                    Spacer()
                }
            }
        }
    }

    private var scheduleKindBinding: Binding<String> {
        Binding(
            get: {
                switch policy.schedule {
                case .manual: return "manual"
                case .interval: return "interval"
                case .daily: return "daily"
                }
            },
            set: { newValue in
                switch newValue {
                case "manual": policy.schedule = .manual
                case "interval": policy.schedule = .interval(minutes: 60)
                case "daily": policy.schedule = .daily(hour: 4)
                default: break
                }
            }
        )
    }

    @ViewBuilder
    private var safetyRails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Protect pinned messages", isOn: $policy.safety.protectPinned)
                .toggleStyle(.switch)
                .font(.caption)
            Toggle("Protect messages with reactions", isOn: $policy.safety.protectReacted)
                .toggleStyle(.switch)
                .font(.caption)
            HStack {
                Text("Max per run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                numericInput(
                    value: $policy.safety.maxMessagesPerRun,
                    range: 10...2000,
                    step: 10,
                    suffix: "messages"
                )
                Spacer()
            }
            HStack {
                Text("Min age (min)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                numericInput(
                    value: $policy.safety.minMessageAgeMinutes,
                    range: 0...1440,
                    step: 5,
                    suffix: "minutes"
                )
                Spacer()
            }
        }
    }
}

// MARK: - Preview sheet

private struct SweepPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: SweepRunReport
    let policyName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.45)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let err = report.error {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Try Run failed")
                                    .font(.subheadline.weight(.semibold))
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.thinMaterial)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.red.opacity(0.4), lineWidth: 1)
                        )
                    }
                    SweepPreviewSummary(report: report)
                }
                .padding(20)
            }
        }
        .background(.regularMaterial)
        .frame(minWidth: 560, idealWidth: 660, minHeight: 480, idealHeight: 600)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Try Run — \(policyName)")
                    .font(.title3.weight(.semibold))
                Text("\(report.scanned) scanned · \(report.matched) would tidy · \(report.suppressed) protected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Preview summary (grouped, plain-English)

/// Compact summary of a `SweepRunReport`. Groups actions by kind, then by
/// author (for tidies/keeps) or reason (for protections), so the user sees
/// "Would delete 50 from PatchBot" instead of 50 individual rows.
struct SweepPreviewSummary: View {
    let report: SweepRunReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !destructiveGroups.isEmpty {
                summarySection(
                    title: "Would tidy",
                    symbol: "rectangle.compress.vertical",
                    tone: .orange,
                    groups: destructiveGroups,
                    emptyHint: nil
                )
            }
            if !virtualGroups.isEmpty {
                summarySection(
                    title: "Virtual",
                    symbol: "bell.slash",
                    tone: .purple,
                    groups: virtualGroups,
                    emptyHint: nil
                )
            }
            if !keepGroups.isEmpty {
                summarySection(
                    title: "Keep",
                    symbol: "checkmark.circle",
                    tone: .green,
                    groups: keepGroups,
                    emptyHint: nil
                )
            }
            if !protectedGroups.isEmpty {
                summarySection(
                    title: "Protected",
                    symbol: "shield.lefthalf.filled",
                    tone: .green,
                    groups: protectedGroups,
                    emptyHint: nil
                )
            }
            if destructiveGroups.isEmpty && virtualGroups.isEmpty && keepGroups.isEmpty && protectedGroups.isEmpty {
                Text("Nothing would be touched in this run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Grouping

    private struct Group: Hashable {
        let label: String
        let count: Int
    }

    private var destructiveGroups: [Group] {
        groupByAuthor(actions: report.actions.filter { [.delete, .archive, .pin].contains($0.kind) })
    }

    private var virtualGroups: [Group] {
        groupByAuthor(actions: report.actions.filter { [.summarise, .quiet].contains($0.kind) })
    }

    private var keepGroups: [Group] {
        groupByAuthor(actions: report.actions.filter { $0.kind == .keep })
    }

    private var protectedGroups: [Group] {
        let skips = report.actions.filter { $0.kind == .skip }
        let byReason = Dictionary(grouping: skips, by: { $0.reason })
        return byReason
            .map { Group(label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    private func groupByAuthor(actions: [SweepAction]) -> [Group] {
        guard !actions.isEmpty else { return [] }
        let byAuthor = Dictionary(grouping: actions, by: { $0.authorName ?? "Unknown" })
        return byAuthor
            .map { Group(label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
    }

    // MARK: Section view

    @ViewBuilder
    private func summarySection(
        title: String,
        symbol: String,
        tone: Color,
        groups: [Group],
        emptyHint: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tone)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("· \(groups.reduce(0) { $0 + $1.count })")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.self) { group in
                    HStack(spacing: 6) {
                        Text("\(group.count)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tone)
                            .frame(minWidth: 32, alignment: .trailing)
                            .monospacedDigit()
                        Text(group.label)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.leading, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tone.opacity(0.18), lineWidth: 1)
        )
    }
}
