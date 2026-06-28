import Foundation

/// Persists the set of dismissed finding fingerprints, keyed by guild. Dismissal
/// filtering runs at the end of the analysis pipeline so detectors stay pure —
/// see AppModel+Audit. Follows the on-disk JSON actor pattern from Persistence.
actor AuditDismissalStore {
    private struct Payload: Codable {
        /// guildID → set of ignored finding fingerprints.
        var ignored: [String: Set<String>] = [:]
    }

    private let url: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var payload: Payload

    init(filename: String = "audit-dismissals.json") {
        let folder = SwiftBotStorage.folderURL()
        self.url = folder.appendingPathComponent(filename)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        if let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(Payload.self, from: data) {
            self.payload = decoded
        } else {
            self.payload = Payload()
        }
    }

    func ignoredFingerprints(guildID: String) -> Set<String> {
        payload.ignored[guildID] ?? []
    }

    func ignore(fingerprint: String, guildID: String) {
        payload.ignored[guildID, default: []].insert(fingerprint)
        persist()
    }

    func unignore(fingerprint: String, guildID: String) {
        payload.ignored[guildID]?.remove(fingerprint)
        persist()
    }

    private func persist() {
        guard let data = try? encoder.encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
