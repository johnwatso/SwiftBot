import Foundation
import SwiftUI
import AppKit

extension AppModel {

    // MARK: - Bot Lifecycle

    func startBot() async {
        if isRemoteLaunchMode {
            await MainActor.run {
                logs.append("⚠️ Remote Control Mode does not start a local Discord bot.")
            }
            return
        }

        // Worker mode is temporarily disabled pending UX redesign.
        // The underlying code is preserved; re-enable by removing this guard when ready.
        if settings.clusterMode == .worker {
            await MainActor.run {
                logs.append("⚠️ Worker mode is temporarily unavailable. Select Standalone, Primary, or Fail Over in Settings.")
            }
            return
        }

        await cluster.applySettings(
            mode: settings.clusterMode,
            nodeName: settings.clusterNodeName,
            leaderAddress: settings.clusterLeaderAddress,
            leaderPort: settings.clusterLeaderPort,
            listenPort: settings.clusterListenPort,
            sharedSecret: settings.clusterSharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )
        await cluster.setOffloadPolicy(
            aiReplies: settings.clusterOffloadAIReplies,
            wikiLookups: settings.clusterOffloadWikiLookups
        )
        configureMeshSync()

        let runtimeMode = await cluster.currentSnapshot().mode
        if runtimeMode == .standby {
            // Block all Discord output — standby observes events for live dashboard
            // but must not respond until promoted to Primary.
            await service.setOutputAllowed(false)
            logs.append("Fail Over mode active. Connecting to Discord in passive mode; live work remains delegated/primary-only.")
        }

        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }

        guard !normalizedToken.isEmpty else {
            logs.append("⚠️ Token is empty; cannot start bot")
            return
        }

