import Foundation
import SwiftUI

/// Focused view model for the Audit feature. Owns the analyzer + dismissal
/// store, runs the scan pipeline, and publishes feed state. Deliberately scoped
/// to Audit rather than bolted onto AppModel, mirroring the per-feature file
/// convention (e.g. PatchyViewModel).
@MainActor
final class AuditViewModel: ObservableObject {
    enum ScanState: Equatable {
        case idle
        case scanning
        case completed(Date)
        case failed(String)
    }

    @Published var scanState: ScanState = .idle
    @Published var selectedServerID: String?
    @Published var selectedFindingID: Finding.ID?
    @Published var showIgnored = false

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var rolesByID: [String: AuditRole] = [:]
    @Published private(set) var ignoredFingerprints: Set<String> = []
    @Published private(set) var recentChangeCount = 0

    private let analyzer = AuditAnalyzer()
    private let store = AuditDismissalStore()

    // MARK: - Derived state

    /// Findings minus dismissed ones (unless the user is reviewing ignored).
    var visibleFindings: [Finding] {
        showIgnored ? findings : findings.filter { !ignoredFingerprints.contains($0.id) }
    }

    var ignoredCount: Int {
        findings.filter { ignoredFingerprints.contains($0.id) }.count
    }

    var groupedByCategory: [(category: FindingCategory, findings: [Finding])] {
        let grouped = Dictionary(grouping: visibleFindings, by: \.category)
        return FindingCategory.allCases.compactMap { category in
            guard let items = grouped[category], !items.isEmpty else { return nil }
            return (category, items)
        }
    }

    func isIgnored(_ finding: Finding) -> Bool {
        ignoredFingerprints.contains(finding.id)
    }

    func role(_ id: String) -> AuditRole? { rolesByID[id] }

    var selectedFinding: Finding? {
        guard let id = selectedFindingID else { return nil }
        return findings.first { $0.id == id }
    }

    // MARK: - Summary metrics

    var riskCount: Int { visibleFindings.filter { $0.severity >= .warning }.count }
    var duplicateCount: Int { visibleFindings.filter { $0.category == .duplicateRoles }.count }
    var unusedCount: Int { visibleFindings.filter { $0.category == .unusedRole }.count }
    var elevatedCount: Int { visibleFindings.filter { $0.category == .permissionRisk }.count }

    // MARK: - Scan

    func scan(token: String, session: URLSession, guildID: String, guildName: String) async {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty, !guildID.isEmpty else {
            scanState = .failed("Connect the bot and select a server first.")
            return
        }

        scanState = .scanning
        let builder = AuditSnapshotBuilder(session: session)

        do {
            let snapshot = try await builder.build(guildID: guildID, guildName: guildName, token: trimmedToken)
            let results = await analyzer.analyze(snapshot)
            let ignored = await store.ignoredFingerprints(guildID: guildID)

            findings = results
            rolesByID = Dictionary(uniqueKeysWithValues: snapshot.roles.map { ($0.id, $0) })
            ignoredFingerprints = ignored
            recentChangeCount = snapshot.recentEvents.count
            scanState = .completed(snapshot.capturedAt)

            if let selectedFindingID, !results.contains(where: { $0.id == selectedFindingID }) {
                self.selectedFindingID = nil
            }
        } catch {
            scanState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Dismissal

    func ignore(_ finding: Finding, guildID: String) {
        ignoredFingerprints.insert(finding.id)
        if selectedFindingID == finding.id { selectedFindingID = nil }
        Task { await store.ignore(fingerprint: finding.id, guildID: guildID) }
    }

    func unignore(_ finding: Finding, guildID: String) {
        ignoredFingerprints.remove(finding.id)
        Task { await store.unignore(fingerprint: finding.id, guildID: guildID) }
    }
}
