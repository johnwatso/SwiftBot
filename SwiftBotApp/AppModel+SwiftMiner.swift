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
                return (
                    true,
                    """
                    Link Twitch for SwiftMiner:
                    1. Open \(session.verificationUri)
                    2. Enter code `\(session.userCode)`

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

    func sendSwiftMinerTestDM(
        to discordUserId: String,
        twitchUsername: String?,
        priorityGames: [String],
        priorityGamesKeyPresent: Bool
    ) async -> Bool {
        guard settings.swiftMiner.enabled else {
            self.swiftMinerLogger.warning("sendSwiftMinerTestDM skipped: SwiftMiner integration is disabled")
            return false
        }

        self.swiftMinerLogger.info(
            "Building SwiftMiner onboarding embed for \(discordUserId) — priorityGamesKeyPresent: \(priorityGamesKeyPresent), count: \(priorityGames.count)"
        )

        // Look up the recipient's Discord display name (server nick / global name / username)
        // from the gateway cache so the message can address them by name.
        let discordName = await discordCache.userName(for: discordUserId)
        let greeting = discordName.map { "Hi **\($0)**! " } ?? ""

        let body: String
        if let twitchUsername, !twitchUsername.isEmpty {
            body = "Your Twitch account **@\(twitchUsername)** is linked and ready to mine drops."
        } else {
            body = "Your Twitch account has been linked to SwiftMiner and is ready to mine drops."
        }
        let description = greeting + body

        var fields: [[String: Any]] = []

        if !priorityGamesKeyPresent {
            fields.append([
                "name": "🎮 Priority games",
                "value": "_Priority games could not be loaded._",
                "inline": false
            ])
            self.swiftMinerLogger.warning("Priority games key missing in payload for \(discordUserId)")
        } else if priorityGames.isEmpty {
            fields.append([
                "name": "🎮 Priority games",
                "value": "_None set — SwiftMiner will mine any available drops campaign._",
                "inline": false
            ])
            self.swiftMinerLogger.info("Priority games explicitly empty for \(discordUserId)")
        } else {
            let preview = priorityGames.prefix(8).map { "• \($0)" }.joined(separator: "\n")
            let extra = priorityGames.count > 8 ? "\n• …and \(priorityGames.count - 8) more" : ""
            fields.append([
                "name": "🎮 Priority games",
                "value": preview + extra,
                "inline": false
            ])
            self.swiftMinerLogger.info("Priority games rendered for \(discordUserId): \(priorityGames)")
        }

        fields.append([
            "name": "📬 Notifications",
            "value": "You'll get a DM here if anything needs attention — auth expired, blocked drops, etc.",
            "inline": false
        ])

        let embed: [String: Any] = [
            "title": "SwiftMiner account connected and active ⚡",
            "description": description,
            "color": 3_062_954, // green, matches the ok colour used by /miner responses
            "fields": fields,
            "footer": ["text": "Use /miner action:status to check progress"]
        ]

        do {
            try await service.sendDMEmbed(userId: discordUserId, embed: embed)
            addEvent(ActivityEvent(timestamp: Date(), kind: .command, message: "SwiftMiner setup DM sent to \(discordUserId)"))
            self.swiftMinerLogger.info("SwiftMiner onboarding embed sent successfully to \(discordUserId)")
            return true
        } catch {
            logs.append("SwiftMiner setup DM failed for \(discordUserId): \(error.localizedDescription)")
            self.swiftMinerLogger.error("SwiftMiner onboarding embed failed for \(discordUserId): \(error.localizedDescription)")
            return false
        }
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
            guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "swiftMinerWebhookDM", log: { logs.append($0) }) else {
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
