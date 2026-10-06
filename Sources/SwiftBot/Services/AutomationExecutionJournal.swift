import Foundation

/// A checkpoint records intent before an external effect and progress after it.
/// An unacknowledged effect is held for review rather than repeated after a crash.
struct AutomationExecutionCheckpoint: Codable, Sendable {
    let id: String
    var rule: Automations.Rule
    let event: SwiftBotEvent
    var nextStep = 0
    var wakeAt: Date?
    var inFlightStep: Int?
    var completed = false
    var needsReview = false
    var eventHandled = false
    var aiOutput: String?
    var errors: [String] = []
    var admitted: Bool?
    var branchStack: [AutomationBranchFrame]?
    var traces: [Automations.StepTrace]?
    var updatedAt = Date()
}

/// Owned exclusively by AutomationService, including synchronous persistence
/// before each effect. No bot tokens, sessions, or tunnel secrets are recorded.
struct AutomationExecutionJournal {
    static let fileName = "automation-executions.json"
    let fileURL: URL?
    private(set) var records: [String: AutomationExecutionCheckpoint] = [:]

    init(fileURL: URL?) {
        self.fileURL = fileURL
        reload()
    }

    mutating func reload() {
        guard let fileURL else { return }
        isReadable = true
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = [:]
            return
        }
        do {
            let values = try JSONDecoder().decode([AutomationExecutionCheckpoint].self, from: Data(contentsOf: fileURL))
            records = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            // Journals written before webhook URLs moved to the Keychain.
            if values.contains(where: \.hasInlineWebhookURL) {
                for (id, record) in records where record.hasInlineWebhookURL {
                    records[id]?.rule = AutomationWebhookVault.seal(record.rule)
                }
                // A failed rewrite leaves the old file until the next save.
                try? writeRecords(records)
            }
            for id in Array(records.keys) where records[id]?.inFlightStep != nil {
                records[id]?.needsReview = true
            }
        } catch {
            // A damaged journal must never turn a recorded intent into a new
            // execution. Keep a sentinel so the service fails closed.
            records = [:]
            isReadable = false
        }
    }
    private(set) var isReadable = true

    mutating func save(_ checkpoint: AutomationExecutionCheckpoint) throws {
        guard isReadable else { throw CocoaError(.fileReadCorruptFile) }
        var updated = checkpoint
        updated.updatedAt = Date()
        // Callers seal the rule when they create a checkpoint; this keeps a
        // URL off disk if one ever reaches here inline.
        if updated.hasInlineWebhookURL { updated.rule = AutomationWebhookVault.seal(updated.rule) }
        var copy = records
        copy[updated.id] = updated
        let expired = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        copy = copy.filter { !$0.value.completed || $0.value.updatedAt > expired }
        if copy.count > 1000 {
            for record in copy.values.filter({ $0.completed }).sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(copy.count - 1000) {
                copy.removeValue(forKey: record.id)
            }
        }
        guard copy.count <= 1000 else { throw CocoaError(.fileWriteOutOfSpace) }
        try writeRecords(copy)
        records = copy
    }

    private func writeRecords(_ values: [String: AutomationExecutionCheckpoint]) throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(values.values).sorted { $0.id < $1.id }).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

extension AutomationExecutionCheckpoint {
    var hasInlineWebhookURL: Bool {
        rule.steps.contains { !($0.webhookUrl ?? "").isEmpty }
    }
}

struct AutomationBranchFrame: Codable, Sendable {
    var parentActive: Bool
    var conditionMatched: Bool
    var inOtherwise = false
    var active: Bool { parentActive && (inOtherwise ? !conditionMatched : conditionMatched) }
}

struct AutomationMemory: Codable, Sendable {
    static let fileName = "automation-memory.json"
    static func url(for journalURL: URL) -> URL {
        journalURL.lastPathComponent == AutomationExecutionJournal.fileName
            ? journalURL.deletingLastPathComponent().appendingPathComponent(fileName)
            : journalURL.appendingPathExtension("memory.json")
    }
    var counters: [String: [Date]] = [:]
    var cooldowns: [String: Date] = [:]
    var appliedSteps: [String: Date] = [:]
    var scheduleCursors: [String: Date] = [:]
    static func scopeKey(name: String, scope: Automations.MemoryScope, ruleId: String, event: SwiftBotEvent) -> String {
        let subject: String
        switch scope {
        case .user: subject = event.userId
        case .channel: subject = event.channelId
        case .guild: subject = event.guildId
        case .rule: subject = ruleId
        }
        // Encode components rather than concatenating untrusted names with separators.
        return (try? JSONEncoder().encode([event.guildId, name, scope.rawValue, subject]).base64EncodedString()) ?? ""
    }
    func count(name: String, scope: Automations.MemoryScope, ruleId: String, event: SwiftBotEvent, now: Date = Date()) -> Int {
        counters[Self.scopeKey(name: name, scope: scope, ruleId: ruleId, event: event), default: []].filter { $0 > now }.count
    }
    mutating func prune(now: Date = Date()) {
        counters = counters.mapValues { $0.filter { $0 > now } }.filter { !$0.value.isEmpty }
        cooldowns = cooldowns.filter { $0.value > now }
        appliedSteps = appliedSteps.filter { $0.value > now.addingTimeInterval(-7 * 86400) }
    }
}

struct AutomationRunDiagnostic: Codable, Sendable {
    let id: String
    let ruleId: String
    let ruleName: String
    let updatedAt: Date
    let status: String
    let traces: [Automations.StepTrace]
    let errors: [String]
}
