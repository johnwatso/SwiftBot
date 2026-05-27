import Foundation
import Observation
import OSLog

/// Observable rule list backed by a JSON file in Application Support.
///
/// SwiftUI views bind directly to `rules`. The engine reads a snapshot via
/// `snapshot()` when an event fires.
@MainActor
@Observable
final class AutomationStore {

    private(set) var rules: [Automations.Rule] = []
    private(set) var isLoaded: Bool = false

    private let fileURL: URL
    private let logger = Logger(subsystem: "com.swiftbot", category: "automations.store")
    private var saveTask: Task<Void, Never>?

    /// Fires after each successful save. Used by AppModel to mirror changes.
    var onPersisted: (@MainActor () -> Void)?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
    }

    static func defaultFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SwiftBot", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("automations.json")
    }

    // MARK: - Load / Save

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            rules = []
            isLoaded = true
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            rules = try JSONDecoder().decode([Automations.Rule].self, from: data)
            isLoaded = true
            logger.info("Loaded \(self.rules.count) automation(s)")
        } catch {
            logger.error("Failed to load automations: \(error.localizedDescription)")
            rules = []
            isLoaded = true
        }
    }

    /// Debounced save — call after mutations.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() async {
        let snap = rules
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(snap)
            try data.write(to: fileURL, options: .atomic)
            logger.info("Saved \(snap.count) automation(s)")
            onPersisted?()
        } catch {
            logger.error("Failed to save automations: \(error.localizedDescription)")
        }
    }

    // MARK: - Mutations

    func upsert(_ rule: Automations.Rule) {
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = rule
        } else {
            rules.append(rule)
        }
        scheduleSave()
    }

    func remove(id: String) {
        rules.removeAll { $0.id == id }
        scheduleSave()
    }

    func toggleEnabled(id: String) {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[i].enabled.toggle()
        scheduleSave()
    }

    #if DEBUG
    func setRulesForTesting(_ rules: [Automations.Rule]) {
        self.rules = rules
    }
    #endif

    /// Snapshot for the engine to evaluate against off-main.
    nonisolated func snapshot() async -> [Automations.Rule] {
        await MainActor.run { self.rules }
    }
}
