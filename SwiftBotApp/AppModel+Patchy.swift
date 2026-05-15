import Foundation
import SwiftUI

struct PatchyMonitoringSnapshot: Equatable {
    let patchySettings: PatchySettings
    let clusterMode: ClusterMode
    let botStatus: BotStatus
}

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
                logs.append("Patchy: " + "Test send skipped: target channel is empty.")
                return
            }

            let validation = await validatePatchyTarget(target, forceRefresh: true)
            guard validation.isValid else {
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = validation.detail
                }
                persistSettingsQuietly()
                logs.append("Patchy: " + "Patchy test skipped: \(validation.detail)")
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
                    embedJSON: await patchyEmbedJSON(
                        mapped.embedJSON,
                        for: target,
                        item: item
                    ),
                    roleIDs: target.roleIDs
                )

                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastRunAt = Date()
                    entry.lastStatus = delivery.detail
                }
                persistSettingsQuietly()
                logs.append("Patchy: " + "Test send [\(target.source.rawValue)] -> \(delivery.detail)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Patchy test failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                logs.append("Patchy: " + "Patchy test failed: \(diagnostic)")
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
                logs.append("Patchy: " + "Pull [\(target.source.rawValue)] -> \(mapped.statusSummary)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Pull failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                logs.append("Patchy: " + "Pull [\(target.source.rawValue)] failed: \(diagnostic)")
                appendPatchyErrorTraceIfPresent(error, context: "Pull [\(target.source.rawValue)]")
            }
        }
    }

    func configurePatchyMonitoring() {
        let snapshot = PatchyMonitoringSnapshot(
            patchySettings: settings.patchy,
            clusterMode: runtimeClusterMode,
            botStatus: status
        )

        guard snapshot != lastPatchyMonitoringSnapshot else { return }
        lastPatchyMonitoringSnapshot = snapshot

        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil

        let currentMode = runtimeClusterMode
        let isAuthorized = currentMode == .leader || currentMode == .standalone

        guard usesLocalRuntime, settings.patchy.monitoringEnabled, status == .running, isAuthorized else {
            logs.append("Patchy: " + "Patchy monitoring paused.")
            return
        }

        patchyMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runPatchyMonitoringCycle(trigger: "Startup")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                if Task.isCancelled { break }
                await self.runPatchyMonitoringCycle(trigger: "Scheduled")
            }
        }
        logs.append("Patchy: " + "Patchy monitoring started.")
    }

    struct PatchySourceGroupKey: Hashable {
        let source: PatchySourceKind
        let steamAppID: String
        let githubRepo: String
        let githubBranch: String
        let githubWatchAllCommits: Bool
    }

    func runPatchyMonitoringCycle(trigger: String) async {
        guard status == .running || trigger == "Manual" || trigger == "Startup" else {
            return
        }
        guard !patchyIsCycleRunning else { return }
        guard let patchyChecker else {
            logs.append("Patchy: " + "Patchy checker unavailable. Cycle skipped.")
            return
        }

        let enabledTargets = settings.patchy.sourceTargets.filter { $0.isEnabled && !$0.channelId.isEmpty }
        guard !enabledTargets.isEmpty else {
            logs.append("Patchy: " + "Patchy cycle (\(trigger)) skipped: no enabled targets.")
            setPatchyLastCycleAt(Date())
            return
        }

        let now = Date()
        let dueTargets = enabledTargets.filter { isPatchyTargetDue($0, now: now, trigger: trigger) }
        guard !dueTargets.isEmpty else {
            setPatchyLastCycleAt(now)
            return
        }

        patchyIsCycleRunning = true
        defer {
            patchyIsCycleRunning = false
            setPatchyLastCycleAt(Date())
        }

        let grouped = Dictionary(grouping: dueTargets) { target in
            PatchySourceGroupKey(
                source: target.source,
                steamAppID: target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines),
                githubRepo: target.githubRepo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                githubBranch: target.githubBranch.trimmingCharacters(in: .whitespacesAndNewlines),
                githubWatchAllCommits: target.githubWatchAllCommits
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
                        logs.append("Patchy: " + "Patchy driver baseline initialized [\(referenceTarget.source.rawValue)] version=\(newestVersion)")
                    case .unchanged:
                        break
                    case .changed(let oldVersion, _):
                        guard let comparison = PatchyRuntime.compareDriverVersions(newestVersion, oldVersion) else {
                            try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            logs.append("Patchy: " + "Patchy migrated legacy driver baseline [\(referenceTarget.source.rawValue)] old=\(oldVersion) new=\(newestVersion)")
                            break
                        }

                        guard comparison > 0 else {
                            logs.append("Patchy: " + "Patchy ignored non-newer driver [\(referenceTarget.source.rawValue)] latest=\(newestVersion) lastPosted=\(oldVersion)")
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
                                logs.append("Patchy: " + "Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: await patchyEmbedJSON(mapped.embedJSON, for: target, item: driverItem),
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
                } else if let githubItem = item as? GitHubUpdateItem {
                    let identifier = githubItem.identifier
                    let key = PatchyRuntime.lastPostedGitHubIdentifierKey(for: githubItem.sourceKey)
                    let check = try await patchyChecker.check(identifier: identifier, for: key)
                    mapped = PatchyRuntime.map(item: githubItem, change: check)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch check {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: identifier, for: key)
                        logs.append("Patchy: " + "Patchy GitHub baseline initialized [\(referenceTarget.githubRepo)] id=\(identifier)")
                    case .unchanged:
                        break
                    case .changed:
                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                logs.append("Patchy: " + "Patchy cycle [GitHub] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: await patchyEmbedJSON(mapped.embedJSON, for: target, item: githubItem),
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: identifier, for: key)
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
                        logs.append("Patchy: " + "Patchy Steam baseline initialized [\(referenceTarget.steamAppID)] stamp=\(newestStamp)")
                    case .unchanged:
                        break
                    case .changed(let oldStamp, _):
                        guard let comparison = PatchyRuntime.compareSteamOrderingStamp(newestStamp, oldStamp) else {
                            try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            logs.append("Patchy: " + "Patchy migrated legacy Steam baseline [\(referenceTarget.steamAppID)] old=\(oldStamp) new=\(newestStamp)")
                            break
                        }

                        guard comparison > 0 else {
                            logs.append("Patchy: " + "Patchy ignored non-newer Steam item [\(referenceTarget.steamAppID)] latest=\(newestStamp) lastPosted=\(oldStamp)")
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
                                logs.append("Patchy: " + "Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: await patchyEmbedJSON(mapped.embedJSON, for: target, item: steamItem),
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
                                logs.append("Patchy: " + "Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: await patchyEmbedJSON(mapped.embedJSON, for: target, item: item),
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
                logs.append("Patchy: " + "Patchy cycle \(referenceTarget.source.rawValue) failed: \(error.localizedDescription)")
            }
        }

        persistSettingsQuietly()
    }

    private func isPatchyTargetDue(_ target: PatchySourceTarget, now: Date, trigger: String) -> Bool {
        guard trigger == "Scheduled" else { return true }
        guard let lastCheckedAt = target.lastCheckedAt else { return true }

        let defaultInterval = PatchyEmbedAccent.defaultPollingIntervalMinutes(for: target.source)
        let configuredInterval = target.pollingIntervalMinutes > 0 ? target.pollingIntervalMinutes : defaultInterval
        let minimumInterval = target.source == .github ? 5 : 15
        let clampedInterval = max(configuredInterval, minimumInterval)
        return now.timeIntervalSince(lastCheckedAt) >= Double(clampedInterval * 60)
    }

    private func patchyEmbedJSON(_ embedJSON: String, for target: PatchySourceTarget, item: (any UpdateItem)? = nil) async -> String {
        let trimmed = embedJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var embeds = payload["embeds"] as? [[String: Any]],
              !embeds.isEmpty
        else {
            return embedJSON
        }

        embeds[0]["color"] = PatchyEmbedAccent.discordColorInt(hex: target.embedColorHex, source: target.source)
        if target.summarizeWithAppleIntelligence, let summaryInput = patchySummaryInput(for: item) {
            if let summary = await aiService.summarizePatchyUpdateWithAppleIntelligence(
                updateText: summaryInput.text,
                source: summaryInput.source
            ) {
                embeds[0] = patchyEmbedWithAISummary(embeds[0], summary: summary)
                logs.append("Patchy: " + "Summarised with AI [\(target.source.rawValue)].")
            } else {
                logs.append("Patchy: " + "AI summary skipped [\(target.source.rawValue)]: Apple Intelligence unavailable or returned no summary.")
            }
        }
        payload["embeds"] = embeds

        guard let encoded = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
              let output = String(data: encoded, encoding: .utf8)
        else {
            return embedJSON
        }
        return output
    }

    private func patchySummaryInput(for item: (any UpdateItem)?) -> (source: String, text: String)? {
        guard let item else { return nil }

        if let driver = item as? DriverUpdateItem {
            let text = """
            Title: \(driver.releaseNotes.title)
            Vendor: \(driver.releaseNotes.author)
            Version: \(driver.releaseNotes.version)
            Release date: \(driver.releaseNotes.date)

            \(patchyReleaseNotesText(driver.releaseNotes))
            """
            return ("\(driver.releaseNotes.author) driver release", text)
        }

        if let github = item as? GitHubUpdateItem {
            let modeLabel: String
            switch github.info.mode {
            case .releases:
                modeLabel = "release"
            case .commits:
                modeLabel = "commit"
            case .allCommits:
                modeLabel = "commit across branches"
            }
            let text = """
            Repository/source: \(github.info.author)
            Type: GitHub \(modeLabel)
            Title: \(github.info.title)
            Version/identifier: \(github.info.displayVersion)
            Date: \(github.info.date)
            URL: \(github.info.url)

            \(github.info.summary)
            """
            return ("GitHub \(modeLabel)", text)
        }

        if let steam = item as? SteamUpdateItem {
            let cleaned = steam.newsItem.contents
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\[[^\]]+\]"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = """
            Game/source: \(steam.newsItem.feedLabel)
            Title: \(steam.newsItem.title)
            Date: \(steam.newsItem.dateFormatted)
            URL: \(steam.newsItem.url)

            \(cleaned)
            """
            return ("Steam patch notes", text)
        }

        return nil
    }

    private func patchyReleaseNotesText(_ releaseNotes: ReleaseNotes) -> String {
        releaseNotes.sections.map { section in
            var lines = [section.title]
            for bullet in section.bullets {
                lines.append("- \(bullet.text)")
                lines += bullet.subBullets.map { "  - \($0)" }
            }
            return lines.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    private func patchyEmbedWithAISummary(_ embed: [String: Any], summary: String) -> [String: Any] {
        let cleanedSummary = patchyNormalizedAISummary(summary)
        guard !cleanedSummary.isEmpty else { return embed }

        var updated = embed
        let existingDescription = (embed["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summaryBlock = "**AI Summary**\n\(cleanedSummary)"
        let combined = existingDescription.isEmpty ? summaryBlock : "\(summaryBlock)\n\n\(existingDescription)"
        updated["description"] = patchyTruncateDiscordDescription(combined)
        return updated
    }

    private func patchyNormalizedAISummary(_ summary: String) -> String {
        let paragraphs = summary
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .components(separatedBy: .newlines)
                    .map { line -> String in
                        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        while text.hasPrefix("-") || text.hasPrefix("•") || text.hasPrefix("*") {
                            text.removeFirst()
                            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        return text
                    }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return paragraphs.prefix(2).joined(separator: "\n\n")
    }

    private func patchyTruncateDiscordDescription(_ description: String) -> String {
        let limit = 4096
        guard description.count > limit else { return description }
        return String(description.prefix(limit - 3)) + "..."
    }

    func updatePatchyTargetRuntimeState(id: UUID, apply: (inout PatchySourceTarget) -> Void) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.patchy.sourceTargets[idx]
        apply(&target)
        settings.patchy.sourceTargets[idx] = target
        persistSettingsQuietly()
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
        let explicitStatusCode = ns.userInfo["statusCode"] as? Int
        let statusCode = explicitStatusCode ?? ns.code
        let body = (ns.userInfo["responseBody"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet:
                return "Network appears offline. Check the internet connection and try again."
            case NSURLErrorTimedOut:
                return "Network request timed out while contacting the update source."
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
                return "Could not reach the update source host. Please try again shortly."
            default:
                let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !localized.isEmpty {
                    return "Network request failed: \(localized)"
                }
                return "Network request failed."
            }
        }

        if explicitStatusCode == nil && body.isEmpty {
            let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !localized.isEmpty,
               localized != "The operation couldn’t be completed." {
                return localized
            }
        }

        // Try to parse Discord's specific error code from the JSON body
        var discordCode: Int?
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

    func appendPatchyErrorTraceIfPresent(_ error: Error, context: String) {
        let ns = error as NSError
        guard let trace = ns.userInfo["amdDebugTrace"] as? String,
              !trace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        for line in trace.components(separatedBy: .newlines) where !line.isEmpty {
            logs.append("Patchy: " + "\(context) debug: \(line)")
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
