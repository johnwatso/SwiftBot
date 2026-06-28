import Foundation

enum AutomationConflictDetector {
    enum Severity: String, Codable, Hashable, Sendable {
        case warning
        case info
    }

    struct Finding: Identifiable, Hashable, Sendable {
        let id: String
        let severity: Severity
        let ruleIds: [String]
        let title: String
        let detail: String
    }

    static func findings(in rules: [Automations.Rule]) -> [Finding] {
        let enabledRules = rules.filter(\.enabled)
        var output: [Finding] = []

        for rule in enabledRules {
            output.append(contentsOf: intraRuleFindings(for: rule))
        }

        for leftIndex in enabledRules.indices {
            for rightIndex in enabledRules.index(after: leftIndex)..<enabledRules.endIndex {
                let left = enabledRules[leftIndex]
                let right = enabledRules[rightIndex]
                guard scopesMayOverlap(left, right) else { continue }
                output.append(contentsOf: pairFindings(left, right))
            }
        }

        return output
    }

    static func findings(for rule: Automations.Rule, in rules: [Automations.Rule]) -> [Finding] {
        findings(in: rules).filter { $0.ruleIds.contains(rule.id) }
    }

    private static func intraRuleFindings(for rule: Automations.Rule) -> [Finding] {
        var output: [Finding] = []

        if let destructiveIndex = firstDestructiveStepIndex(in: rule),
           destructiveIndex < rule.steps.index(before: rule.steps.endIndex) {
            let laterStep = rule.steps[rule.steps.index(after: destructiveIndex)]
            output.append(Finding(
                id: "intra-\(rule.id)-post-destructive-\(destructiveIndex)",
                severity: .warning,
                ruleIds: [rule.id],
                title: "Steps after a destructive action may not run as expected",
                detail: "\(rule.name) runs \(stepSummary(rule.steps[destructiveIndex])) before \(stepSummary(laterStep)). Later steps may have no message or member left to work with."
            ))
        }

        if roleMutations(in: rule).contains(where: { $0.operation == .addRole })
            && roleMutations(in: rule).contains(where: { $0.operation == .removeRole }) {
            let addRoles = Set(roleMutations(in: rule).filter { $0.operation == .addRole }.compactMap(\.roleId))
            let removeRoles = Set(roleMutations(in: rule).filter { $0.operation == .removeRole }.compactMap(\.roleId))
            if !addRoles.isDisjoint(with: removeRoles) {
                output.append(Finding(
                    id: "intra-\(rule.id)-role-add-remove",
                    severity: .warning,
                    ruleIds: [rule.id],
                    title: "Rule adds and removes the same role",
                    detail: "\(rule.name) both adds and removes at least one matching role when it runs."
                ))
            }
        }

        return output
    }

    private static func pairFindings(_ left: Automations.Rule, _ right: Automations.Rule) -> [Finding] {
        var output: [Finding] = []
        let ordered = [left, right]

        if let destructiveRule = ordered.first(where: containsDestructiveAction) {
            let other = destructiveRule.id == left.id ? right : left
            if containsDiscordOutput(other) {
                output.append(Finding(
                    id: pairID(left, right, suffix: "destructive-output"),
                    severity: .warning,
                    ruleIds: [left.id, right.id],
                    title: "Moderation may prevent another rule from responding",
                    detail: "\(destructiveRule.name) can delete, timeout, kick, or move before \(other.name) sends a message, reaction, webhook, or DM for the same event."
                ))
            }
        }

        if sendsUserVisibleMessage(left) && sendsUserVisibleMessage(right) {
            output.append(Finding(
                id: pairID(left, right, suffix: "duplicate-response"),
                severity: .info,
                ruleIds: [left.id, right.id],
                title: "Two rules may respond to the same event",
                detail: "\(left.name) and \(right.name) can both send visible messages when the same trigger and conditions match."
            ))
        }

        for leftMutation in roleMutations(in: left) {
            for rightMutation in roleMutations(in: right) where mutationsConflict(leftMutation, rightMutation) {
                output.append(Finding(
                    id: pairID(left, right, suffix: "role-\(leftMutation.operation.rawValue)-\(rightMutation.operation.rawValue)-\(leftMutation.roleId ?? "unknown")"),
                    severity: .warning,
                    ruleIds: [left.id, right.id],
                    title: "Rules may fight over the same role",
                    detail: "\(left.name) and \(right.name) can both change the same role in opposite ways for the same event."
                ))
            }
        }

        return output
    }

    private static func scopesMayOverlap(_ left: Automations.Rule, _ right: Automations.Rule) -> Bool {
        guard left.trigger.kind == right.trigger.kind else { return false }
        guard optionalValuesMayOverlap(left.trigger.commandName, right.trigger.commandName) else { return false }
        guard optionalValuesMayOverlap(left.trigger.reactionEmoji, right.trigger.reactionEmoji) else { return false }
        guard channelsMayOverlap(channels(for: left), channels(for: right)) else { return false }
        guard directMessageScopeMayOverlap(left, right) else { return false }
        guard contentFiltersMayOverlap(left, right) else { return false }
        return true
    }

