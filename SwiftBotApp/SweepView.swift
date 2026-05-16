import Foundation
import SwiftUI

// MARK: - Sweep Models
//
// Sweep is SwiftBot's channel lifecycle / retention subsystem. The first cut
// ships the full model surface, an actor-backed service with JSON persistence
// and a scheduler tick, and a SwiftMesh-styled dashboard. Discord side-effects
// are routed through `SweepDispatcher` — by default the dispatcher is a
// dry-run shim so the UI is fully exercisable without touching real channels.

enum SweepStrategyKind: String, Codable, CaseIterable, Identifiable {
    case delete
    case keepLatest
    case deduplicate
    case compactVoiceSessions
    case summarise
    case archive
    case pinSummary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .delete: return "Delete"
        case .keepLatest: return "Keep Latest"
        case .deduplicate: return "Deduplicate"
        case .compactVoiceSessions: return "Compact Voice"
        case .summarise: return "Summarise"
        case .archive: return "Archive"
        case .pinSummary: return "Pin Summary"
        }
    }

    var symbol: String {
        switch self {
        case .delete: return "trash"
        case .keepLatest: return "1.circle"
        case .deduplicate: return "square.on.square.dashed"
        case .compactVoiceSessions: return "waveform"
        case .summarise: return "text.bubble"
        case .archive: return "archivebox"
        case .pinSummary: return "pin"
        }
    }
}

/// A configured strategy on a policy. Strategies are composed in order — for
/// example, `summarise` followed by `delete` preserves a digest before pruning.
struct SweepStrategy: Codable, Hashable, Identifiable {
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

struct SweepSafetyRails: Codable, Hashable {
    var maxMessagesPerRun: Int = 200
    var dryRunOnly: Bool = true
    var minMessageAgeMinutes: Int = 5
    var protectPinned: Bool = true
    var protectReacted: Bool = true
}

struct SweepPolicy: Codable, Identifiable, Hashable {
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
}

enum SweepActionKind: String, Codable {
    case delete
    case keep
    case archive
    case summarise
    case pin
    case skip
}

struct SweepAction: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let kind: SweepActionKind
    let messageID: String
    let preview: String
    let reason: String
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

    private let store = SweepStore()
    private var dispatcher: SweepDispatcher = PreviewSweepDispatcher()
    private var tickTask: Task<Void, Never>?

    init() {
        Task { await self.hydrate() }
    }

    func setDispatcher(_ dispatcher: SweepDispatcher) {
        self.dispatcher = dispatcher
    }

    private func hydrate() async {
        let snapshot = await store.load()
        self.policies = snapshot.policies
        self.recentReports = snapshot.recentReports
        self.globalPaused = snapshot.globalPaused
        recomputeNextRuns()
        startTickLoop()
    }

