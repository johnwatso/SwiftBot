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

    /// Via `SwiftBotStorage` rather than resolving Application Support again:
    /// a second copy of the path silently opts this store out of the test
    /// redirection there, and back onto the live automations file.
    static func defaultFileURL() -> URL {
        SwiftBotStorage.folderURL().appendingPathComponent("automations.json")
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
            let decoded = try JSONDecoder().decode([Automations.Rule].self, from: data)
            // Files written before webhook URLs moved to the Keychain.
            rules = decoded.map(AutomationWebhookVault.seal)
            isLoaded = true
            if rules != decoded { scheduleSave() }
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

    /// A webhook step with a blank URL keeps the URL already saved for it.
    func upsert(_ rule: Automations.Rule) {
        let before = rules
        let sealed = AutomationWebhookVault.seal(rule)
        if let i = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[i] = sealed
        } else {
            rules.append(sealed)
        }
        AutomationWebhookVault.deleteUnreferenced(previous: before, current: rules)
        scheduleSave()
    }

    func remove(id: String) {
        let before = rules
        rules.removeAll { $0.id == id }
        AutomationWebhookVault.deleteUnreferenced(previous: before, current: rules)
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

/// Webhook URLs usually carry their own authorization token, so they live in
/// the Keychain. Rules in memory, `automations.json`, the execution journal
/// and mesh snapshots hold only `webhookCredentialId`. Each new URL gets a new
/// ID, so a changed URL also changes the rule, and Standbys pull the URLs over
/// `/v1/mesh/credentials`.
enum AutomationWebhookVault {
    private static let accountPrefix = "automation-webhook."

    static func url(for id: String) -> String? {
        guard !id.isEmpty else { return nil }
        return KeychainHelper.load(account: accountPrefix + id)
    }

    @discardableResult
    static func store(_ url: String, id: String) -> Bool {
        KeychainHelper.save(url, account: accountPrefix + id)
    }

    /// Moves any inline webhook URL into the Keychain. A step whose Keychain
    /// write fails keeps its inline URL rather than losing it.
    static func seal(_ rule: Automations.Rule) -> Automations.Rule {
        var sealed = rule
        for index in sealed.steps.indices {
            let url = (sealed.steps[index].webhookUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if url.isEmpty {
                sealed.steps[index].webhookUrl = nil
                continue
            }
            let id = UUID().uuidString
            guard store(url, id: id) else { continue }
            sealed.steps[index].webhookUrl = nil
            sealed.steps[index].webhookCredentialId = id
        }
        return sealed
    }

    static func credentialIds(in rules: [Automations.Rule]) -> Set<String> {
        Set(rules.flatMap(\.steps).compactMap(\.webhookCredentialId).filter { !$0.isEmpty })
    }

    /// Every saved URL the rules reference, keyed by credential ID.
    static func urls(for rules: [Automations.Rule]) -> [String: String] {
        var result: [String: String] = [:]
        for id in credentialIds(in: rules) { result[id] = url(for: id) }
        return result
    }

    static func deleteUnreferenced(previous: [Automations.Rule], current: [Automations.Rule]) {
        for id in credentialIds(in: previous).subtracting(credentialIds(in: current)) {
            KeychainHelper.delete(account: accountPrefix + id)
        }
    }
}