    private static func channels(for rule: Automations.Rule) -> Set<String>? {
        if let triggerChannel = clean(rule.trigger.channelId) {
            return [triggerChannel]
        }
        let channelFilters = rule.filters
            .filter { $0.kind == .inChannel }
            .compactMap(\.channelIds)
            .flatMap { $0.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        return channelFilters.isEmpty ? nil : Set(channelFilters)
    }

    private static func channelsMayOverlap(_ left: Set<String>?, _ right: Set<String>?) -> Bool {
        guard let left, let right else { return true }
        return !left.isDisjoint(with: right)
    }

    private static func directMessageScopeMayOverlap(_ left: Automations.Rule, _ right: Automations.Rule) -> Bool {
        guard let leftScope = directMessageScope(for: left),
              let rightScope = directMessageScope(for: right) else {
            return true
        }
        return leftScope == rightScope
    }

    private static func directMessageScope(for rule: Automations.Rule) -> Bool? {
        guard rule.filterLogic == .all else { return nil }
        let scopes = rule.filters.filter { $0.kind == .directMessage }.compactMap(\.boolValue)
        guard !scopes.isEmpty else { return nil }
        return scopes.allSatisfy { $0 == scopes[0] } ? scopes[0] : nil
    }

    private static func contentFiltersMayOverlap(_ left: Automations.Rule, _ right: Automations.Rule) -> Bool {
        guard left.filterLogic == .all, right.filterLogic == .all else { return true }

        let leftEquals = Set(left.filters.filter { $0.kind == .messageEquals }.compactMap { clean($0.text)?.lowercased() })
        let rightEquals = Set(right.filters.filter { $0.kind == .messageEquals }.compactMap { clean($0.text)?.lowercased() })
        if !leftEquals.isEmpty, !rightEquals.isEmpty, leftEquals.isDisjoint(with: rightEquals) {
            return false
        }

        let leftRequired = requiredMessageSubstrings(for: left)
        let rightRequired = requiredMessageSubstrings(for: right)
        if !leftEquals.isEmpty, !rightRequired.isEmpty {
            return leftEquals.contains { exact in rightRequired.allSatisfy { exact.contains($0) } }
        }
        if !rightEquals.isEmpty, !leftRequired.isEmpty {
            return rightEquals.contains { exact in leftRequired.allSatisfy { exact.contains($0) } }
        }

        return true
    }

    private static func requiredMessageSubstrings(for rule: Automations.Rule) -> [String] {
        rule.filters.compactMap { filter in
            guard filter.kind == .messageContains else { return nil }
            return clean(filter.text)?.lowercased()
        }
    }

    private static func optionalValuesMayOverlap(_ left: String?, _ right: String?) -> Bool {
        guard let left = clean(left), let right = clean(right) else { return true }
        return left.caseInsensitiveCompare(right) == .orderedSame
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func firstDestructiveStepIndex(in rule: Automations.Rule) -> Int? {
        rule.steps.firstIndex(where: isDestructiveStep)
    }

    private static func containsDestructiveAction(_ rule: Automations.Rule) -> Bool {
        rule.steps.contains(where: isDestructiveStep)
    }

    private static func isDestructiveStep(_ step: Automations.Step) -> Bool {
        switch step.kind {
        case .modifyMessage:
            return (step.messageOp ?? .delete) == .delete
        case .modifyMember:
            switch step.memberOp ?? .addRole {
            case .timeout, .kick, .moveVoice:
                return true
            case .addRole, .removeRole:
                return false
            }
        default:
            return false
        }
    }

    private static func containsDiscordOutput(_ rule: Automations.Rule) -> Bool {
        rule.steps.contains { step in
            switch step.kind {
            case .sendMessage, .webhook:
                return true
            case .modifyMessage:
                return (step.messageOp ?? .delete) == .react
            default:
                return false
            }
        }
    }

    private static func sendsUserVisibleMessage(_ rule: Automations.Rule) -> Bool {
        rule.steps.contains { $0.kind == .sendMessage || $0.kind == .webhook }
    }

    private struct RoleMutation: Hashable {
        let operation: Automations.MemberOp
        let roleId: String?
    }

    private static func roleMutations(in rule: Automations.Rule) -> [RoleMutation] {
        rule.steps.compactMap { step in
            guard step.kind == .modifyMember else { return nil }
            let op = step.memberOp ?? .addRole
            guard op == .addRole || op == .removeRole else { return nil }
            return RoleMutation(operation: op, roleId: clean(step.roleId))
        }
    }

    private static func mutationsConflict(_ left: RoleMutation, _ right: RoleMutation) -> Bool {
        guard left.operation != right.operation else { return false }
        guard let leftRole = left.roleId, let rightRole = right.roleId else { return true }
        return leftRole == rightRole
    }

    private static func pairID(_ left: Automations.Rule, _ right: Automations.Rule, suffix: String) -> String {
        [left.id, right.id].sorted().joined(separator: "-") + "-\(suffix)"
    }

    private static func stepSummary(_ step: Automations.Step) -> String {
        switch step.kind {
        case .sendMessage: return "send message"
        case .modifyMember:
            switch step.memberOp ?? .addRole {
            case .addRole: return "add role"
            case .removeRole: return "remove role"
            case .timeout: return "timeout"
            case .kick: return "kick"
            case .moveVoice: return "move voice user"
            }
        case .modifyMessage:
            return (step.messageOp ?? .delete) == .delete ? "delete message" : "react"
        case .log: return "write log"
        case .webhook: return "call webhook"
        case .delay: return "wait"
        case .aiTransform: return "AI transform"
        }
    }
}
