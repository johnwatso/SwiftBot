import AppKit
import Foundation
import UniformTypeIdentifiers

/// Scrubs Discord/cluster secrets and PII from a SwiftBot log export so the
/// resulting file can safely be attached to a GitHub issue or pasted into a
/// Claude conversation. Adapted from SwiftMiner's `LogRedactor` and tuned
/// for the secret shapes SwiftBot actually carries.
enum SwiftBotLogRedactor {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
        init(_ pattern: String, _ replacement: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
            self.pattern = pattern
            self.replacement = replacement
            self.options = options
        }
    }

    private static let rules: [Rule] = [
        // Discord bot token: 3 base64-ish segments separated by dots, prefixed
        // by "Bot " in REST headers. Match both with and without prefix.
        Rule(#"Bot\s+[A-Za-z0-9_\-\.]{40,}"#, "Bot <discord-token>"),
        Rule(#"\b[MN][A-Za-z0-9_\-]{23,}\.[A-Za-z0-9_\-]{6,}\.[A-Za-z0-9_\-]{27,}\b"#, "<discord-token>"),

        // Discord webhook URL: contains an integer ID and a long b64 secret.
        Rule(#"https?://(?:[a-z0-9.-]*\.)?discord(?:app)?\.com/api/webhooks/\d+/[A-Za-z0-9_\-]+"#, "https://discord.com/api/webhooks/<redacted>"),

        // OAuth-style "oauth:xxx" (from copy/paste of Twitch/IRC-style tokens).
        Rule(#"oauth:[A-Za-z0-9_\-]+"#, "oauth:<redacted>"),

        // Bearer authorization headers.
        Rule(#"Bearer\s+[A-Za-z0-9_\-\.=]+"#, "Bearer <redacted>"),

        // JWT-shaped tokens (three base64url segments).
        Rule(#"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\b"#, "<jwt-redacted>"),

        // OpenAI API key (sk-… ~48+ chars). Anthropic keys (sk-ant-…) caught by the same prefix.
        Rule(#"\bsk-(?:ant-)?[A-Za-z0-9_\-]{20,}\b"#, "<api-key>"),

        // Cluster shared-secret HMAC signature headers.
        Rule(#"(X-SwiftBot-(?:Signature|Nonce|Timestamp))\s*[:=]\s*\S+"#, "$1: <redacted>"),

        // Email addresses.
        Rule(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "<email>"),

        // Discord snowflakes following a hint keyword (id, user, channel, guild).
        Rule(#"(discord[_\-]?(?:id|user)?|guild[_\-]?id|channel[_\-]?id|user[_\-]?id)[=:\s]+\d{16,20}"#, "$1=<discord-id>"),

        // Generic 40+ char hex/base64 token-ish runs that look like secrets.
        // Last so the specific rules above win.
        Rule(#"\b[A-Za-z0-9]{40,}\b"#, "<redacted-token>", [])
    ]

    private static let compiled: [(NSRegularExpression, String)] = rules.compactMap {
        guard let r = try? NSRegularExpression(pattern: $0.pattern, options: $0.options) else { return nil }
        return (r, $0.replacement)
    }

    static func redact(_ input: String) -> String {
        var result = input
        for (regex, replacement) in compiled {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: replacement)
        }
        return result
    }
}

/// Builds a single plain-text diagnostic report covering app version, bot
/// status, cluster state, connection diagnostics, settings (with secrets
/// scrubbed), and the in-memory activity log. Designed to be attached to a
/// GitHub issue or pasted into a debugging conversation.
enum LogExporter {

    @MainActor
    static func buildReport(from app: AppModel, generatedAt: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let arch: String = {
            var sysinfo = utsname()
            guard uname(&sysinfo) == 0 else { return "unknown" }
            return withUnsafePointer(to: &sysinfo.machine) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                    String(cString: $0)
                }
            }
        }()

        var out = ""
        out += "=== SwiftBot Diagnostic Report ===\n"
        out += "Generated: \(iso.string(from: generatedAt))\n"
        out += "App: \(version) (build \(build))\n"
        out += "OS: \(osVersion) · arch \(arch)\n"
        out += "\n"

        // Bot runtime
        out += "=== Bot Runtime ===\n"
        out += "status=\(app.status.rawValue)\n"
        out += "uptime=\(app.uptime?.text ?? "-")\n"
        out += "username=\(app.botUsername)\n"
        out += "botUserId=\(app.botUserId ?? "-")\n"
        out += "gatewayEvents=\(app.gatewayEventCount)\n"
        out += "readyEvents=\(app.readyEventCount)\n"
        out += "guildCreates=\(app.guildCreateEventCount)\n"
        out += "voiceStateEvents=\(app.voiceStateEventCount)\n"
        out += "lastGatewayEvent=\(app.lastGatewayEventName)\n"
        out += "intentsAccepted=\(app.intentsAccepted.map(String.init(describing:)) ?? "unknown")\n"
        out += "\n"

        // Connection diagnostics
        out += "=== Connection Diagnostics ===\n"
        let cd = app.connectionDiagnostics
        out += "heartbeatLatencyMs=\(cd.heartbeatLatencyMs.map(String.init) ?? "-")\n"
        out += "rateLimitRemaining=\(cd.rateLimitRemaining.map(String.init) ?? "-")\n"
        out += "lastGatewayCloseCode=\(cd.lastGatewayCloseCode.map(String.init) ?? "-")\n"
        out += "lastTestMessage=\(cd.lastTestMessage.isEmpty ? "-" : SwiftBotLogRedactor.redact(cd.lastTestMessage))\n"
        out += "lastTestAt=\(cd.lastTestAt.map { iso.string(from: $0) } ?? "-")\n"
        switch cd.restHealth {
        case .ok: out += "restHealth=ok\n"
        case .unknown: out += "restHealth=unknown\n"
        case let .error(code, msg): out += "restHealth=error(\(code), \(SwiftBotLogRedactor.redact(msg)))\n"
        }
        out += "\n"

        // Cluster / SwiftMesh
        out += "=== SwiftMesh ===\n"
        let cs = app.clusterSnapshot
        out += "configuredMode=\(app.settings.clusterMode.rawValue)\n"
        out += "runtimeMode=\(cs.mode.rawValue)\n"
        out += "nodeName=\(cs.nodeName)\n"
        out += "leaderAddress=\(cs.leaderAddress.isEmpty ? "-" : cs.leaderAddress)\n"
        out += "listenPort=\(cs.listenPort)\n"
        out += "leaderTerm=\(cs.leaderTerm)\n"
        out += "serverState=\(cs.serverState.rawValue) · \(cs.serverStatusText)\n"
        out += "workerState=\(cs.workerState.rawValue) · \(cs.workerStatusText)\n"
        out += "diagnostics=\(SwiftBotLogRedactor.redact(cs.diagnostics))\n"
        out += "lastJobRoute=\(cs.lastJobRoute.rawValue)\n"
        out.append("lastJobNode=\(cs.lastJobNode)\n")
        out += "lastJobSummary=\(SwiftBotLogRedactor.redact(cs.lastJobSummary))\n"
        out += "registeredWorkers=\(app.registeredWorkersDebugCount) (\(SwiftBotLogRedactor.redact(app.registeredWorkersDebugSummary)))\n"
        out += "autoReclaimAfterHours=\(app.settings.clusterAutoReclaimAfterHours)\n"
        out += "autoReclaimRemainingSecs=\(app.autoReclaimRemainingSeconds.map { "\(Int($0))" } ?? "-")\n"
        if cs.followerStates.isEmpty {
            out += "followerStates=(none)\n"
        } else {
            out += "followerStates (\(cs.followerStates.count)):\n"
            for (key, state) in cs.followerStates.sorted(by: { $0.value.nodeName < $1.value.nodeName }) {
                out += "  - \(state.nodeName) @ \(SwiftBotLogRedactor.redact(key))\n"
                out += "    mode=\(state.mode) term=\(state.leaderTerm) gatewayConnected=\(state.gatewayConnected) outputAllowed=\(state.outputAllowed)\n"
                out += "    discordLatencyMs=\(state.discordGatewayLatencyMs.map(String.init) ?? "-") activeVoice=\(state.activeVoiceMembers)\n"
                out += "    lastEventAt=\(state.lastEventAt.map { iso.string(from: $0) } ?? "-")\n"
                out += "    collectedAt=\(iso.string(from: state.collectedAt))\n"
            }
        }
        out += "\n"

        // Cluster nodes (what /cluster/status reports)
        out += "=== Cluster Nodes (\(app.clusterNodes.count)) ===\n"
        if app.clusterNodes.isEmpty {
            out += "(none)\n"
        } else {
            for node in app.clusterNodes {
                out += "[\(node.displayName)] role=\(node.role.rawValue) status=\(node.status.rawValue) host=\(SwiftBotLogRedactor.redact(node.hostname))\n"
                out += "  hw=\(node.hardwareModel) cpu=\(node.cpu)% mem=\(node.mem)% uptime=\(Int(node.uptime))s\n"
                out += "  latencyMs=\(node.latencyMs.map { "\(Int($0))" } ?? "-") jobsActive=\(node.jobsActive)\n"
            }
        }
        out += "\n"

        // Settings (secrets explicitly excluded)
        out += "=== Settings (secrets excluded) ===\n"
        let s = app.settings
        let rows: [(String, String)] = [
            ("clusterMode", s.clusterMode.rawValue),
            ("clusterNodeName", s.clusterNodeName),
            ("clusterLeaderAddress", s.clusterLeaderAddress),
            ("clusterLeaderPort", "\(s.clusterLeaderPort)"),
            ("clusterListenPort", "\(s.clusterListenPort)"),
            ("clusterSharedSecret", s.clusterSharedSecret.isEmpty ? "<empty>" : "<set:\(s.clusterSharedSecret.count) chars>"),
            ("clusterLeaderTerm", "\(s.clusterLeaderTerm)"),
            ("clusterWorkerOffloadEnabled", "\(s.clusterWorkerOffloadEnabled)"),
            ("clusterOffloadAIReplies", "\(s.clusterOffloadAIReplies)"),
            ("clusterOffloadWikiLookups", "\(s.clusterOffloadWikiLookups)"),
            ("clusterAutoReclaimAfterHours", "\(s.clusterAutoReclaimAfterHours)"),
            ("autoStart", "\(s.autoStart)"),
            ("tokenSet", s.token.isEmpty ? "false" : "true(\(s.token.count) chars)")
        ]
        for (k, v) in rows {
            out += "\(k)=\(SwiftBotLogRedactor.redact(v))\n"
        }
        out += "\n"

        // Activity log (newest first to match the UI ordering)
        out += "=== Activity Log (\(app.logs.lines.count) system lines, \(app.commandLog.count) commands) ===\n"
        out += "-- Command Log (most recent 200) --\n"
        let commands = app.commandLog.suffix(200)
        if commands.isEmpty {
            out += "(none)\n"
        } else {
            for c in commands {
                let ts = iso.string(from: c.time)
                let status = c.ok ? "OK" : "ERR"
                out += "\(ts)  \(status)  \(SwiftBotLogRedactor.redact(c.user)) · \(SwiftBotLogRedactor.redact(c.server)) · \(SwiftBotLogRedactor.redact(c.channel)) · route=\(c.executionRoute) on=\(c.executionNode) · \(SwiftBotLogRedactor.redact(c.command))\n"
            }
        }
        out += "\n-- System Log (most recent 500 lines) --\n"
        let lines = app.logs.lines.suffix(500)
        if lines.isEmpty {
            out += "(none)\n"
        } else {
            for line in lines {
                out += SwiftBotLogRedactor.redact(line) + "\n"
            }
        }

        return out
    }

    @MainActor
    static func presentSavePanel(app: AppModel) {
        let generatedAt = Date()
        let report = buildReport(from: app, generatedAt: generatedAt)

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultFilename(for: generatedAt)
        panel.title = "Export Diagnostic Logs"
        panel.message = "Save a redacted SwiftBot diagnostic report. Discord tokens, mesh secrets, API keys, snowflakes, and emails are scrubbed."
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save diagnostic logs"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    static func defaultFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SwiftBot-logs-\(formatter.string(from: date)).txt"
    }
}
