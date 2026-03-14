import Foundation
import SwiftUI

extension AppModel {

    // MARK: - Patchy Update Monitoring

    func addPatchyTarget(_ target: PatchySourceTarget) {
        settings.patchy.sourceTargets.append(target)
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func updatePatchyTarget(_ target: PatchySourceTarget) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == target.id }) else { return }
        settings.patchy.sourceTargets[idx] = target
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func deletePatchyTarget(_ targetID: UUID) {
        settings.patchy.sourceTargets.removeAll { $0.id == targetID }
        saveSettings()
    }

    func togglePatchyTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled.toggle()
        saveSettings()
    }

    func setPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled = enabled
        saveSettings()
    }

    func runPatchyManualCheck() {
        Task {
            await runPatchyMonitoringCycle(trigger: "Manual")
        }
    }

    private func validatePatchyTarget(_ target: PatchySourceTarget, forceRefresh: Bool = false) async -> (isValid: Bool, detail: String) {
        let channelId = target.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelId.isEmpty else {
            return (false, "Target channel ID is empty.")
        }

        let now = Date()
        if !forceRefresh, let cached = patchyTargetValidationCache[channelId], now.timeIntervalSince(cached.validatedAt) < 3600 {
            return (cached.isValid, cached.detail)
        }

        do {
            _ = try await service.fetchChannel(channelId: channelId, token: settings.token)
            let result = (true, "Ready")
            patchyTargetValidationCache[channelId] = (result.0, result.1, now)
            return result
        } catch {
            let detail = patchyErrorDiagnostic(from: error)
            let result = (false, detail)
            patchyTargetValidationCache[channelId] = (result.0, result.1, now)
            return result
        }
    }

    func sendPatchyTest(targetID: UUID) {
        Task {
            guard let target = settings.patchy.sourceTargets.first(where: { $0.id == targetID }) else { return }
            guard !target.channelId.isEmpty else {
                appendPatchyLog("Test send skipped: target channel is empty.")
                return
            }

            let validation = await validatePatchyTarget(target, forceRefresh: true)
            guard validation.isValid else {
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = validation.detail
                }
                persistSettingsQuietly()
                appendPatchyLog("Patchy test skipped: \(validation.detail)")
                return
            }

            do {
                resolveSteamNameIfNeeded(for: target)
                let source = try PatchyRuntime.makeSource(from: target)
                let item = try await source.fetchLatest()
                let mapped = PatchyRuntime.map(item: item, change: .unchanged(identifier: item.identifier))
                let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                let delivery = await sendPatchyNotificationDetailed(
                    channelId: target.channelId,
                    message: fallback,
                    embedJSON: mapped.embedJSON,
                    roleIDs: target.roleIDs
                )

                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastRunAt = Date()
                    entry.lastStatus = delivery.detail
                }
                persistSettingsQuietly()
                appendPatchyLog("Test send [\(target.source.rawValue)] -> \(delivery.detail)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Patchy test failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                appendPatchyLog("Patchy test failed: \(diagnostic)")
            }
        }
    }

    func pullPatchyUpdate(targetID: UUID) {
        Task {
            guard let target = settings.patchy.sourceTargets.first(where: { $0.id == targetID }) else { return }
            
            do {
                resolveSteamNameIfNeeded(for: target)
                let source = try PatchyRuntime.makeSource(from: target)
                let item = try await source.fetchLatest()
                let mapped = PatchyRuntime.map(item: item, change: .unchanged(identifier: item.identifier))
                
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = mapped.statusSummary
                }
                persistSettingsQuietly()
                appendPatchyLog("Pull [\(target.source.rawValue)] -> \(mapped.statusSummary)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Pull failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                appendPatchyLog("Pull [\(target.source.rawValue)] failed: \(diagnostic)")
            }
        }
    }

    func configurePatchyMonitoring() {
        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil

        guard settings.patchy.monitoringEnabled else {
            appendPatchyLog("Patchy monitoring paused.")
            return
        }

        patchyMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runPatchyMonitoringCycle(trigger: "Startup")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                if Task.isCancelled { break }
                await self.runPatchyMonitoringCycle(trigger: "Scheduled")
            }
        }
        appendPatchyLog("Patchy monitoring started (hourly).")
    }

    struct PatchySourceGroupKey: Hashable {
        let source: PatchySourceKind
        let steamAppID: String
    }

    func runPatchyMonitoringCycle(trigger: String) async {
        guard !patchyIsCycleRunning else { return }
        guard let patchyChecker else {
            appendPatchyLog("Patchy checker unavailable. Cycle skipped.")
            return
        }

        let enabledTargets = settings.patchy.sourceTargets.filter { $0.isEnabled && !$0.channelId.isEmpty }
        guard !enabledTargets.isEmpty else {
            appendPatchyLog("Patchy cycle (\(trigger)) skipped: no enabled targets.")
            patchyLastCycleAt = Date()
            return
        }

        patchyIsCycleRunning = true
        defer {
            patchyIsCycleRunning = false
            patchyLastCycleAt = Date()
        }

        let grouped = Dictionary(grouping: enabledTargets) { target in
            PatchySourceGroupKey(
                source: target.source,
                steamAppID: target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        for (_, targets) in grouped {
            guard let referenceTarget = targets.first else { continue }

            do {
                resolveSteamNameIfNeeded(for: referenceTarget)
                let source = try PatchyRuntime.makeSource(from: referenceTarget)
                let item = try await source.fetchLatest()
                let mapped: PatchyFetchResult
                if let driverItem = item as? DriverUpdateItem {
                    let newestVersion = driverItem.version.trimmingCharacters(in: .whitespacesAndNewlines)
                    let versionKey = PatchyRuntime.lastPostedDriverVersionKey(for: item.sourceKey)
                    let versionCheck = try await patchyChecker.check(identifier: newestVersion, for: versionKey)
                    mapped = PatchyRuntime.map(item: item, change: versionCheck)
                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch versionCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                        appendPatchyLog("Patchy driver baseline initialized [\(referenceTarget.source.rawValue)] version=\(newestVersion)")
                    case .unchanged:
                        break
                    case .changed(let oldVersion, _):
                        guard let comparison = PatchyRuntime.compareDriverVersions(newestVersion, oldVersion) else {
                            try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            appendPatchyLog("Patchy migrated legacy driver baseline [\(referenceTarget.source.rawValue)] old=\(oldVersion) new=\(newestVersion)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer driver [\(referenceTarget.source.rawValue)] latest=\(newestVersion) lastPosted=\(oldVersion)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            }
                        }
                    }
                } else if let steamItem = item as? SteamUpdateItem {
                    let newestStamp = PatchyRuntime.makeSteamOrderingStamp(item: steamItem)
                    let steamKey = PatchyRuntime.lastPostedSteamIdentifierKey(for: item.sourceKey)
                    let steamCheck = try await patchyChecker.check(identifier: newestStamp, for: steamKey)
                    mapped = PatchyRuntime.map(item: item, change: steamCheck)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch steamCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                        appendPatchyLog("Patchy Steam baseline initialized [\(referenceTarget.steamAppID)] stamp=\(newestStamp)")
                    case .unchanged:
                        break
                    case .changed(let oldStamp, _):
                        guard let comparison = PatchyRuntime.compareSteamOrderingStamp(newestStamp, oldStamp) else {
                            try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            appendPatchyLog("Patchy migrated legacy Steam baseline [\(referenceTarget.steamAppID)] old=\(oldStamp) new=\(newestStamp)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer Steam item [\(referenceTarget.steamAppID)] latest=\(newestStamp) lastPosted=\(oldStamp)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            }
                        }
                    }
                } else {
                    let change = try await patchyChecker.check(item: item)
                    try await patchyChecker.save(item: item)
                    mapped = PatchyRuntime.map(item: item, change: change)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    if change.isNewItem {
                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                        }
                    }
                }
            } catch {
                for target in targets {
                    updatePatchyTargetRuntimeState(id: target.id) { entry in
                        entry.lastCheckedAt = Date()
                        entry.lastStatus = "Patchy check failed: \(error.localizedDescription)"
                    }
                }
                appendPatchyLog("Patchy cycle \(referenceTarget.source.rawValue) failed: \(error.localizedDescription)")
            }
        }

        persistSettingsQuietly()
    }

    func updatePatchyTargetRuntimeState(id: UUID, apply: (inout PatchySourceTarget) -> Void) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.patchy.sourceTargets[idx]
        apply(&target)
        settings.patchy.sourceTargets[idx] = target
    }

    func appendPatchyLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let final = "[\(stamp)] \(line)"
        patchyDebugLogs.insert(final, at: 0)
        if patchyDebugLogs.count > 200 {
            patchyDebugLogs.removeLast(patchyDebugLogs.count - 200)
        }
        logs.append("Patchy: \(line)")
    }

    func persistSettingsQuietly() {
        let snapshot = settings
        Task {
            do {
                try await store.save(snapshot)
                try await swiftMeshConfigStore.save(snapshot.swiftMeshSettings)
            } catch {
                await MainActor.run {
                    self.logs.append("❌ Failed saving settings: \(error.localizedDescription)")
                }
            }
        }
    }

    func migrateLegacyPatchySettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        guard loaded.patchy.sourceTargets.isEmpty, !loaded.patchy.targets.isEmpty else {
            return false
        }

        let migratedTargets = loaded.patchy.targets.map { legacy in
            PatchySourceTarget(
                isEnabled: legacy.isEnabled,
                source: loaded.patchy.source,
                steamAppID: loaded.patchy.steamAppID,
                serverId: legacy.serverId,
                channelId: legacy.channelId,
                roleIDs: legacy.roleIDs
            )
        }

        loaded.patchy.sourceTargets = migratedTargets
        return true
    }

    func migrateLegacyWikiBridgeSettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        let previousTargets = loaded.wikiBot.sources.count
        let previousPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        loaded.wikiBot.normalizeSources()
        let currentPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        return previousTargets != loaded.wikiBot.sources.count || previousPrimary != currentPrimary
    }

    func patchyErrorDiagnostic(from error: Error) -> String {
        let ns = error as NSError
        let statusCode = ns.userInfo["statusCode"] as? Int ?? ns.code
        let body = (ns.userInfo["responseBody"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Try to parse Discord's specific error code from the JSON body
        var discordCode: Int? = nil
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? Int {
            discordCode = code
        }

        // Map to HIG-aligned, actionable messages
        switch (statusCode, discordCode) {
        case (403, 50001?):
            return "SwiftBot cannot view this channel. Check permissions in the Discord server."
        case (403, 50013?):
            return "SwiftBot lacks 'Embed Links' or 'Mention' permissions in this channel."
        case (404, 10003?):
            return "Channel not found. It may have been deleted — please remove or update this target."
        case (401, _):
            return "Invalid Bot Token. Please check your token in General Settings."
        case (429, _):
            return "Sending too fast. Discord is temporarily limiting requests."
        default:
            if !body.isEmpty && body != "-" {
                let trimmedBody = body.count > 120 ? String(body.prefix(117)) + "..." : body
                return "Failed to send (HTTP \(statusCode)). Details: \(trimmedBody)"
            }
            return "Failed to send (HTTP \(statusCode)). Check Patchy logs for details."
        }
    }

    func resolveSteamNameIfNeeded(for target: PatchySourceTarget) {
        guard target.source == .steam else { return }
        let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return }
        if let existing = settings.patchy.steamAppNames[appID], !existing.isEmpty {
            return
        }

        Task {
            if let name = await fetchSteamAppName(appID: appID) {
                await MainActor.run {
                    self.settings.patchy.steamAppNames[appID] = name
                    self.persistSettingsQuietly()
                }
            }
        }
    }

    func fetchSteamAppName(appID: String) async -> String? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let appNode = root[appID] as? [String: Any],
                let success = appNode["success"] as? Bool, success,
                let dataNode = appNode["data"] as? [String: Any],
                let name = dataNode["name"] as? String
            else {
                return nil
            }

            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

}
