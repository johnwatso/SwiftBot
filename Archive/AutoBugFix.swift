// MARK: - Archived Bug Auto-Fix Feature (Deprecated / Removed)
// Preserved here in case we ever want to bring this feature back.
//
// Original files touched:
// - AppModel+Commands.swift
// - AppModel.swift
// - BotSettings.swift
// - AdvancedPreferencesView.swift

import Foundation
import SwiftUI
import AppKit

// MARK: - BotSettings Properties
/*
// Original properties in BotSettings.swift
var bugAutoFixEnabled: Bool = false
var bugAutoFixTriggerEmoji: String = "🤖"
var bugAutoFixCommandTemplate: String = "codex exec \"$SWIFTBOT_BUG_PROMPT\""
var bugAutoFixRepoPath: String = ""
var bugAutoFixGitBranch: String = "main"
var bugAutoFixVersionBumpEnabled: Bool = true
var bugAutoFixPushEnabled: Bool = true
var bugAutoFixRequireApproval: Bool = true
var bugAutoFixApproveEmoji: String = "🚀"
var bugAutoFixRejectEmoji: String = "🛑"
var bugAutoFixAllowedUsernames: [String] = []
*/

// MARK: - AppModel Properties
/*
// Original properties in AppModel.swift
@Published var bugAutoFixStatusText: String = "Idle"
@Published var bugAutoFixConsoleText: String = ""
var activeBugAutoFixMessageIDs: Set<String> = []
var pendingBugAutoFixStarts: [String: BugAutoFixPendingStart] = [:]
var pendingBugAutoFixApprovals: [String: BugAutoFixPendingApproval] = [:]
*/

// MARK: - Structs
struct BugAutoFixPendingStart: Hashable, Codable {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
    let requestedByUserID: String
}

struct BugAutoFixPendingApproval: Hashable, Codable {
    let bugMessageID: String
    let channelID: String
    let guildID: String
    let sourceRepoPath: String
    let isolatedRepoPath: String
    let branch: String
    let updateChannelID: String
    let version: String
    let build: String
}

// MARK: - Extension Methods from AppModel+Commands.swift
extension AppModel {
    func appendBugAutoFixConsole(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        let next = "[\(timestamp)] \(trimmed)\n"
        bugAutoFixConsoleText.append(next)
        if bugAutoFixConsoleText.count > 50_000 {
            bugAutoFixConsoleText = String(bugAutoFixConsoleText.suffix(50_000))
        }
    }

    func beginBugAutoFixSession(_ status: String) {
        bugAutoFixStatusText = status
        appendBugAutoFixConsole("=== \(status) ===")
    }

    func finishBugAutoFixSession(_ status: String) {
        bugAutoFixStatusText = status
        appendBugAutoFixConsole("=== \(status) ===")
    }

    func shouldTriggerBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixTriggerEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func shouldApproveBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixApproveEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func shouldRejectBugAutoFix(forEmoji emoji: String) -> Bool {
        guard settings.bugAutoFixEnabled else { return false }
        let trigger = normalizedReactionEmojiName(settings.bugAutoFixRejectEmoji)
        guard !trigger.isEmpty else { return false }
        return normalizedReactionEmojiName(emoji) == trigger
    }