        await connectDiscordInternal()
        startMediaMonitor()
    }

    func connectDiscordAfterPromotion() async {
        // Allow output immediately — the gateway connection is already live if this
        // node was running in standby (passive) mode. Avoid reconnecting if already
        // connected to prevent the brief downtime a disconnect/reconnect would cause.
        await service.setOutputAllowed(true)

        if status == .running {
            // Already connected and receiving events — just flip the output gate.
            logs.append("✅ Output enabled. Now responding as Primary.")
            return
        }

        // Not yet connected (e.g. fresh start without prior standby connection).
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }
        guard !normalizedToken.isEmpty else { return }
        await connectDiscordInternal()
    }

    func connectDiscordInternal() async {
        if !serviceCallbacksConfigured {
            await configureServiceCallbacks()
        }

        let token = normalizedDiscordToken(from: settings.token)
        if settings.token != token {
            settings.token = token
        }
        guard !token.isEmpty else {
            logs.append("⚠️ Token is empty; cannot connect")
            status = .stopped
            return
        }

        let tokenValidation = await identityRESTClient.validateBotTokenRich(token)
        lastTokenValidationResult = tokenValidation
        guard tokenValidation.isValid else {
            status = .stopped
            logs.append("❌ Token validation failed: \(tokenValidation.errorMessage)")
            return
        }
        applyBotIdentity(from: tokenValidation)

        status = .connecting
        uptime = UptimeInfo(startedAt: Date())
        await clearVoicePresence()
        patchyTargetValidationCache.removeAll()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        gatewayEventCount = 0
        voiceStateEventCount = 0
        readyEventCount = 0
        guildCreateEventCount = 0
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        startUptimeTicker()

        let weekly = WeeklySummaryPlugin()
        self.weeklyPlugin = weekly
        Task { await pluginManager.add(weekly) }

        await service.connect(token: token)
        logs.append("Connecting to Discord Gateway")
    }

    private func applyBotIdentity(from validation: DiscordService.TokenValidationResult) {
        if let userId = validation.userId, !userId.isEmpty {
            botUserId = userId
        }
        if let username = validation.username, !username.isEmpty {
            botUsername = username
        }
        if let discriminator = validation.discriminator,
           !discriminator.isEmpty,
           discriminator != "0" {
            botDiscriminator = discriminator
        } else {
            botDiscriminator = nil
        }
        if let avatarURL = validation.avatarURL {
            let filename = avatarURL.deletingPathExtension().lastPathComponent
            botAvatarHash = filename.isEmpty ? nil : filename
        } else {
            botAvatarHash = nil
        }
    }

    // MARK: - Onboarding integration

    /// Validates the current token, resolves the OAuth2 client ID, and stores results for
    /// the onboarding UI. Returns `true` on success. Does NOT flip `isOnboardingComplete` —
    /// call `completeOnboarding()` after the user gives explicit confirmation.
    @discardableResult
    func validateAndOnboard() async -> Bool {
        settings.launchMode = .standaloneBot
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else { return false }
        let result = await identityRESTClient.validateBotTokenRich(token)
        lastTokenValidationResult = result
        guard result.isValid else { return false }
        let cid = await resolveClientID(token: token, fallbackUserID: result.userId)
        resolvedClientID = cid
        return true
    }

    /// Flips the onboarding gate after the user has explicitly confirmed they want to proceed.
    /// Persists settings through the Keychain path, then flips `isOnboardingComplete`.
    /// Must only be called after a successful `validateAndOnboard()`.
    func completeOnboarding() {
        viewMode = .local
        saveSettings()
        isOnboardingComplete = true
    }

    func completeRemoteModeOnboarding(primaryNodeAddress: String, accessToken: String) {
        settings.launchMode = .remoteControl
        settings.remoteMode = RemoteModeSettings(
            primaryNodeAddress: primaryNodeAddress,
            accessToken: accessToken
        )
        settings.remoteMode.normalize()
        viewMode = .remote
        saveSettings()
        isOnboardingComplete = true
    }

    /// Handles OAuth session token received via deep link for remote authentication.
    /// Stores the session token in Keychain and updates remote mode settings.
    func handleRemoteAuthSession(_ sessionToken: String) {
        // Store session token in Keychain for secure persistence
        KeychainHelper.save(sessionToken, account: "remote-session-token")

        // Update the remote mode settings with the session token
        var currentMode = settings.remoteMode
        currentMode.accessToken = sessionToken
        settings.remoteMode = currentMode
        saveSettings()

        // Post notification so UI can react to successful auth
        NotificationCenter.default.post(name: .remoteAuthSessionReceived, object: sessionToken)
    }

    func updateRemoteModeConnection(primaryNodeAddress: String, accessToken: String) {
        settings.remoteMode = RemoteModeSettings(
            primaryNodeAddress: primaryNodeAddress,
            accessToken: accessToken
        )
        settings.remoteMode.normalize()
        saveSettings()
    }

    /// Performs a safe API key reset with deterministic ordering:
    /// 1. Awaits gateway disconnect (cancels reconnect task, sets userInitiatedDisconnect).
    /// 2. Clears all bot runtime state.
    /// 3. Clears the token and persists via the Keychain-backed path (disk settings.json stays redacted).
    /// 4. Clears invite/token validation cache so setup can be run again on demand.
    func clearAPIKey() async {
        // Step 1: deterministic gateway disconnect — awaited before any state mutation.
        await service.disconnect()
        // Step 2: clear runtime state (mirrors stopBot without fire-and-forget disconnect).
        uptimeTask?.cancel()
        uptime = nil
        await clearVoicePresence()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        Task { await pluginManager.removeAll() }
        Task { await cluster.stopAll() }
        status = .stopped
        // Step 3: secure token erase — empty token triggers KeychainHelper.deleteToken() in ConfigStore.
        settings.token = ""
        saveSettings()
        // Step 4: clear onboarding caches; caller decides whether to reopen setup flow.
        resolvedClientID = nil
        lastTokenValidationResult = nil
        logs.append("API key cleared. Please enter a new token to reconnect.")
    }

    /// Returns the app to the initial onboarding/setup screen.
    func runInitialSetup() {
        resolvedClientID = nil
        lastTokenValidationResult = nil
        viewMode = .local
        isOnboardingComplete = false
    }

    private func resolveClientID(token: String, fallbackUserID: String?) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackUserID }

        if let appID = await identityRESTClient.resolveClientID(token: trimmed) {
            return appID
        }

        return fallbackUserID
    }

    /// Generates a Discord invite URL for the bot, resolving/storing client ID on demand.
    func generateInviteURL(includeSlashCommands: Bool? = nil) async -> String? {
        let cid: String
        if let existing = resolvedClientID {
            cid = existing
        } else {
            let token = normalizedDiscordToken(from: settings.token)
            guard !token.isEmpty else { return nil }
            let resolved = await resolveClientID(token: token, fallbackUserID: nil)
            if let resolved {
                resolvedClientID = resolved
                cid = resolved
            } else {
                let validation = await identityRESTClient.validateBotTokenRich(token)
                guard validation.isValid else {
                    lastTokenValidationResult = validation
                    return nil
                }
                lastTokenValidationResult = validation
                guard let fallback = await resolveClientID(token: token, fallbackUserID: validation.userId) else {
                    return nil
                }
                resolvedClientID = fallback
                cid = fallback
            }
        }
        let includeSlash = includeSlashCommands ?? (settings.commandsEnabled && settings.slashCommandsEnabled)
        return await service.generateInviteURL(clientId: cid, includeSlashCommands: includeSlash)
    }

    // MARK: - Diagnostics

    /// Whether the 10-second Test Connection UI cooldown has elapsed.
    var canRunTestConnection: Bool {
        guard let until = testConnectionCooldownUntil else { return true }
        return Date() >= until
    }

    /// Derived: gateway intents were accepted when Discord sent READY.
    var intentsAccepted: Bool? {
        switch status {
        case .running where readyEventCount > 0: return true
        case .stopped: return nil
        default: return nil
        }
    }

    /// Runs an on-demand REST health probe and updates `connectionDiagnostics`.
    /// Enforces a 10-second UI rate limit — callers must check `canRunTestConnection` first.
    func runTestConnection() async {
        guard canRunTestConnection else { return }
        testConnectionCooldownUntil = Date().addingTimeInterval(10)
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else {
            connectionDiagnostics.lastTestAt = Date()
            connectionDiagnostics.lastTestMessage = "No token configured."
            connectionDiagnostics.restHealth = .error(0, "No token")
            return
        }
        let (isOK, httpStatus, remaining) = await identityRESTClient.restHealthProbe(token: token)
        let now = Date()
        connectionDiagnostics.lastTestAt = now
        connectionDiagnostics.rateLimitRemaining = remaining
        if isOK {
            connectionDiagnostics.restHealth = .ok
            connectionDiagnostics.lastTestMessage = "REST probe OK."
        } else {
            let code = httpStatus ?? 0
            let message = diagnosticsRemediationMessage(httpStatus: code)
            connectionDiagnostics.restHealth = .error(code, message)
            connectionDiagnostics.lastTestMessage = message
        }
    }

    func diagnosticsRemediationMessage(httpStatus: Int) -> String {
        switch httpStatus {
        case 401: return "401 Unauthorized — Token is invalid or revoked. Use Clear API Key to reset."
        case 403: return "403 Forbidden — Bot lacks required permissions. Re-invite with correct permissions."
        case 429: return "429 Rate Limited — Reduce request frequency. Discord will reset the limit automatically."
        case 0:   return "Network failure — Check your internet connection."
        default:  return "HTTP \(httpStatus) — Unexpected error from Discord REST API."
        }
    }

    func gatewayCloseRemediationMessage(code: Int) -> String {
        switch code {
        case 4004: return "Close 4004 — Authentication failed. Token is invalid. Use Clear API Key to reset."
        case 4014: return "Close 4014 — Privileged intent not enabled. Enable SERVER MEMBERS INTENT and MESSAGE CONTENT INTENT in the Discord Developer Portal → Bot tab."
        case 4013: return "Close 4013 — Invalid intents specified. Check the gateway intents bitmask (required: 37507)."
        case 4009: return "Close 4009 — Session timed out. The bot will reconnect automatically."
        case 4000: return "Close 4000 — Unknown gateway error. The bot will attempt to reconnect."
        default:   return "Close \(code) — Gateway closed with error. The bot will attempt to reconnect."
        }
    }

    func normalizedDiscordToken(from raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bot ") {
            token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

}
