import AppKit
import CryptoKit
import Foundation
import OSLog

extension AppModel {
    func applySwiftMinerPairingToken(_ rawToken: String) -> (ok: Bool, message: String) {
        do {
            let bundle = try decodeSwiftMinerPairingToken(rawToken)
            settings.swiftMiner.apply(pairingBundle: bundle)
            settings.adminWebUI.enabled = true
            cacheSwiftMinerArtwork(from: bundle)
            saveSettings()
            return (true, "SwiftMiner pairing bundle applied. Local webhook server enabled.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func decodeSwiftMinerPairingToken(_ rawToken: String) throws -> SwiftMinerPairingBundle {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SwiftMinerPairingError.empty }

        let encodedPayload: String
        if trimmed.hasPrefix("swiftminer://pair?") {
            guard let components = URLComponents(string: trimmed),
                  let value = components.queryItems?.first(where: { $0.name == "b" })?.value else {
                throw SwiftMinerPairingError.invalidToken
            }
            encodedPayload = value
        } else if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8) else { throw SwiftMinerPairingError.invalidToken }
            return try decodeSwiftMinerPairingJSON(data)
        } else {
            encodedPayload = trimmed
        }

        guard let data = Data(base64Encoded: encodedPayload) else {
            throw SwiftMinerPairingError.invalidBase64
        }
        return try decodeSwiftMinerPairingJSON(data)
    }