    func bugAutoFixUsernameAllowed(userID: String) async -> Bool {
        let allowed = settings.bugAutoFixAllowedUsernames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !allowed.isEmpty else { return true }

        let known = (knownUsersById[userID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !known.isEmpty, allowed.contains(known) {
            return true
        }

        let resolved = (await displayNameForUserID(userID)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !resolved.isEmpty && allowed.contains(resolved)
    }

    func handleBugAutoFixReaction(
        raw: [String: DiscordJSON],
        messageID: String,
        channelID: String,
        userID: String
    ) async {
        guard settings.bugAutoFixEnabled else { return }
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix is restricted to configured usernames.")
            return
        }

        let guildID: String = {
            if case let .string(id)? = raw["guild_id"] { return id }
            return "unknown-guild"
        }()
        let updateChannelID = await ensureBugThreadChannelID(bugChannelID: channelID, bugMessageID: messageID) ?? channelID

        guard let bugMessage = await fetchMessage(channelId: channelID, messageId: messageID),
              case let .string(content)? = bugMessage["content"],
              content.contains("🐞 SwiftBot Bug")
        else { return }

        if pendingBugAutoFixStarts[messageID] != nil {
            _ = await send(updateChannelID, "⏳ Auto-fix is waiting for approval. React with \(settings.bugAutoFixApproveEmoji) to run, or \(settings.bugAutoFixRejectEmoji) to cancel.")
            return
        }

        if pendingBugAutoFixApprovals[messageID] != nil {
            _ = await send(updateChannelID, "⏳ Auto-fix proposal is waiting for approval. React with \(settings.bugAutoFixApproveEmoji) to commit+push, or \(settings.bugAutoFixRejectEmoji) to cancel.")
            return
        }

        guard !activeBugAutoFixMessageIDs.contains(messageID) else {
            _ = await send(updateChannelID, "⏳ Auto-fix is already running for this bug.")
            return
        }

        let repoPathRaw = settings.bugAutoFixRepoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceRepoPath = repoPathRaw.isEmpty ? FileManager.default.currentDirectoryPath : repoPathRaw

        let repoCheck = await runShellCommand("git rev-parse --is-inside-work-tree", workingDirectory: sourceRepoPath)
        let repoCheckOutput = repoCheck.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard repoCheck.exitCode == 0, repoCheckOutput.contains("true") else {
            finishBugAutoFixSession("Invalid repository path")
            _ = await send(
                updateChannelID,
                """
                ❌ Auto-fix repository path is not a git repository: `\(sourceRepoPath)`.
                Set **Settings → Bug Auto-Fix → Repository Path** to your SwiftBot repo root.
                """
            )
            return
        }

        let branch = settings.bugAutoFixGitBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "main"
            : settings.bugAutoFixGitBranch.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let release = await extractBugAutoFixReleaseInfo(channelID: updateChannelID) else {
            _ = await send(
                updateChannelID,
                """
                📝 Auto-fix needs a target release number before it can run.
                In this thread, add a comment like:
                `version=1.8.19 build=181900`
                Then react to the parent bug again with \(settings.bugAutoFixTriggerEmoji).
                """
            )
            return
        }

        guard let isolatedRepoPath = await createBugAutoFixWorkspaceClone(
            sourceRepoPath: sourceRepoPath,
            branch: branch,
            messageID: messageID
        ) else {
            _ = await send(updateChannelID, "❌ Failed to create isolated auto-fix workspace clone.")
            return
        }

        pendingBugAutoFixStarts[messageID] = BugAutoFixPendingStart(
            bugMessageID: messageID,
            channelID: channelID,
            guildID: guildID,
            sourceRepoPath: sourceRepoPath,
            isolatedRepoPath: isolatedRepoPath,
            branch: branch,
            updateChannelID: updateChannelID,
            version: release.version,
            build: release.build,
            requestedByUserID: userID
        )
        _ = await addReaction(channelId: channelID, messageId: messageID, emoji: settings.bugAutoFixApproveEmoji)
        _ = await addReaction(channelId: channelID, messageId: messageID, emoji: settings.bugAutoFixRejectEmoji)

        _ = await send(
            updateChannelID,
            """
            🧾 Auto-fix preflight ready for bug `\(messageID)`.
            Target release: `\(release.version) (\(release.build))`
            Workspace: `\(isolatedRepoPath)`
            No changes were made to the live repo.
            React on the parent bug with \(settings.bugAutoFixApproveEmoji) to start Codex, or \(settings.bugAutoFixRejectEmoji) to cancel.
            """
        )
    }

    func approvePendingBugAutoFix(raw: [String: DiscordJSON], messageID: String, channelID: String, userID: String) async {
        if let pendingStart = pendingBugAutoFixStarts[messageID] {
            guard await bugAutoFixUsernameAllowed(userID: userID) else {
                _ = await send(channelID, "⛔ Auto-fix approval is restricted to configured usernames.")
                return
            }
            pendingBugAutoFixStarts.removeValue(forKey: messageID)
            _ = await send(pendingStart.updateChannelID, "✅ Auto-fix run approved by <@\(userID)>. Starting Codex in isolated workspace…")
            await runPendingBugAutoFixStart(pendingStart)
            return
        }

        guard let pending = pendingBugAutoFixApprovals[messageID] else { return }
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix approval is restricted to configured usernames.")
            return
        }
        pendingBugAutoFixApprovals.removeValue(forKey: messageID)
        _ = await send(pending.updateChannelID, "✅ Auto-fix approved by <@\(userID)>. Committing and pushing…")
        beginBugAutoFixSession("Approval received; committing and pushing")
        await executeApprovedBugAutoFixPush(
            messageID: pending.bugMessageID,
            updateChannelID: pending.updateChannelID,
            repoPath: pending.isolatedRepoPath,
            branch: pending.branch,
            version: pending.version,
            build: pending.build
        )
    }

    func rejectPendingBugAutoFix(raw: [String: DiscordJSON], messageID: String, channelID: String, userID: String) async {
        guard await bugAutoFixUsernameAllowed(userID: userID) else {
            _ = await send(channelID, "⛔ Auto-fix rejection is restricted to configured usernames.")
            return
        }

        if let pendingStart = pendingBugAutoFixStarts[messageID] {
            pendingBugAutoFixStarts.removeValue(forKey: messageID)
            _ = await runShellCommand("rm -rf \(shellQuote(pendingStart.isolatedRepoPath))", workingDirectory: FileManager.default.currentDirectoryPath)
            finishBugAutoFixSession("Preflight rejected by \(userID)")
            _ = await send(pendingStart.updateChannelID, "🛑 Auto-fix preflight cancelled by <@\(userID)> before any code changes.")
            return
        }

        guard pendingBugAutoFixApprovals[messageID] != nil else { return }
        let updateChannelID = pendingBugAutoFixApprovals[messageID]?.updateChannelID ?? channelID
        pendingBugAutoFixApprovals.removeValue(forKey: messageID)
        finishBugAutoFixSession("Proposal rejected by \(userID)")
        _ = await send(updateChannelID, "🛑 Auto-fix proposal rejected by <@\(userID)>. Isolated workspace changes were retained for manual review.")
    }

    func executeApprovedBugAutoFixPush(
        messageID: String,
        updateChannelID: String,
        repoPath: String,
        branch: String,
        version: String,
        build: String
    ) async {
        let shortId = String(messageID.prefix(8))
        let add = await runShellCommand("git add -A", workingDirectory: repoPath)
        guard add.exitCode == 0 else {
            finishBugAutoFixSession("Failed at git add")
            _ = await send(updateChannelID, "❌ Auto-fix completed, but `git add` failed.")
            return
        }

        let commit = await runShellCommand(
            "git commit -m \"fix: auto-fix bug \(shortId) v\(version) (\(build))\"",
            workingDirectory: repoPath
        )
        if commit.exitCode != 0 {
            let output = commit.combinedOutput.lowercased()
            if output.contains("nothing to commit") || output.contains("no changes added") {
                finishBugAutoFixSession("No committable changes")
                _ = await send(updateChannelID, "ℹ️ Auto-fix proposal had no committable changes.")
                return
            }
            finishBugAutoFixSession("Failed at git commit")
            _ = await send(updateChannelID, "❌ Auto-fix commit failed (exit \(commit.exitCode)).")
            return
        }

        let push = await runShellCommand("git push origin \(branch)", workingDirectory: repoPath)
        guard push.exitCode == 0 else {
            finishBugAutoFixSession("Failed at git push")
            _ = await send(updateChannelID, "❌ Auto-fix committed, but push to `origin/\(branch)` failed.")
            return
        }
        finishBugAutoFixSession("Pushed to \(branch)")
        _ = await send(updateChannelID, "🚀 Auto-fix committed and pushed to `\(branch)` with version `\(version)` build `\(build)`. CI/ShipHook build should start shortly.")
    }

    func applyVersionAndBuildNumber(repoPath: String, version: String, build: String) -> Bool {
        let pbxprojPath = URL(fileURLWithPath: repoPath)
            .appendingPathComponent("SwiftBot.xcodeproj")
            .appendingPathComponent("project.pbxproj")
        guard let content = try? String(contentsOf: pbxprojPath, encoding: .utf8) else { return false }

        guard
            let buildRegex = try? NSRegularExpression(pattern: #"CURRENT_PROJECT_VERSION = [^;]+;"#),
            let versionRegex = try? NSRegularExpression(pattern: #"MARKETING_VERSION = [^;]+;"#)
        else { return false }

        let ns = content as NSString
        let buildReplaced = buildRegex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: "CURRENT_PROJECT_VERSION = \(build);"
        )
        let versionNs = buildReplaced as NSString
        let replaced = versionRegex.stringByReplacingMatches(
            in: buildReplaced,
            range: NSRange(location: 0, length: versionNs.length),
            withTemplate: "MARKETING_VERSION = \(version);"
        )

        do {
            try replaced.write(to: pbxprojPath, atomically: true, encoding: .utf8)
            logs.append("Auto-fix set MARKETING_VERSION=\(version), CURRENT_PROJECT_VERSION=\(build)")
            return true
        } catch {
            logs.append("Auto-fix version/build write failed: \(error.localizedDescription)")
            return false
        }
    }

    func runPendingBugAutoFixStart(_ pending: BugAutoFixPendingStart) async {
        guard !activeBugAutoFixMessageIDs.contains(pending.bugMessageID) else {
            _ = await send(pending.updateChannelID, "⏳ Auto-fix is already running for this bug.")
            return
        }
        activeBugAutoFixMessageIDs.insert(pending.bugMessageID)
        defer { activeBugAutoFixMessageIDs.remove(pending.bugMessageID) }

        let commandTemplate = settings.bugAutoFixCommandTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandTemplate.isEmpty else {
            _ = await send(pending.updateChannelID, "❌ Auto-fix command template is empty. Configure it in Settings → Bug Auto-Fix.")
            return
        }

        guard let bugMessage = await fetchMessage(channelId: pending.channelID, messageId: pending.bugMessageID),
              case let .string(content)? = bugMessage["content"],
              content.contains("🐞 SwiftBot Bug")
        else {
            _ = await send(pending.updateChannelID, "❌ Could not fetch the source bug report message.")
            return
        }

        beginBugAutoFixSession("Running Codex for bug \(pending.bugMessageID)")
        _ = await send(
            pending.updateChannelID,
            """
            🤖 Auto-fix triggered by <@\(pending.requestedByUserID)> — running Codex pipeline…
            Release target: `\(pending.version) (\(pending.build))`
            Workspace: `\(pending.isolatedRepoPath)`
            """
        )

        var lastForwardAt = Date.distantPast
        var bufferedForward = ""
        func flushForwardBuffer() {
            let trimmed = bufferedForward.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let sanitized = trimmed.replacingOccurrences(of: "```", with: "'''")
            let snippet = String(sanitized.suffix(1400))
            bufferedForward = ""
            lastForwardAt = Date()
            Task { _ = await send(pending.updateChannelID, "```text\n\(snippet)\n```") }
        }

        let prompt = """
        You are fixing a tracked SwiftBot bug.
        Source repository: \(pending.sourceRepoPath)
        Isolated workspace: \(pending.isolatedRepoPath)
        Bug message ID: \(pending.bugMessageID)
        Discord guild/channel: \(pending.guildID)/\(pending.channelID)
        Target release version/build: \(pending.version) (\(pending.build))

        Bug report content:
        \(content)

        Required:
        1) Implement a safe fix in the isolated workspace only.
        2) Keep changes minimal and targeted.
        3) Summarize what changed and why in concise bullets.
        """

        let contextURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftbot-bug-\(pending.bugMessageID).txt")
        do {
            try prompt.write(to: contextURL, atomically: true, encoding: .utf8)
        } catch {
            _ = await send(pending.updateChannelID, "❌ Failed to write bug context file: \(error.localizedDescription)")
            return
        }

        let codex = await runShellCommand(
            commandTemplate,
            workingDirectory: pending.isolatedRepoPath,
            environment: [
                "SWIFTBOT_BUG_PROMPT": prompt,
                "SWIFTBOT_BUG_CONTEXT_FILE": contextURL.path,
                "SWIFTBOT_REPO_PATH": pending.isolatedRepoPath,
                "SWIFTBOT_BUG_MESSAGE_ID": pending.bugMessageID,
                "SWIFTBOT_BUG_CHANNEL_ID": pending.channelID,
                "SWIFTBOT_BUG_GUILD_ID": pending.guildID,
                "SWIFTBOT_TARGET_VERSION": pending.version,
                "SWIFTBOT_TARGET_BUILD": pending.build
            ],
            outputSink: { chunk in
                bufferedForward.append(chunk)
                let now = Date()
                if bufferedForward.count > 1400 || now.timeIntervalSince(lastForwardAt) >= 4 {
                    flushForwardBuffer()
                }
            }
        )
        flushForwardBuffer()

        guard codex.exitCode == 0 else {
            let tail = codex.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = tail.isEmpty ? "No output." : String(tail.suffix(700))
            finishBugAutoFixSession("Codex failed (exit \(codex.exitCode))")
            _ = await send(pending.updateChannelID, "❌ Codex auto-fix failed (exit \(codex.exitCode)).\n```\(snippet)```")
            return
        }

        if !applyVersionAndBuildNumber(repoPath: pending.isolatedRepoPath, version: pending.version, build: pending.build) {
            _ = await send(
                pending.updateChannelID,
                "⚠️ Codex completed, but setting MARKETING_VERSION/CURRENT_PROJECT_VERSION failed in workspace."
            )
        }

        let status = await runShellCommand("git status --short", workingDirectory: pending.isolatedRepoPath)
        let diffStat = await runShellCommand("git diff --stat", workingDirectory: pending.isolatedRepoPath)
        let changedFilesRaw = await runShellCommand("git diff --name-only", workingDirectory: pending.isolatedRepoPath)
        let hasChanges = !status.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !hasChanges {
            finishBugAutoFixSession("No changes produced")
            _ = await send(pending.updateChannelID, "ℹ️ Auto-fix ran, but produced no git changes.")
            return
        }

        let compactStat = diffStat.combinedOutput
            .split(separator: "\n")
            .prefix(14)
            .joined(separator: "\n")
        let changedFiles = changedFilesRaw.combinedOutput
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let changedFilesSnippet: String = {
            guard !changedFiles.isEmpty else { return "(none listed)" }
            return changedFiles.prefix(10).map { "- \($0)" }.joined(separator: "\n")
        }()
        let codexWhy = codex.combinedOutput
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("$ ") && !$0.hasPrefix("exit ") }
            .suffix(8)
            .joined(separator: "\n")
        let whySnippet = codexWhy.isEmpty ? "Codex output did not include a concise summary." : codexWhy

        if settings.bugAutoFixPushEnabled && settings.bugAutoFixRequireApproval {
            pendingBugAutoFixApprovals[pending.bugMessageID] = BugAutoFixPendingApproval(
                bugMessageID: pending.bugMessageID,
                channelID: pending.channelID,
                guildID: pending.guildID,
                sourceRepoPath: pending.sourceRepoPath,
                isolatedRepoPath: pending.isolatedRepoPath,
                branch: pending.branch,
                updateChannelID: pending.updateChannelID,
                version: pending.version,
                build: pending.build
            )
            _ = await addReaction(channelId: pending.channelID, messageId: pending.bugMessageID, emoji: settings.bugAutoFixApproveEmoji)
            _ = await addReaction(channelId: pending.channelID, messageId: pending.bugMessageID, emoji: settings.bugAutoFixRejectEmoji)
            _ = await send(
                pending.updateChannelID,
                """
                🧠 Codex proposed changes for bug `\(pending.bugMessageID)`:
                **Target release:** `\(pending.version) (\(pending.build))`
                **Changed files:**
                ```text
                \(changedFilesSnippet)
                ```
                **Diff stat:**
                ```text
                \(compactStat.isEmpty ? "(no diff stat)" : compactStat)
                ```
                **Why / summary:**
                ```text
                \(String(whySnippet.suffix(1200)))
                ```
                React on the bug message with \(settings.bugAutoFixApproveEmoji) to commit+push, or \(settings.bugAutoFixRejectEmoji) to cancel.
                """
            )
            finishBugAutoFixSession("Waiting for push approval")
            return
        }

        if settings.bugAutoFixPushEnabled {
            await executeApprovedBugAutoFixPush(
                messageID: pending.bugMessageID,
                updateChannelID: pending.updateChannelID,
                repoPath: pending.isolatedRepoPath,
                branch: pending.branch,
                version: pending.version,
                build: pending.build
            )
        } else {
            finishBugAutoFixSession("Completed (isolated workspace only)")
            _ = await send(
                pending.updateChannelID,
                """
                ✅ Auto-fix completed in isolated workspace only (auto-push disabled).
                Release target: `\(pending.version) (\(pending.build))`
                Workspace: `\(pending.isolatedRepoPath)`
                """
            )
        }
    }

    func extractBugAutoFixReleaseInfo(channelID: String) async -> (version: String, build: String)? {
        let messages = await fetchRecentMessages(channelId: channelID, limit: 50)
        for message in messages {
            guard case let .string(content)? = message["content"] else { continue }
            if let parsed = parseBugAutoFixReleaseInfo(from: content) {
                return parsed
            }
        }
        return nil
    }

    func parseBugAutoFixReleaseInfo(from text: String) -> (version: String, build: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let versionRegex = try? NSRegularExpression(pattern: #"(?i)\bversion\s*[:=]\s*([0-9]+(?:\.[0-9]+){1,3})\b"#)
        let buildRegex = try? NSRegularExpression(pattern: #"(?i)\bbuild\s*[:=]\s*([0-9]{3,})\b"#)
        guard
            let versionMatch = versionRegex?.firstMatch(in: trimmed, range: fullRange),
            let buildMatch = buildRegex?.firstMatch(in: trimmed, range: fullRange),
            versionMatch.numberOfRanges >= 2,
            buildMatch.numberOfRanges >= 2
        else { return nil }

        let version = ns.substring(with: versionMatch.range(at: 1))
        let build = ns.substring(with: buildMatch.range(at: 1))
        return (version, build)
    }

    func createBugAutoFixWorkspaceClone(sourceRepoPath: String, branch: String, messageID: String) async -> String? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftbot-autofix", isDirectory: true)
        let workspaceURL = root.appendingPathComponent(
            "\(messageID)-\(Int(Date().timeIntervalSince1970))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            logs.append("Auto-fix workspace create failed: \(error.localizedDescription)")
            return nil
        }

        let command = "git clone --no-local --single-branch --branch \(shellQuote(branch)) \(shellQuote(sourceRepoPath)) \(shellQuote(workspaceURL.path))"
        let clone = await runShellCommand(command, workingDirectory: FileManager.default.currentDirectoryPath)
        guard clone.exitCode == 0 else {
            logs.append("Auto-fix clone failed: \(clone.combinedOutput)")
            return nil
        }
        return workspaceURL.path
    }

    func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runShellCommand(
        _ command: String,
        workingDirectory: String,
        environment: [String: String] = [:],
        outputSink: (@MainActor @Sendable (String) -> Void)? = nil
    ) async -> (exitCode: Int32, combinedOutput: String) {
        final class OutputBuffer: @unchecked Sendable {
            private let lock = NSLock()
            private var data = Data()

            func append(_ chunk: Data) {
                lock.lock()
                data.append(chunk)
                lock.unlock()
            }

            func snapshot() -> Data {
                lock.lock()
                let copy = data
                lock.unlock()
                return copy
            }
        }

        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

            var env = ProcessInfo.processInfo.environment
            environment.forEach { env[$0.key] = $0.value }
            process.environment = env

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            let captured = OutputBuffer()

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                captured.append(data)
                if let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty {
                    Task { @MainActor in
                        self?.appendBugAutoFixConsole(chunk)
                        outputSink?(chunk)
                    }
                }
            }

            appendBugAutoFixConsole("$ \(command)")
            outputSink?("$ \(command)\n")

            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                if !data.isEmpty { captured.append(data) }
                let text = String(data: captured.snapshot(), encoding: .utf8) ?? ""
                Task { @MainActor [weak self] in
                    self?.appendBugAutoFixConsole("exit \(proc.terminationStatus)")
                    outputSink?("exit \(proc.terminationStatus)\n")
                }
                continuation.resume(returning: (proc.terminationStatus, text))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (127, error.localizedDescription))
            }
        }
    }

    func normalizedReactionEmojiName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{FE0F}", with: "")
    }
}

