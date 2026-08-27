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
    static func buildReport(from app: AppModel, generatedAt: Date = Date()) async -> String {
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
        out += "lastGatewayEventDisplayName=\(GatewayEventPresentation.displayName(for: app.lastGatewayEventName))\n"
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
        out += "recentGatewayReconnects=\(cd.recentGatewayReconnects.count)\n"
        for reconnect in cd.recentGatewayReconnects {
            let closeCode = reconnect.closeCode.map(String.init) ?? "-"
            let reason = SwiftBotLogRedactor.redact(reconnect.reason)
            out += "gatewayReconnect at=\(iso.string(from: reconnect.at)) generation=\(reconnect.generation)"
            out += " delaySeconds=\(reconnect.delaySeconds) closeCode=\(closeCode) reason=\(reason)\n"
        }
        switch cd.restHealth {
        case .ok: out += "restHealth=ok\n"
        case .unknown: out += "restHealth=unknown\n"
        case let .error(code, msg): out += "restHealth=error(\(code), \(SwiftBotLogRedactor.redact(msg)))\n"
        }
        out += "\n"

        // Voice diagnostics are kept separately from the general system log,
        // which can otherwise be dominated by gateway reconnect entries and
        // hide the transition that made an announcer go silent.
        let voiceHealth = app.announcerHealth
        let manualHold = app.manualAnnouncerHold
        let breaker = app.announcerRecoveryCircuitBreaker
        out += "=== Voice Announcer ===\n"
        out += "connectionStatus=\(app.voiceConnectionStatus.displayLabel)\n"
        out += "phase=\(voiceHealth.phase.rawValue)\n"
        out += "queueDepth=\(voiceHealth.queueDepth)\n"
        out += "retryStreak=\(voiceHealth.retryStreak)\n"
        let activeConfig = app.settings.voice.announcerConfigs.first {
            $0.voiceChannelID == app.voicePendingChannelID
        }
        let activeConfigEnabled = activeConfig.map { String($0.enabled) } ?? "-"
        out += "pendingGuildID=\(SwiftBotLogRedactor.redact(app.voicePendingGuildID ?? "-"))\n"
        out += "pendingChannelID=\(SwiftBotLogRedactor.redact(app.voicePendingChannelID ?? "-"))\n"
        out += "activeConfiguration=\(SwiftBotLogRedactor.redact(activeConfig?.name ?? "-")) enabled=\(activeConfigEnabled)\n"
        out += "lastVoiceStateAt=\(app.lastVoiceStateAt.map { iso.string(from: $0) } ?? "-")\n"
        out += "lastVoiceStateSummary=\(SwiftBotLogRedactor.redact(app.lastVoiceStateSummary))\n"
        let recoveryDelays = app.voiceRecovery.schedule.map { duration in
            let components = duration.components
            let seconds = Double(components.seconds)
                + Double(components.attoseconds) / 1_000_000_000_000_000_000
            return String(format: "%.2fs", seconds)
        }.joined(separator: ",")
        out += "voiceRecoveryInProgress=\(app.voiceRecovery.inProgress) attempts=\(app.voiceRecovery.attemptsMade)/\(app.voiceRecovery.attemptsAllowed) schedule=\(recoveryDelays) stabilityWindowPending=\(app.voiceRecoveryStabilityTask != nil)\n"
        out += "voiceLeaveAckState=\(app.voiceLeaveAckState) preserveAnnouncerSession=\(app.voiceDisconnectPreservesAnnouncerSession) awaitingExternalDisconnectClosure=\(app.voiceRecoveryAwaitingExternalDisconnectClosure)\n"
        out += "pendingJoinIntroduction=\(app.pendingVoiceJoinIntro != nil)\n"
        if let manualHold {
            out += "manualHold=true expiresAt=\(iso.string(from: manualHold.expiresAt)) remainingSeconds=\(manualHold.remainingSeconds())\n"
        } else {
            out += "manualHold=false\n"
        }
        out += "recoveryCircuitBreakerOpen=\(breaker.isOpen) exhaustedAttempts=\(breaker.exhaustedAttempts)\n"
        out += "recoveryCircuitBreakerOpenedAt=\(breaker.openedAt.map { iso.string(from: $0) } ?? "-") resumesAt=\(breaker.resumesAt.map { iso.string(from: $0) } ?? "-")\n"
        out += "recoveryCircuitBreakerReason=\(SwiftBotLogRedactor.redact(breaker.reason ?? "-"))\n"
        out += "lastQueuedAt=\(voiceHealth.lastQueuedAt.map { iso.string(from: $0) } ?? "-")\n"
        out += "lastSpokenAt=\(voiceHealth.lastSpokenAt.map { iso.string(from: $0) } ?? "-")\n"
        out += "lastFailureAt=\(voiceHealth.lastFailureAt.map { iso.string(from: $0) } ?? "-")\n"
        out += "lastFailureReason=\(SwiftBotLogRedactor.redact(voiceHealth.lastFailureReason ?? "-"))\n"
        out += "\n"

        let transportDiagnostics: VoicePlaybackService.DiagnosticsSnapshot? = if let playback = app.voicePlaybackServiceStorage {
            await playback.diagnosticsSnapshot()
        } else {
            nil
        }
        out += "=== Voice Transport ===\n"
        if let transportDiagnostics {
            let stagedTransitions = transportDiagnostics.davePendingTransitionIds
                .map(String.init)
                .joined(separator: ",")
            let averageAudioEncodeMilliseconds = transportDiagnostics.averageAudioEncodeMilliseconds
                .map { String(format: "%.3f", $0) } ?? "-"
            let audioMetrics = [
                "opusProfile=\(transportDiagnostics.opusProfile)",
                "encodedPackets=\(transportDiagnostics.encodedAudioPacketCount)",
                "encodedBytes=\(transportDiagnostics.encodedAudioByteCount)",
                "encodeFailures=\(transportDiagnostics.audioEncodeFailureCount)",
                "sendFailures=\(transportDiagnostics.audioSendFailureCount)",
                "averageEncodeMilliseconds=\(averageAudioEncodeMilliseconds)",
                "worstQueueDelayMilliseconds=\(String(format: "%.3f", transportDiagnostics.worstAudioQueueDelayMilliseconds))",
            ].joined(separator: " ")
            out += "status=\(transportDiagnostics.status)\n"
            out += "connectionGeneration=\(transportDiagnostics.connectionGeneration)\n"
            out += "lastSuccessfulConnectionGeneration=\(transportDiagnostics.lastSuccessfulConnectionGeneration.map(String.init) ?? "-")\n"
            out += "lastFailureGeneration=\(transportDiagnostics.lastFailureGeneration.map(String.init) ?? "-")\n"
            out += "lastFailureHistorical=\(transportDiagnostics.lastFailureIsHistorical)\n"
            out += "lastFailureReason=\(SwiftBotLogRedactor.redact(transportDiagnostics.lastFailureReason ?? "-"))\n"
            out += "gateway=\(transportDiagnostics.hasGateway) transport=\(transportDiagnostics.hasTransport) encryption=\(transportDiagnostics.hasEncryption) opus=\(transportDiagnostics.hasOpusEncoder) ssrc=\(transportDiagnostics.hasSSRC)\n"
            out += "isSpeaking=\(transportDiagnostics.isSpeaking) speakingElapsedSeconds=\(transportDiagnostics.speakingElapsedSeconds.map { String(format: "%.2f", $0) } ?? "-") firstAudioFrameSent=\(transportDiagnostics.didSendFirstAudioFrame)\n"
            out += "connectionEstablishedAt=\(transportDiagnostics.connectionEstablishedAt.map { iso.string(from: $0) } ?? "-")\n"
            out += "lastAudioFrameSentAt=\(transportDiagnostics.lastAudioFrameSentAt.map { iso.string(from: $0) } ?? "-") mediaIdleSeconds=\(transportDiagnostics.mediaIdleSeconds.map { String(format: "%.1f", $0) } ?? "-")\n"
            out += "recoveredDaveIdleRefreshArmed=\(transportDiagnostics.recoveredDaveIdleRefreshArmed) thresholdSeconds=\(transportDiagnostics.recoveredDaveIdleRefreshThresholdSeconds)\n"
            out += "\(audioMetrics)\n"
            out += "keepaliveCounter=\(transportDiagnostics.keepaliveCounter) failures=\(transportDiagnostics.keepaliveFailures) evidence=local-send-only\n"
            out += "lastKeepaliveAttemptAt=\(transportDiagnostics.lastKeepaliveAttemptAt.map { iso.string(from: $0) } ?? "-")\n"
            out += "lastKeepaliveSuccessAt=\(transportDiagnostics.lastKeepaliveSuccessAt.map { iso.string(from: $0) } ?? "-")\n"
            out += "lastKeepaliveFailureAt=\(transportDiagnostics.lastKeepaliveFailureAt.map { iso.string(from: $0) } ?? "-")\n"
            out += "lastKeepaliveFailureReason=\(SwiftBotLogRedactor.redact(transportDiagnostics.lastKeepaliveFailureReason ?? "-"))\n"
            out += "awaitingVoiceResume=\(transportDiagnostics.awaitingVoiceResume) resumeAttemptsRemaining=\(transportDiagnostics.voiceResumeAttemptsRemaining)\n"
            out += "pathRecoveryRequested=\(transportDiagnostics.pathRecoveryRequested) pathRecoveryBudgetRemaining=\(transportDiagnostics.networkPathRecoveryBudgetRemaining)\n"
            out += "daveRequired=\(transportDiagnostics.daveMediaRequired) daveGatePending=\(transportDiagnostics.daveTransitionGatePending) daveMediaContextGeneration=\(transportDiagnostics.daveMediaContextGeneration)\n"
            out += "daveDowngradeTransitionId=\(transportDiagnostics.pendingDaveDowngradeTransitionId.map(String.init) ?? "-") daveSoleMemberReset=\(transportDiagnostics.pendingDaveSoleMemberReset)\n"
            out += "daveSessionGeneration=\(transportDiagnostics.daveSessionGeneration.map(String.init) ?? "-") protocolVersion=\(transportDiagnostics.daveProtocolVersion.map(String.init) ?? "-") handshake=\(transportDiagnostics.daveHandshakeState ?? "-") mediaReady=\(transportDiagnostics.daveMediaReady.map(String.init) ?? "-")\n"
            out += "daveAppliedTransitions=\(transportDiagnostics.daveAppliedTransitionCount.map(String.init) ?? "-") pendingEpoch=\(transportDiagnostics.davePendingEpoch.map(String.init) ?? "-") pendingTransition=\(transportDiagnostics.davePendingTransitionId.map(String.init) ?? "-") activeTransition=\(transportDiagnostics.daveActiveTransitionId.map(String.init) ?? "-")\n"
            out += "daveStagedTransitions=\(stagedTransitions.isEmpty ? "-" : stagedTransitions) pendingOutboundActions=\(transportDiagnostics.davePendingOutboundActionCount.map(String.init) ?? "-") lastRecoveryAction=\(transportDiagnostics.daveLastRecoveryAction ?? "-")\n"
            out += "daveExternalSenderState=\(transportDiagnostics.daveExternalSenderState ?? "-") rosterMembers=\(transportDiagnostics.daveRosterMemberCount.map(String.init) ?? "-") unrecognizedRosterMembers=\(transportDiagnostics.daveUnrecognizedRosterUserIds.count) evictedTransitions=\(transportDiagnostics.daveEvictedTransitionCount.map(String.init) ?? "-")\n"
            if !transportDiagnostics.daveUnrecognizedRosterUserIds.isEmpty {
                out += "daveUnrecognizedRosterUserIds=\(SwiftBotLogRedactor.redact(transportDiagnostics.daveUnrecognizedRosterUserIds.joined(separator: ",")))\n"
            }
            out += "daveLastFailureCode=\(transportDiagnostics.daveLastFailureCode ?? "-") origin=\(transportDiagnostics.daveLastFailureOrigin ?? "-") historical=\(transportDiagnostics.daveLastFailureIsHistorical) nativeSource=\(SwiftBotLogRedactor.redact(transportDiagnostics.daveLastFailureNativeSource ?? "-")) nativeReason=\(SwiftBotLogRedactor.redact(transportDiagnostics.daveLastFailureNativeReason ?? "-"))\n"
            out += "daveLastTransitionAt=\(transportDiagnostics.daveLastTransitionAt.map { iso.string(from: $0) } ?? "-")\n"
            out += "daveEncryptSuccesses=\(transportDiagnostics.daveEncryptionSuccessCount.map(String.init) ?? "-") failures=\(transportDiagnostics.daveEncryptionFailureCount.map(String.init) ?? "-")\n"
            out += "daveLastMlsError=\(SwiftBotLogRedactor.redact(transportDiagnostics.daveLastMlsError ?? "-"))\n"
            out += "daveTraceEvents=\(transportDiagnostics.daveRecentEvents.count)\n"
            for event in transportDiagnostics.daveRecentEvents {
                let transition = event.transitionId.map(String.init) ?? "-"
                let failure = event.failure.map { "\($0.code.rawValue)/\($0.origin.rawValue)" } ?? "-"
                out += "daveTrace id=\(event.id) at=\(iso.string(from: event.timestamp)) generation=\(event.sessionGeneration) kind=\(event.kind.rawValue) outcome=\(event.outcome.rawValue) transition=\(transition) mediaReady=\(event.mediaReady) recovery=\(event.recoveryHint.rawValue) failure=\(failure) detail=\(SwiftBotLogRedactor.redact(event.detail ?? "-"))\n"
            }
        } else {
            out += "state=not initialized\n"
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

        out += "\n-- Voice Log (most recent 200) --\n"
        let voiceEntries = app.voiceLog.prefix(200)
        if voiceEntries.isEmpty {
            out += "(none)\n"
        } else {
            for entry in voiceEntries {
                out += "[\(iso.string(from: entry.time))] \(SwiftBotLogRedactor.redact(entry.description))\n"
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

    /// Builds a compact, redacted report for diagnosing Announcer failures.
    /// It deliberately derives its payload from the full report so new voice
    /// fields and redaction rules cannot diverge between the two export paths.
    @MainActor
    static func buildAnnouncerReport(from app: AppModel, generatedAt: Date = Date()) async -> String {
        let fullReport = await buildReport(from: app, generatedAt: generatedAt)
        // These markers must be real newlines. Written as "\\n" they matched a
        // literal backslash-n, every slice failed, and the bundle silently fell
        // back to the full report — shipping settings and the system log in an
        // export whose whole purpose is to exclude them.
        guard let header = reportSlice(
            in: fullReport,
            from: "=== SwiftBot Diagnostic Report ===\n",
            upTo: "=== Bot Runtime ===\n"
        ), let voice = reportSlice(
            in: fullReport,
            from: "=== Voice Announcer ===\n",
            upTo: "=== SwiftMesh ===\n"
        ), let voiceLog = reportSlice(
            in: fullReport,
            from: "-- Voice Log (most recent 200) --\n",
            upTo: "-- System Log (most recent 500 lines) --\n"
        ) else {
            return fullReport
        }

        var out = header.replacingOccurrences(
            of: "=== SwiftBot Diagnostic Report ===",
            with: "=== SwiftBot Announcer Diagnostic Report ==="
        )
        out += "\n"
        out += voice
        out += "\n"
        out += voiceLog
        return out
    }

    private static func reportSlice(in report: String, from start: String, upTo end: String) -> String? {
        guard let startRange = report.range(of: start),
              let endRange = report.range(of: end, range: startRange.upperBound..<report.endIndex) else {
            return nil
        }
        return String(report[startRange.lowerBound..<endRange.lowerBound])
    }

    /// Presents SwiftMiner's export flow: first a small, window-attached progress
    /// sheet while potentially slow diagnostics are gathered, then a save sheet.
    @MainActor
    static func presentSavePanel(app: AppModel) async {
        await presentSavePanel(app: app, export: .full)
    }

    /// Saves a smaller, Announcer-only diagnostic bundle for sharing directly
    /// after a silent stop or unexpected voice disconnect.
    @MainActor
    static func presentAnnouncerSavePanel(app: AppModel) async {
        await presentSavePanel(app: app, export: .announcer)
    }

    private enum DiagnosticExport {
        case full
        case announcer

        var filename: (Date) -> String {
            switch self {
            case .full: { LogExporter.defaultFilename(for: $0) }
            case .announcer: { LogExporter.defaultAnnouncerFilename(for: $0) }
            }
        }

        var panelTitle: String {
            switch self {
            case .full: "Export Diagnostic Logs"
            case .announcer: "Export Announcer Diagnostics"
            }
        }

        var panelMessage: String {
            switch self {
            case .full: "Save a redacted SwiftBot diagnostic report you can attach to a GitHub issue."
            case .announcer: "Save a focused, redacted Announcer report to help investigate voice issues."
            }
        }

        var progressDetail: String {
            switch self {
            case .full: "Collecting Announcer, Discord voice, and activity data. This can take a moment for a large log."
            case .announcer: "Collecting Announcer state, Discord voice transport health, and the recent voice flight recorder."
            }
        }
    }

    @MainActor
    private static func presentSavePanel(app: AppModel, export: DiagnosticExport) async {
        let progressSheet = presentProgressSheet(title: export.panelTitle, detail: export.progressDetail)
        defer { dismiss(progressSheet) }

        // Give AppKit a chance to display feedback before awaiting actor-backed
        // voice/DAVE diagnostics and redacting a potentially large activity log.
        await Task.yield()
        let generatedAt = Date()
        let report = switch export {
        case .full:
            await buildReport(from: app, generatedAt: generatedAt)
        case .announcer:
            await buildAnnouncerReport(from: app, generatedAt: generatedAt)
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = export.filename(generatedAt)
        panel.title = export.panelTitle
        panel.message = export.panelMessage
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard await present(panel) == .OK, let url = panel.url else { return }

        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save diagnostics"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// A save panel started from a SwiftUI command needs a window-attached sheet
    /// on current macOS releases. `runModal()` can return without presenting in
    /// that context, which made exporting look like a no-op.
    @MainActor
    private static func present(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
            return panel.runModal()
        }

        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }

    private struct ProgressSheet {
        let panel: NSPanel
        let parentWindow: NSWindow?
        let symbolCycler: DiagnosticsSymbolCycler
    }

    /// Displays immediately while the report is snapshotted, redacted, and
    /// formatted, avoiding an export action that appears to have been ignored.
    @MainActor
    private static func presentProgressSheet(title: String, detail: String) -> ProgressSheet {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 154),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let content = NSView(frame: panel.contentView?.bounds ?? .zero)

        let symbolCycler = DiagnosticsSymbolCycler(frame: NSRect(x: 27, y: 71, width: 30, height: 30))
        content.addSubview(symbolCycler)

        let titleLabel = NSTextField(labelWithString: "Preparing diagnostics…")
        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 74, y: 90, width: 272, height: 22)
        content.addSubview(titleLabel)

        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        detailLabel.frame = NSRect(x: 74, y: 42, width: 272, height: 40)
        content.addSubview(detailLabel)

        panel.contentView = content
        symbolCycler.start()

        if let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow {
            parentWindow.beginSheet(panel)
            return ProgressSheet(panel: panel, parentWindow: parentWindow, symbolCycler: symbolCycler)
        }

        panel.center()
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        return ProgressSheet(panel: panel, parentWindow: nil, symbolCycler: symbolCycler)
    }

    @MainActor
    private static func dismiss(_ progressSheet: ProgressSheet) {
        progressSheet.symbolCycler.stop()
        if let parentWindow = progressSheet.parentWindow {
            parentWindow.endSheet(progressSheet.panel)
        } else {
            progressSheet.panel.orderOut(nil)
        }
    }

    static func defaultFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SwiftBot-logs-\(formatter.string(from: date)).txt"
    }

    static func defaultAnnouncerFilename(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "SwiftBot-announcer-diagnostics-\(formatter.string(from: date)).txt"
    }
}

/// Cycles through relevant symbols while diagnostics are prepared, providing
/// the same visible activity cue as SwiftMiner's diagnostics export sheet.
private final class DiagnosticsSymbolCycler: NSImageView {
    private let symbols: [(name: String, color: NSColor)] = [
        ("speaker.wave.2.fill", .systemBlue),
        ("waveform", .systemPurple),
        ("antenna.radiowaves.left.and.right", .systemIndigo),
        ("text.bubble.fill", .systemTeal)
    ]
    private var symbolIndex = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel("Preparing diagnostics")
        updateSymbol()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func start() {
        guard timer == nil else { return }

        let timer = Timer(
            timeInterval: 0.65,
            target: self,
            selector: #selector(advanceSymbol),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func advanceSymbol() {
        symbolIndex = (symbolIndex + 1) % symbols.count
        updateSymbol()
    }

    private func updateSymbol() {
        let symbol = symbols[symbolIndex]
        contentTintColor = symbol.color
        image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: "Preparing diagnostics")
    }

}