    private func persist() async {
        let snapshot = SweepSnapshot(
            schemaVersion: 1,
            policies: policies,
            globalPaused: globalPaused,
            recentReports: recentReports
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
                error: nil
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

    func preview(policyID: UUID) async -> SweepRunReport? {
        guard let policy = policies.first(where: { $0.id == policyID }) else { return nil }
        let start = Date()
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
                policyName: policy.name,
                startedAt: start,
                durationMS: Int(Date().timeIntervalSince(start) * 1000),
                scanned: messages.count,
                matched: matched,
                executed: 0,
                suppressed: suppressed,
                dryRun: true,
                actions: plan,
                error: nil
            )
        } catch {
            return nil
        }
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
        Task { await persist() }
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
                actions.append(SweepAction(
                    kind: .skip, messageID: message.id,
                    preview: message.content,
                    reason: "Pinned — protected"))
                continue
            }
            if policy.safety.protectReacted && message.hasReactions {
                actions.append(SweepAction(
                    kind: .skip, messageID: message.id,
                    preview: message.content,
                    reason: "Has reactions — protected"))
                continue
            }
            if now.timeIntervalSince(message.createdAt) < minAge {
                actions.append(SweepAction(
                    kind: .skip, messageID: message.id,
                    preview: message.content,
                    reason: "Younger than minimum age"))
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
            actions.append(SweepAction(
                kind: .keep, messageID: message.id,
                preview: message.content,
                reason: "No matching strategy"))
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
                        kind: .skip, messageID: action.messageID,
                        preview: action.preview,
                        reason: "Exceeds per-run cap"))
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
        case .delete:
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                let matchesBots = !strategy.fromBotsOnly || message.isBot
                if matchesBots && now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(SweepAction(
                        kind: .delete, messageID: message.id,
                        preview: message.content,
                        reason: "Older than \(strategy.ageHours)h"))
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
            var consumed: [SweepAction] = kept.map { msg in
                SweepAction(kind: .keep, messageID: msg.id,
                            preview: msg.content,
                            reason: "Latest \(keepCount) preserved")
            }
            consumed.append(contentsOf: dropped.map { msg in
                SweepAction(kind: .delete, messageID: msg.id,
                            preview: msg.content,
                            reason: "Superseded by newer post")
            })
            return (consumed, [])

        case .deduplicate:
            var seen: [String: SweepFetchedMessage] = [:]
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages.sorted(by: { $0.createdAt > $1.createdAt }) {
                let key = message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let _ = seen[key] {
                    consumed.append(SweepAction(
                        kind: .delete, messageID: message.id,
                        preview: message.content,
                        reason: "Duplicate of newer message"))
                } else {
                    seen[key] = message
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .compactVoiceSessions:
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                if message.isBot && now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(SweepAction(
                        kind: .summarise, messageID: message.id,
                        preview: message.content,
                        reason: "Voice activity → session digest"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .summarise:
            let consumed = messages.map { msg in
                SweepAction(kind: .summarise, messageID: msg.id,
                            preview: msg.content,
                            reason: "Captured in summary")
            }
            return (consumed, [])

        case .archive:
            var consumed: [SweepAction] = []
            var remaining: [SweepFetchedMessage] = []
            for message in messages {
                if now.timeIntervalSince(message.createdAt) >= age {
                    consumed.append(SweepAction(
                        kind: .archive, messageID: message.id,
                        preview: message.content,
                        reason: "Archived after \(strategy.ageHours)h"))
                } else {
                    remaining.append(message)
                }
            }
            return (consumed, remaining)

        case .pinSummary:
            if let latest = messages.max(by: { $0.createdAt < $1.createdAt }) {
                return ([SweepAction(
                    kind: .pin, messageID: latest.id,
                    preview: latest.content,
                    reason: "Refresh pinned summary")], messages.filter { $0.id != latest.id })
            }
            return ([], messages)
        }
    }
}

// MARK: - View

struct SweepView: View {
    @EnvironmentObject var app: AppModel
    @State private var editingPolicy: SweepPolicy?
    @State private var showingNewPolicySheet = false
    @State private var previewReport: SweepRunReport?
    @State private var previewingPolicyName: String = ""

    private var service: SweepService { app.sweepService }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if service.state == .running {
                    activeRunPanel
                }
                metricTileRow
                SwiftMeshSection(title: "Policies", symbol: "rectangle.stack.badge.minus") {
                    policyListContent
                }
                diagnosticsAndLastRunRow
                SwiftMeshSection(title: "Audit Timeline", symbol: "clock.arrow.circlepath") {
                    auditTimelineContent
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .sheet(isPresented: $showingNewPolicySheet) {
            SweepPolicyEditor(
                policy: SweepPolicy(
                    name: "New Policy",
                    guildID: "",
                    guildName: "",
                    channelID: "",
                    channelName: "",
                    strategies: [SweepStrategy(kind: .keepLatest)],
                    schedule: .interval(minutes: 60),
                    safety: SweepSafetyRails()
                ),
                isNew: true,
                onSave: { service.upsert($0) }
            )
        }
        .sheet(item: $editingPolicy) { policy in
            SweepPolicyEditor(
                policy: policy,
                isNew: false,
                onSave: { service.upsert($0) }
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
            HStack(spacing: 8) {
                Button {
                    service.globalPaused.toggle()
                } label: {
                    Label(service.globalPaused ? "Resume" : "Pause All",
                          systemImage: service.globalPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button {
                    showingNewPolicySheet = true
                } label: {
                    Label("New Policy", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            SweepStateBadge(state: service.state)
        }
    }

    private var headerSubtitle: String {
        if service.globalPaused {
            return "Paused · \(service.policies.count) policies"
        }
        let enabled = service.enabledPolicyCount
        let total = service.policies.count
        return "\(enabled)/\(total) enabled · next \(service.nextRunDescription) · \(service.messagesTodayCount) tidied today"
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
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            DashboardMetricCard(
                title: "Status",
                value: service.state.displayName,
                subtitle: service.globalPaused ? "Paused by operator" : "\(service.enabledPolicyCount) enabled",
                symbol: service.state == .running ? "rectangle.stack.fill.badge.minus" : "rectangle.stack.badge.minus",
                color: service.state.tone
            )
            DashboardMetricCard(
                title: "Policies",
                value: "\(service.enabledPolicyCount)",
                subtitle: "of \(service.policies.count) total",
                symbol: "list.bullet.rectangle",
                color: .accentColor
            )
            DashboardMetricCard(
                title: "Next Run",
                value: service.nextRunDescription,
                subtitle: service.globalPaused ? "Resume to schedule" : "Across all policies",
                symbol: "clock",
                color: .blue
            )
            DashboardMetricCard(
                title: "Last Run",
                value: lastRunValue,
                subtitle: lastRunSubtitle,
                symbol: "checkmark.seal.fill",
                color: lastRunTone
            )
            DashboardMetricCard(
                title: "Tidied Today",
                value: "\(service.messagesTodayCount)",
                subtitle: "Across \(service.recentReports.count) runs",
                symbol: "tray.full",
                color: .indigo
            )
            DashboardMetricCard(
                title: "Suppressed",
                value: "\(service.suppressedTodayCount)",
                subtitle: "Saved by safety rails",
                symbol: "shield.lefthalf.filled",
                color: .green
            )
            DashboardMetricCard(
                title: "Summaries",
                value: "\(service.summariesThisWeekCount)",
                subtitle: "Past 7 days",
                symbol: "text.bubble",
                color: .purple
            )
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
            PlaceholderPanelLine(text: "No Sweep policies yet. Tap “New Policy” to create one.")
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
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
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

// MARK: - Policy editor sheet

struct SweepPolicyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var policy: SweepPolicy
    let isNew: Bool
    let onSave: (SweepPolicy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New Sweep Policy" : "Edit Sweep Policy")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }
                Button(isNew ? "Create" : "Save") {
                    onSave(policy)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SwiftMeshSection(title: "Target", symbol: "number") {
                        VStack(alignment: .leading, spacing: 8) {
                            labelledField("Policy Name", text: $policy.name)
                            labelledField("Channel Name", text: $policy.channelName, placeholder: "general")
                            labelledField("Channel ID", text: $policy.channelID, placeholder: "Discord snowflake")
                            labelledField("Guild Name", text: $policy.guildName, placeholder: "My Server")
                            labelledField("Guild ID", text: $policy.guildID, placeholder: "Discord snowflake")
                        }
                    }

                    SwiftMeshSection(title: "Strategies", symbol: "list.bullet.rectangle") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach($policy.strategies) { $strategy in
                                strategyCard(strategy: $strategy)
                            }
                            Button {
                                policy.strategies.append(SweepStrategy(kind: .delete))
                            } label: {
                                Label("Add Strategy", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    SwiftMeshSection(title: "Schedule", symbol: "clock") {
                        schedulePicker
                    }

                    SwiftMeshSection(title: "Safety Rails", symbol: "shield.lefthalf.filled") {
                        safetyRails
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 600, idealHeight: 720)
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

    @ViewBuilder
    private func strategyCard(strategy: Binding<SweepStrategy>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: strategy.wrappedValue.kind.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Picker("", selection: strategy.kind) {
                    ForEach(SweepStrategyKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 180)

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

            strategyParameters(strategy: strategy)
        }
        .padding(10)
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
        case .delete, .archive, .compactVoiceSessions, .pinSummary, .deduplicate:
            HStack {
                Text("Older than")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("\(strategy.wrappedValue.ageHours)h",
                        value: strategy.ageHours, in: 1...720)
                    .frame(maxWidth: 160)
                if strategy.wrappedValue.kind == .delete {
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
        case .summarise:
            Text("Generates a digest from matching messages. Routed to the policy's channel.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Stepper("\(m) min",
                            value: Binding(
                                get: { m },
                                set: { policy.schedule = .interval(minutes: $0) }
                            ),
                            in: 5...1440, step: 5)
                        .frame(maxWidth: 180)
                    Spacer()
                }
            case .daily(let h):
                HStack {
                    Text("At hour")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Stepper("\(h):00",
                            value: Binding(
                                get: { h },
                                set: { policy.schedule = .daily(hour: $0) }
                            ),
                            in: 0...23)
                        .frame(maxWidth: 160)
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
            Toggle("Dry-run only (never execute, just preview)", isOn: $policy.safety.dryRunOnly)
                .toggleStyle(.switch)
                .font(.caption)
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
                Stepper("\(policy.safety.maxMessagesPerRun)",
                        value: $policy.safety.maxMessagesPerRun,
                        in: 10...2000, step: 10)
                    .frame(maxWidth: 160)
                Spacer()
            }
            HStack {
                Text("Min age (min)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 110, alignment: .leading)
                Stepper("\(policy.safety.minMessageAgeMinutes)",
                        value: $policy.safety.minMessageAgeMinutes,
                        in: 0...1440, step: 5)
                    .frame(maxWidth: 160)
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
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preview — \(policyName)")
                        .font(.title3.weight(.semibold))
                    Text("\(report.scanned) scanned · \(report.matched) would execute · \(report.suppressed) protected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(report.actions) { action in
                        previewRow(action: action)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 560)
    }

    @ViewBuilder
    private func previewRow(action: SweepAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: action.kind))
                .foregroundStyle(tone(for: action.kind))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.preview)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(action.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(action.kind.rawValue.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(tone(for: action.kind))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(tone(for: action.kind).opacity(0.12)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }

    private func symbol(for kind: SweepActionKind) -> String {
        switch kind {
        case .delete: return "trash"
        case .keep: return "checkmark.circle"
        case .archive: return "archivebox"
        case .summarise: return "text.bubble"
        case .pin: return "pin"
        case .skip: return "shield.lefthalf.filled"
        }
    }

    private func tone(for kind: SweepActionKind) -> Color {
        switch kind {
        case .delete: return .red
        case .keep: return .secondary
        case .archive: return .orange
        case .summarise: return .purple
        case .pin: return .blue
        case .skip: return .green
        }
    }
}
