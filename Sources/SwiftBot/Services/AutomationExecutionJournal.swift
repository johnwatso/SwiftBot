import Foundation

/// A checkpoint records intent before an external effect and progress after it.
/// An unacknowledged effect is held for review rather than repeated after a crash.
struct AutomationExecutionCheckpoint: Codable, Sendable {
    let id: String
    let rule: Automations.Rule
    let event: SwiftBotEvent
    var nextStep = 0
    var wakeAt: Date?
    var inFlightStep: Int?
    var completed = false
    var needsReview = false
    var eventHandled = false
    var aiOutput: String?
    var errors: [String] = []
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else { records = [:]; return }
        do {
            let values = try JSONDecoder().decode([AutomationExecutionCheckpoint].self, from: Data(contentsOf: fileURL))
            records = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
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
        if let fileURL {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(copy.values).sorted { $0.id < $1.id }).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        records = copy
    }
}