// MARK: - AdvancedPreferencesView Original Card
/*
PreferencesCard("Bug Auto-Fix", systemImage: "sparkles") {
    VStack(alignment: .leading, spacing: 12) {
        settingsSubsectionTitle("Automation")
        settingsToggleRow("Enable Auto-Fix", isOn: $app.settings.bugAutoFixEnabled)
    }

    Divider()

    VStack(alignment: .leading, spacing: 8) {
        settingsSubsectionTitle("Trigger")
        Text("Trigger Emoji")
            .font(.subheadline.weight(.medium))
        TextField("🤖", text: $app.settings.bugAutoFixTriggerEmoji)
            .textFieldStyle(.roundedBorder)
        Text("React with this emoji on a tracked bug message to trigger Codex automation.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    Divider()

    VStack(alignment: .leading, spacing: 12) {
        settingsSubsectionTitle("Codex Integration")

        VStack(alignment: .leading, spacing: 8) {
            Text("Command Template")
                .font(.subheadline.weight(.medium))
            TextField("codex exec \"$SWIFTBOT_BUG_PROMPT\"", text: $app.settings.bugAutoFixCommandTemplate)
                .textFieldStyle(.roundedBorder)
            Text("Environment variables: SWIFTBOT_BUG_PROMPT, SWIFTBOT_BUG_CONTEXT_FILE, SWIFTBOT_REPO_PATH, SWIFTBOT_BUG_MESSAGE_ID, SWIFTBOT_BUG_CHANNEL_ID, SWIFTBOT_BUG_GUILD_ID")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Repository Path")
                .font(.subheadline.weight(.medium))
            TextField("/Users/max/Developer/SwiftBot", text: $app.settings.bugAutoFixRepoPath)
                .textFieldStyle(.roundedBorder)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Git Branch")
                .font(.subheadline.weight(.medium))
            TextField("main", text: $app.settings.bugAutoFixGitBranch)
                .textFieldStyle(.roundedBorder)
        }
    }

    Divider()

    VStack(alignment: .leading, spacing: 12) {
        settingsSubsectionTitle("Deployment")
        settingsToggleRow("Auto push to GitHub", isOn: $app.settings.bugAutoFixPushEnabled)
        settingsToggleRow("Require approval before push", isOn: $app.settings.bugAutoFixRequireApproval)
            .disabled(!app.settings.bugAutoFixPushEnabled)
    }

    Divider()

    VStack(alignment: .leading, spacing: 12) {
        settingsSubsectionTitle("Reactions")

        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Approve Emoji")
                    .font(.subheadline.weight(.medium))
                TextField("🚀", text: $app.settings.bugAutoFixApproveEmoji)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Reject Emoji")
                    .font(.subheadline.weight(.medium))
                TextField("🛑", text: $app.settings.bugAutoFixRejectEmoji)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    Divider()

    VStack(alignment: .leading, spacing: 8) {
        settingsSubsectionTitle("Restrictions")
        Text("Allowed Usernames")
            .font(.subheadline.weight(.medium))
        TextField(
            "Comma-separated usernames; leave blank for no restriction",
            text: Binding(
                get: { app.settings.bugAutoFixAllowedUsernames.joined(separator: ", ") },
                set: { raw in
                    app.settings.bugAutoFixAllowedUsernames = raw
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                        .filter { !$0.isEmpty }
                }
            )
        )
        .textFieldStyle(.roundedBorder)
    }

    Divider()

    VStack(alignment: .leading, spacing: 8) {
        settingsSubsectionTitle("Console")

        HStack {
            Text("Auto-Fix Console")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(app.bugAutoFixStatusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Clear") {
                app.bugAutoFixConsoleText = ""
            }
            .buttonStyle(.plain)
            .font(.caption)
        }

        ScrollView {
            Text(app.bugAutoFixConsoleText.isEmpty ? "No output yet." : app.bugAutoFixConsoleText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(10)
        }
        .frame(minHeight: 140, maxHeight: 200)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }
}
*/