    func swiftMinerCommand(action: String, userId: String, channelId: String) async -> (ok: Bool, message: String) {
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        do {
            switch normalizedAction.isEmpty ? "status" : normalizedAction {
            case "health":
                let ok = try await client.health()
                return (ok, ok ? "SwiftMiner API is reachable." : "SwiftMiner health check did not return ok.")
            case "setup":
                do {
                    try await client.registerUser(discordUserId: userId)
                } catch SwiftMinerClientError.http(let status, let code, _) where status == 409 || code == "user_already_exists" {
                    // Already registered; continue into activation.
                } catch SwiftMinerClientError.http(let status, let code, _) where status == 404 || code == "not_found" {
                    return (
                        false,
                        "SwiftMiner is reachable, but this SwiftMiner build does not expose user registration yet. Ask the SwiftMiner service to add `POST /v1/users` before Discord setup can finish."
                    )
                }

                let session = try await client.startActivation(discordUserId: userId)
                let activationLink = "\(session.verificationUri)?code=\(session.userCode)"
                return (
                    true,
                    """
                    Link Twitch for SwiftMiner:
                    [Click here to activate](\(activationLink))

                    Or enter code `\(session.userCode)` at \(session.verificationUri)
                    This code expires \(relativeTimeText(for: session.expiresAt)).
                    """
                )
            case "status":
                let projection = try await client.projection(discordUserId: userId)
                return (true, renderSwiftMinerProjection(projection))
            default:
                return (false, "Usage: `/miner action:status`, `/miner action:setup`, or `/miner action:health`.")
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func fetchSwiftMinerRegisteredUsers() async -> [String: String] {
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        let cacheNames = await discordCache.allUserNames()
        guard let ids = try? await client.registeredUserIds() else {
            return cacheNames
        }
        var result: [String: String] = [:]
        for id in ids {
            result[id] = cacheNames[id] ?? id
        }
        return result
    }

    // MARK: - SwiftMiner Typed DM Pipeline

    private func makeSwiftMinerDMSender() -> SwiftMinerDMSender {
        SwiftMinerDMSender(dependencies: .init(
                sendDMEmbed: { [weak self] userId, embed in
                    guard let self else { throw NSError(domain: "SwiftMinerDMSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "AppModel deallocated"]) }
                    try await self.service.sendDMEmbed(userId: userId, embed: embed)
                },
                discordNameForUserId: { [weak self] userId in
                    guard let self else { return nil }
                    return await self.discordCache.userName(for: userId)
                },
                hasUserBeenWelcomed: { [weak self] userId in
                    guard let self else { return true }
                    return await MainActor.run {
                        self.settings.swiftMiner.welcomeMessageSentUserIds.contains(userId)
                    }
                },
                hasUserCompletedOnboarding: { [weak self] userId in
                    guard let self else { return true }
                    return await MainActor.run {
                        self.settings.swiftMiner.completedInitialDMFlowUserIds.contains(userId)
                    }
                },
                markUserWelcomed: { [weak self] userId in
                    guard let self else { return }
                    await MainActor.run {
                        self.settings.swiftMiner.welcomeMessageSentUserIds.insert(userId)
                        self.saveSettings()
                    }
                },
                markUserCompletedOnboarding: { [weak self] userId in
                    guard let self else { return }
                    await MainActor.run {
                        self.settings.swiftMiner.completedInitialDMFlowUserIds.insert(userId)
                        self.saveSettings()
                    }
                },
                hasEventBeenSent: { [weak self] signature in
                    guard let self else { return true }
                    return await MainActor.run {
                        self.settings.swiftMiner.sentEventSignatures.contains(signature)
                    }
                },
                markEventSent: { [weak self] signature in
                    guard let self else { return }
                    await MainActor.run {
                        self.settings.swiftMiner.sentEventSignatures.insert(signature)
                        self.saveSettings()
                    }
                },
                logInfo: { [weak self] message in
                    self?.swiftMinerLogger.info("\(message)")
                },
                logError: { [weak self] message in
                    self?.swiftMinerLogger.error("\(message)")
                },
                recordEvent: { [weak self] message in
                    guard let self else { return }
                    await MainActor.run {
                        self.addEvent(ActivityEvent(timestamp: Date(), kind: .command, message: message))
                    }
                }
            )
        )
    }

    func sendSwiftMinerDM(request: SwiftMinerDMRequest, discordUserId: String) async -> Bool {
        guard settings.swiftMiner.enabled else {
            self.swiftMinerLogger.warning("sendSwiftMinerDM skipped: SwiftMiner integration is disabled")
            return false
        }
        let sender = makeSwiftMinerDMSender()
        return await sender.send(request: request, discordUserId: discordUserId)
    }

    // MARK: - DM Testing Utilities

    /// Sends a preview DM of any SwiftMiner message type with mock data.
    /// Does NOT mutate production state (forces debug mode).
    func previewSwiftMinerDM(
        messageType: SwiftMinerDMMessageType,
        discordUserId: String,
        mockData: SwiftMinerDMMockData = SwiftMinerDMMockData()
    ) async -> Bool {
        let request = SwiftMinerDMRequest(
            messageType: messageType,
            debug: true,
            twitchUsername: mockData.twitchUsername,
            priorityGames: mockData.priorityGames,
            activationCode: mockData.activationCode,
            activationExpiresInMinutes: mockData.activationExpiresInMinutes,
            activationURL: mockData.activationURL,
            affectedGame: mockData.affectedGame,
            campaignName: mockData.campaignName,
            milestoneTitle: mockData.milestoneTitle,
            recoveryReason: mockData.recoveryReason
        )
        return await sendSwiftMinerDM(request: request, discordUserId: discordUserId)
    }

    /// Returns the embed that would be sent for a given request, without sending it.
    /// Useful for admin preview panels.
    func renderSwiftMinerDMEmbedPreview(request: SwiftMinerDMRequest, discordUserId: String) async -> [String: Any] {
        let sender = makeSwiftMinerDMSender()
        return await sender.preview(request: request, discordUserId: discordUserId)
    }

    func handleSwiftMinerWebhook(headers: [String: String], body: Data) async -> (status: String, body: Data) {
        guard settings.swiftMiner.enabled else {
            return swiftMinerWebhookResponse(status: "404 Not Found", payload: ["error": "swiftminer_disabled"])
        }
        guard validateSwiftMinerSignature(headers: headers, body: body) else {
            return swiftMinerWebhookResponse(status: "401 Unauthorized", payload: ["error": "invalid_signature"])
        }
        guard let event = try? JSONDecoder().decode(SwiftMinerWebhookEvent.self, from: body) else {
            return swiftMinerWebhookResponse(status: "400 Bad Request", payload: ["error": "invalid_payload"])
        }

        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        let projection: SwiftMinerUserProjection?
        do {
            projection = try await client.projection(discordUserId: event.subject.discordUserId)
        } catch {
            projection = nil
        }

        let bodyText = renderSwiftMinerWebhookMessage(event: event, projection: projection)
        do {
            guard ActionDispatcher.canSend(clusterMode: runtimeClusterMode, action: "swiftMinerWebhookDM", log: { logs.append($0) }) else {
                return swiftMinerWebhookResponse(status: "202 Accepted", payload: ["ok": true, "delivered": false])
            }
            try await service.sendDM(userId: event.subject.discordUserId, content: bodyText)
            addEvent(ActivityEvent(timestamp: Date(), kind: .command, message: "SwiftMiner event \(event.eventType) delivered"))
            return swiftMinerWebhookResponse(status: "200 OK", payload: ["ok": true])
        } catch {
            logs.append("SwiftMiner webhook DM failed: \(error.localizedDescription)")
            return swiftMinerWebhookResponse(status: "202 Accepted", payload: ["ok": true, "delivered": false])
        }
    }

    private func swiftMinerWebhookResponse(status: String, payload: [String: Any]) -> (status: String, body: Data) {
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
        return (status, body)
    }

    private func renderSwiftMinerWebhookMessage(
        event: SwiftMinerWebhookEvent,
        projection: SwiftMinerUserProjection?
    ) -> String {
        let headline: String
        switch event.eventType {
        case "user.dropClaimed":
            headline = "SwiftMiner drop claimed."
        case "user.actionRequired":
            headline = "SwiftMiner needs your attention."
        case "user.opportunityAvailable":
            headline = "SwiftMiner found a drops opportunity."
        case "user.stateChanged":
            headline = "SwiftMiner status changed."
        default:
            headline = "SwiftMiner updated."
        }

        if let projection {
            return "\(headline)\n\n\(renderSwiftMinerProjection(projection))"
        }
        return headline
    }

    private func renderSwiftMinerProjection(_ projection: SwiftMinerUserProjection) -> String {
        switch projection.state {
        case .notConfigured:
            return "SwiftMiner is not set up for your Discord account yet. Run `/miner action:setup`."
        case .active:
            if let campaign = projection.activeCampaign {
                return "SwiftMiner is mining \(campaign.game): \(campaign.progress.pct)% (\(campaign.progress.current)/\(campaign.progress.required) \(campaign.progress.unit))."
            }
            return "SwiftMiner is active."
        case .idle:
            let account = projection.account.map { " for @\($0.username)" } ?? ""
            return "SwiftMiner is idle\(account). No active campaign is being mined right now."
        case .blocked:
            if let issue = projection.issues.first {
                return "SwiftMiner is blocked: \(issue.message)"
            }
            return "SwiftMiner is blocked and needs attention."
        }
    }

    private func validateSwiftMinerSignature(headers: [String: String], body: Data) -> Bool {
        let secret = settings.swiftMiner.webhookSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return true }
        guard let timestamp = headers["x-swiftminer-timestamp"],
              let signature = headers["x-swiftminer-signature"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let timestampValue = TimeInterval(timestamp),
              abs(Date().timeIntervalSince1970 - timestampValue) <= 300 else {
            return false
        }
        let signed = Data("\(timestamp).".utf8) + body
        let key = SymmetricKey(data: Data(secret.utf8))
        let expected = HMAC<SHA256>.authenticationCode(for: signed, using: key)
            .map { String(format: "%02x", $0) }
            .joined()
        return signature == "v1=\(expected)"
    }

    private func relativeTimeText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func decodeSwiftMinerPairingJSON(_ data: Data) throws -> SwiftMinerPairingBundle {
        let bundle = try JSONDecoder().decode(SwiftMinerPairingBundle.self, from: data)
        let endpoint = bundle.swiftMinerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? bundle.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            : bundle.swiftMinerEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            throw SwiftMinerPairingError.missingEndpoint
        }
        guard bundle.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
            throw SwiftMinerPairingError.missingAPIKey
        }
        guard bundle.hmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32 else {
            throw SwiftMinerPairingError.missingSecret
        }
        return bundle
    }

    func swiftMinerCachedArtworkURL() -> URL? {
        let fileName = settings.swiftMiner.cachedArtworkFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileName.isEmpty else { return nil }
        let url = Self.swiftMinerArtworkCacheDirectoryURL().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func cacheSwiftMinerArtworkIfNeeded() {
        let fileName = settings.swiftMiner.cachedArtworkFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cachedURL = swiftMinerCachedArtworkURL()
        guard cachedURL == nil || fileName.isEmpty else { return }
        let artworkURL = settings.swiftMiner.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artworkURL.isEmpty else { return }
        cacheSwiftMinerArtwork(from: nil)
    }

    private func cacheSwiftMinerArtwork(from bundle: SwiftMinerPairingBundle?) {
        if let bundle,
           let data = Self.decodedSwiftMinerArtworkData(from: bundle.artworkDataBase64) {
            storeSwiftMinerArtwork(data)
            return
        }

        let artworkURL = (bundle?.artworkURL ?? settings.swiftMiner.artworkURL).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: artworkURL), ["http", "https"].contains(url.scheme?.lowercased()) else { return }

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    return
                }
                await MainActor.run {
                    self?.storeSwiftMinerArtwork(data)
                    self?.saveSettings()
                }
            } catch {
                await MainActor.run {
                    self?.logs.append("SwiftMiner artwork cache failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func storeSwiftMinerArtwork(_ data: Data) {
        guard NSImage(data: data) != nil else { return }
        let fileName = "swiftminer-artwork-\(SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()).img"
        let url = Self.swiftMinerArtworkCacheDirectoryURL().appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            settings.swiftMiner.cachedArtworkFileName = fileName
        } catch {
            logs.append("SwiftMiner artwork cache failed: \(error.localizedDescription)")
        }
    }

    private static func decodedSwiftMinerArtworkData(from rawValue: String) -> Data? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let base64 = trimmed.localizedCaseInsensitiveContains(";base64,")
            ? trimmed.components(separatedBy: ";base64,").last ?? ""
            : trimmed
        return Data(base64Encoded: base64)
    }

    private static func swiftMinerArtworkCacheDirectoryURL() -> URL {
        let url = SwiftBotStorage.folderURL().appendingPathComponent("swiftminer-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private enum SwiftMinerPairingError: LocalizedError {
    case empty
    case invalidToken
    case invalidBase64
    case missingEndpoint
    case missingAPIKey
    case missingSecret

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Paste the pairing bundle copied from SwiftMiner."
        case .invalidToken:
            return "That does not look like a SwiftMiner pairing bundle."
        case .invalidBase64:
            return "The SwiftMiner pairing payload could not be decoded."
        case .missingEndpoint:
            return "The pairing bundle is missing the SwiftMiner API endpoint."
        case .missingAPIKey:
            return "The pairing bundle is missing a valid SwiftMiner API key."
        case .missingSecret:
            return "The pairing bundle is missing a valid webhook secret."
        }
    }
}

private struct SwiftMinerWebhookEvent: Codable {
    struct Subject: Codable {
        let discordUserId: String
    }

    let eventId: String
    let eventType: String
    let subject: Subject
}
