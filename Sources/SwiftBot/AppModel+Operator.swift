import Foundation

/// Decides when a problem becomes an alert: only after it has lasted a
/// while, once per problem, with an all-clear when it's fixed and no repeat
/// of the same alert within half an hour.
struct OperatorIssueTracker {
    enum Transition: Equatable { case raise, resolve }

    private struct Issue {
        let firstSeen: Date
        var notified = false
        /// False when the alert was held back by the quiet period.
        var sent = false
    }

    private var issues: [String: Issue] = [:]
    private var lastRaised: [String: Date] = [:]
    static let quietPeriod: TimeInterval = 30 * 60

    mutating func observe(_ key: String, isProblem: Bool, after delay: TimeInterval, now: Date = Date()) -> Transition? {
        if isProblem {
            var issue = issues[key] ?? Issue(firstSeen: now)
            defer { issues[key] = issue }
            guard !issue.notified, now.timeIntervalSince(issue.firstSeen) >= delay else { return nil }
            issue.notified = true
            if let last = lastRaised[key], now.timeIntervalSince(last) < Self.quietPeriod {
                return nil
            }
            issue.sent = true
            lastRaised[key] = now
            return .raise
        }
        // An all-clear only follows an alert that was actually sent.
        guard let issue = issues.removeValue(forKey: key), issue.sent else { return nil }
        return .resolve
    }

    /// Error and failure lines in the app log within the window.
    static func errorLines(in lines: [String], since start: Date) -> [String] {
        let formatter = ISO8601DateFormatter()
        return lines.filter { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]"),
                  let date = formatter.date(from: String(line[line.index(after: line.startIndex)..<close])),
                  date >= start else { return false }
            return line.contains("[ERR]") || line.contains("❌") || line.contains("[ERROR]")
        }
    }
}

extension AppModel {
    /// This Mac's name in SwiftMesh, which operators are keyed by.
    var operatorNodeName: String {
        let name = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (Host.current().localizedName ?? "SwiftBot Node") : name
    }

    func operatorID(forNode node: String) -> String? {
        let id = settings.operators.operatorsByNode[node]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return id.isEmpty ? nil : id
    }

