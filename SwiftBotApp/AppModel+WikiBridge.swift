import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Wiki Bridge

    func addWikiBridgeSourceTarget(_ target: WikiSource) {
        settings.wikiBot.sources.append(target)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func updateWikiBridgeSourceTarget(_ target: WikiSource) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == target.id }) else { return }
        settings.wikiBot.sources[idx] = target
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func deleteWikiBridgeSourceTarget(_ targetID: UUID) {
        settings.wikiBot.sources.removeAll { $0.id == targetID }
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func toggleWikiBridgeSourceTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == targetID }) else { return }
        settings.wikiBot.sources[idx].enabled.toggle()
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func setWikiBridgePrimarySource(_ targetID: UUID) {
        settings.wikiBot.setPrimarySource(targetID)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func testWikiBridgeSource(targetID: UUID) {
        Task {
            guard let target = settings.wikiBot.sources.first(where: { $0.id == targetID }) else { return }
            let usesWeaponCommand = target.commands.contains { normalizedWikiCommandTrigger($0.trigger) == "weapon" }
            let testQuery = usesWeaponCommand ? "AKM" : "Main Page"
            let result = await wikiLookupService.lookupWiki(query: testQuery, source: target)
            updateWikiBridgeSourceRuntimeState(id: targetID) { entry in
                entry.lastLookupAt = Date()
                if let result {
                    entry.lastStatus = "Resolved: \(result.title)"
                } else {
                    entry.lastStatus = "No result for \"\(testQuery)\""
                }
            }
            persistSettingsQuietly()
        }
    }

    func runWikiBridgeSourceTestQuery(source: WikiSource, query: String) async -> FinalsWikiLookupResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await wikiLookupService.lookupWiki(query: trimmed, source: source)
    }

    func updateWikiBridgeSourceRuntimeState(id: UUID, apply: (inout WikiSource) -> Void) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.wikiBot.sources[idx]
        apply(&target)
        settings.wikiBot.sources[idx] = target
    }

}