    /// Starts the once-a-minute check. Safe to call repeatedly.
    func configureOperatorMonitoring() {
        guard operatorMonitorTask == nil else { return }
        operatorMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.checkOperatorAlerts()
            }
        }
    }

    func checkOperatorAlerts(now: Date = Date()) async {
        let thisNode = operatorNodeName

        // Discord: reconnecting or connecting for over five minutes. A bot
        // someone stopped on purpose isn't a problem.
        await operatorObserve(.discordDisconnected, key: "discord", node: thisNode,
                              isProblem: status == .connecting || status == .reconnecting, after: 5 * 60, now: now,
                              detail: "SwiftBot on \(thisNode) has been trying to reconnect to Discord for over 5 minutes.",
                              resolvedDetail: "SwiftBot on \(thisNode) is connected to Discord again.")

        // Other Macs: seen from the Primary.
        if settings.clusterMode == .leader {
            for node in clusterNodes where node.displayName.caseInsensitiveCompare(thisNode) != .orderedSame {
                await operatorObserve(.nodeOffline, key: "node|\(node.displayName)", node: node.displayName,
                                      isProblem: node.status == .disconnected, after: 3 * 60, now: now,
                                      detail: "\(node.displayName) stopped responding to the SwiftMesh Primary (\(thisNode)) over 3 minutes ago.",
                                      resolvedDetail: "\(node.displayName) is back and talking to \(thisNode).")
            }
        }

        // Recording folders on this Mac.
        for source in mediaLibrarySettings.sources where source.isEnabled {
            let path = source.normalizedRootPath
            guard !path.isEmpty else { continue }
            var isDirectory: ObjCBool = false
            let reachable = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            await operatorObserve(.recordingsUnreachable, key: "recordings|\(source.id.uuidString)", node: thisNode,
                                  isProblem: !reachable, after: 2 * 60, now: now,
                                  detail: "The \(source.name) recordings folder (\(path)) can't be reached from \(thisNode). Is the drive or NAS connected?",
                                  resolvedDetail: "The \(source.name) recordings folder is reachable again.")
        }

        // A burst of errors in the last 10 minutes.
        let recentErrors = OperatorIssueTracker.errorLines(in: logs.lines, since: now.addingTimeInterval(-10 * 60))
        let latest = recentErrors.suffix(3).map { "• " + String($0.drop(while: { $0 != "]" }).dropFirst()).trimmingCharacters(in: .whitespaces) }
        await operatorObserve(.errorBurst, key: "errors", node: thisNode,
                              isProblem: recentErrors.count >= 8, after: 0, now: now,
                              detail: "\(recentErrors.count) errors on \(thisNode) in the last 10 minutes. Latest:\n" + latest.joined(separator: "\n"),
                              resolvedDetail: "Errors on \(thisNode) have settled down.")

        // Role changes on this Mac (Primary ↔ Fail Over).
        let mode = clusterSnapshot.mode
        if let previous = lastObservedClusterMode, previous != mode {
            await sendOperatorAlert(.roleChanges, node: thisNode, resolved: false,
                                    title: "\(thisNode) is now \(mode.displayName)",
                                    detail: "\(thisNode) changed from \(previous.displayName) to \(mode.displayName).")
        }
        lastObservedClusterMode = mode
    }

    private func operatorObserve(
        _ kind: OperatorAlertKind, key: String, node: String, isProblem: Bool, after delay: TimeInterval, now: Date,
        detail: String, resolvedDetail: String
    ) async {
        switch operatorIssues.observe(key, isProblem: isProblem, after: delay, now: now) {
        case .raise:
            await sendOperatorAlert(kind, node: node, resolved: false, title: "\(kind.title) on \(node)", detail: detail)
        case .resolve:
            await sendOperatorAlert(kind, node: node, resolved: true, title: "Fixed: \(kind.title.lowercased()) on \(node)", detail: resolvedDetail)
        case nil:
            break
        }
    }

    // MARK: - WebUI

    func adminWebOperatorsSnapshot() -> AdminWebOperatorsPayload {
        let thisNode = operatorNodeName
        var names = [thisNode]
        for node in clusterNodes.map(\.displayName) + Array(settings.operators.operatorsByNode.keys)
        where !names.contains(where: { $0.caseInsensitiveCompare(node) == .orderedSame }) {
            names.append(node)
        }
        return AdminWebOperatorsPayload(
            thisNode: thisNode,
            nodes: names.map { .init(name: $0, operatorID: operatorID(forNode: $0), isThisNode: $0 == thisNode) },
            alerts: OperatorAlertKind.allCases.map { .init(id: $0.rawValue, title: $0.title, enabled: settings.operators.enabledAlerts.contains($0)) },
            members: discordMemberOptions.map { .init(id: $0.id, name: $0.displayName, username: $0.username) }
        )
    }

    func applyAdminWebOperatorsPatch(_ patch: AdminWebOperatorsPatch) -> Bool {
        guard !isFailoverManagedNode else { return false }
        if let node = patch.node?.trimmingCharacters(in: .whitespacesAndNewlines), !node.isEmpty {
            let user = patch.userID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard user.isEmpty || user.allSatisfy(\.isNumber) else { return false }
            settings.operators.operatorsByNode[node] = user.isEmpty ? nil : user
        } else if let raw = patch.alert, let kind = OperatorAlertKind(rawValue: raw), let enabled = patch.enabled {
            if enabled { settings.operators.enabledAlerts.insert(kind) } else { settings.operators.enabledAlerts.remove(kind) }
        } else {
            return false
        }
        saveSettings()
        return true
    }

    /// Returns nil when the test DM went out, or why it couldn't.
    func sendOperatorTestAlert() async -> String? {
        guard operatorID(forNode: operatorNodeName) != nil else { return "no_operator" }
        guard ActionDispatcher.canSend(clusterMode: runtimeClusterMode, action: "operatorAlert", log: { _ in }) else { return "not_primary" }
        let sent = await sendOperatorAlert(nil, node: operatorNodeName, resolved: false,
                                           title: "Test alert from \(operatorNodeName)",
                                           detail: "This is how SwiftBot will let you know when something needs a look on \(operatorNodeName).")
        return sent ? nil : "dm_failed"
    }

    /// DMs the Mac's operator, falling back to this Mac's operator for a
    /// Mac that has none. Only the node allowed to post to Discord sends.
    @discardableResult
    func sendOperatorAlert(_ kind: OperatorAlertKind?, node: String, resolved: Bool, title: String, detail: String) async -> Bool {
        if let kind, !settings.operators.enabledAlerts.contains(kind) { return false }
        guard let userID = operatorID(forNode: node) ?? operatorID(forNode: operatorNodeName) else { return false }
        guard ActionDispatcher.canSend(clusterMode: runtimeClusterMode, action: "operatorAlert", log: { _ in }) else { return false }
        let embed: [String: Any] = [
            "title": (resolved ? "✅ " : kind == nil ? "👋 " : "⚠️ ") + title,
            "description": detail,
            "color": resolved ? 0x30D158 : kind == .roleChanges || kind == nil ? 0x0A84FF : 0xFF9F0A,
            "footer": ["text": "You're the operator for \(node). Choose which alerts you get in SwiftBot → Settings → Operator."],
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            nonisolated(unsafe) let payload = embed
            try await service.sendDMEmbed(userId: userID, embed: payload)
            logs.append("[OK] Operator alert sent for \(node): \(title)")
            return true
        } catch {
            logs.append("⚠️ Couldn't DM the operator for \(node): \(error.localizedDescription)")
            return false
        }
    }
}
