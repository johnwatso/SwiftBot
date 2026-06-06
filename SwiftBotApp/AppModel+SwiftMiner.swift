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
        if trimmed.hasPrefix("swiftminer://pair?") || trimmed.hasPrefix("swiftbot://swiftminer-pair?") {
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

    /// Title of the first embed on the message this DM is replying to, if any.
    /// Discord includes `referenced_message` inline on replies.
    private func referencedEmbedTitle(from rawMap: [String: DiscordJSON]) -> String? {
        guard case let .object(referenced)? = rawMap["referenced_message"],
              case let .array(embeds)? = referenced["embeds"],
              case let .object(firstEmbed)? = embeds.first,
              case let .string(title)? = firstEmbed["title"]
        else { return nil }
        return title
    }

    private func componentMessageEmbedTitle(from rawMap: [String: DiscordJSON]) -> String? {
        guard case let .object(message)? = rawMap["message"],
              case let .array(embeds)? = message["embeds"],
              case let .object(firstEmbed)? = embeds.first,
              case let .string(title)? = firstEmbed["title"]
        else { return nil }
        return title
    }

    private func gameNameFromSwiftMinerComponentMessage(_ rawMap: [String: DiscordJSON]) -> String? {
        guard let title = componentMessageEmbedTitle(from: rawMap) else { return nil }
        if let game = SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle: title) {
            return game
        }
        let trimmed = title
            .replacingOccurrences(of: "[TEST] ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("🆕"), let range = trimmed.range(of: "— New campaign") {
            let game = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)..<range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return game.isEmpty ? nil : game
        }
        return nil
    }

    private func accountIdFromPriorityCustomID(_ customID: String) -> String? {
        let prefixes = [
            SwiftMinerDMEmbedBuilders.prioritiseGameCustomIDPrefix,
            SwiftMinerDMEmbedBuilders.prioritiseGameTestCustomIDPrefix
        ]
        guard let prefix = prefixes.first(where: { customID.hasPrefix($0) }) else { return nil }
        let suffix = customID.dropFirst(prefix.count)
        guard suffix.hasPrefix(":") else { return nil }
        let accountId = String(suffix.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        return accountId.isEmpty ? nil : accountId
    }

    /// Handles a possible "reply to dismiss" on a "Link Twitch for {game}" DM.
    /// Returns true when the message was a dismiss reply (handled — caller should
    /// stop processing it), false otherwise.
    func handleSwiftMinerLinkWarningDismiss(
        discordUserId: String,
        channelId: String,
        rawMap: [String: DiscordJSON],
        content: String
    ) async -> Bool {
        let referencedTitle = referencedEmbedTitle(from: rawMap)
        guard let game = SwiftMinerLinkWarningDismiss.gameToDismiss(
            replyContent: content,
            referencedEmbedTitle: referencedTitle
        ) else {
            return false
        }

        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let ignored = try await client.ignoreLinkWarning(discordUserId: discordUserId, gameName: game)
            if ignored {
                _ = await send(channelId, "👍 Got it — you won't get more reminders to link Twitch for **\(game)**. You can turn it back on anytime in SwiftMiner.")
            } else {
                _ = await send(channelId, "I couldn't find a linked SwiftMiner account for you, so there was nothing to mute for **\(game)**.")
            }
        } catch {
            _ = await send(channelId, "I couldn't update that right now — please try again later. (\(error.localizedDescription))")
        }
        return true
    }

    func handleSwiftMinerLinkWarningDismissButton(
        event: GatewayInteractionCreateEvent,
        context: SlashContext,
        isDebug: Bool
    ) async {
        let game = componentMessageEmbedTitle(from: event.rawMap)
            .flatMap(SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle:))
        guard let game else {
            await respondToSwiftMinerButton(event: event, message: "I couldn't tell which game this reminder was for.")
            return
        }

        if isDebug {
            await respondToSwiftMinerButton(
                event: event,
                message: "Test dismiss received for **\(game)** — no real settings changed."
            )
            return
        }

        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let ignored = try await client.ignoreLinkWarning(discordUserId: userId, gameName: game)
            let message = ignored
                ? "Got it — I won't send more link reminders for **\(game)**."
                : "I couldn't find a linked SwiftMiner account for you, so there was nothing to mute for **\(game)**."
            await respondToSwiftMinerButton(event: event, message: message)
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't update that right now — please try again later. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerPrioritiseGameButton(
        event: GatewayInteractionCreateEvent,
        context: SlashContext,
        customID: String,
        isDebug: Bool
    ) async {
        guard let game = gameNameFromSwiftMinerComponentMessage(event.rawMap) else {
            await respondToSwiftMinerButton(event: event, message: "I couldn't tell which game this button was for.")
            return
        }
        if isDebug {
            await respondToSwiftMinerButton(event: event, message: "Test priority received for **\(game)** - no real settings changed.")
            return
        }

        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let accountId: String
            if let id = accountIdFromPriorityCustomID(customID) {
                accountId = id
            } else if let projectionAccount = try await client.projection(discordUserId: userId).account?.twitchAccountId {
                accountId = projectionAccount
            } else {
                await respondToSwiftMinerButton(event: event, message: "I couldn't find your linked SwiftMiner account yet. Try **Refresh status** first.")
                return
            }
            let response = try await client.prioritiseGame(discordUserId: userId, accountId: accountId, gameName: game)
            let top = response.priorityGames.first ?? game
            await respondToSwiftMinerButton(
                event: event,
                message: "Done - **\(top)** is now priority #1 for your miner."
            )
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't update that priority right now - please try again later. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerCampaignDismissButton(
        event: GatewayInteractionCreateEvent,
        context: SlashContext,
        customID: String,
        isDebug: Bool
    ) async {
        let prefix = isDebug ? SwiftMinerDMEmbedBuilders.campaignDismissTestCustomIDPrefix : SwiftMinerDMEmbedBuilders.campaignDismissCustomIDPrefix
        let campaignId = customID.dropFirst(prefix.count).dropFirst()
        guard !campaignId.isEmpty else {
            await respondToSwiftMinerButton(event: event, message: "I couldn't tell which campaign this button was for.")
            return
        }
        if isDebug {
            await respondToSwiftMinerButton(event: event, message: "Test dismiss received - no real settings changed.")
            return
        }
        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            try await client.ignoreCampaign(discordUserId: userId, campaignId: String(campaignId), scope: "campaign")
            await respondToSwiftMinerButton(event: event, message: "Done - I won't remind you about that campaign again.")
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't dismiss that campaign right now - please try again later. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerStatusRefreshButton(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let projection = try await client.projection(discordUserId: userId)
            await respondToSwiftMinerButton(event: event, message: renderSwiftMinerProjection(projection))
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't refresh SwiftMiner status right now - please try `/miner action:status` in a moment. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerPrioritiesButton(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let projection = try await client.projection(discordUserId: userId)
            await respondToSwiftMinerButton(event: event, message: renderSwiftMinerPriorities(projection))
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't fetch your SwiftMiner priorities right now - please try `/miner action:status` in a moment. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerWhyBlockedButton(event: GatewayInteractionCreateEvent, context: SlashContext) async {
        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let messageGame = componentMessageEmbedTitle(from: event.rawMap)
            .flatMap(SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle:))
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let projection = try await client.projection(discordUserId: userId)
            await respondToSwiftMinerButton(
                event: event,
                message: renderSwiftMinerBlockerExplanation(projection: projection, messageGame: messageGame)
            )
        } catch {
            if let messageGame {
                await respondToSwiftMinerButton(
                    event: event,
                    message: "SwiftMiner wants to mine **\(messageGame)**, but Twitch does not show that account as linked for this game's Drops yet. Open Twitch Drops, link the game/account, then use **Refresh status** here."
                )
            } else {
                await respondToSwiftMinerButton(
                    event: event,
                    message: "I couldn't fetch the blocker details right now - please try **Refresh status** or `/miner action:status` in a moment. (\(error.localizedDescription))"
                )
            }
        }
    }

    func handleSwiftMinerLinkWarningPauseButton(
        event: GatewayInteractionCreateEvent,
        context: SlashContext,
        isDebug: Bool
    ) async {
        let game = componentMessageEmbedTitle(from: event.rawMap)
            .flatMap(SwiftMinerLinkWarningDismiss.game(fromNeedsLinkingTitle:))
        guard let game else {
            await respondToSwiftMinerButton(event: event, message: "I couldn't tell which game this reminder was for.")
            return
        }

        if isDebug {
            await respondToSwiftMinerButton(
                event: event,
                message: "Test pause received for **\(game)** - no real settings changed."
            )
            return
        }

        let userId = authorId(from: context.rawLikeMessage) ?? "unknown-user"
        let client = SwiftMinerClient(settings: settings.swiftMiner, session: discordRESTSession)
        do {
            let paused = try await client.pauseLinkWarning(discordUserId: userId, gameName: game, days: 7)
            let message = paused
                ? "Done - I won't send link reminders for **\(game)** for 7 days."
                : "I couldn't find a linked SwiftMiner account for you, so there was nothing to pause for **\(game)**."
            await respondToSwiftMinerButton(event: event, message: message)
        } catch {
            await respondToSwiftMinerButton(
                event: event,
                message: "I couldn't pause that reminder right now - please try again later. (\(error.localizedDescription))"
            )
        }
    }

    func handleSwiftMinerQuietModeButton(event: GatewayInteractionCreateEvent) async {
        settings.swiftMiner.notificationPreferences.dropClaimedEnabled = false
        settings.swiftMiner.notificationPreferences.campaignDetectedEnabled = false
        settings.swiftMiner.notificationPreferences.welcomeBackEnabled = false
        saveSettings()
        await respondToSwiftMinerButton(
            event: event,
            message: "Done - SwiftMiner will send fewer DMs now. I'll still send setup, account recovery, link-required, and campaign-complete messages."
        )
    }

    private func respondToSwiftMinerButton(event: GatewayInteractionCreateEvent, message: String) async {
        do {
            try await service.respondToInteraction(
                interactionID: event.interactionID,
                interactionToken: event.interactionToken,
                payload: [
                    "type": 4,
                    "data": [
                        "content": message,
                        "flags": 64
                    ]
                ]
            )
        } catch {
            logs.append("❌ Failed responding to SwiftMiner button: \(error.localizedDescription)")
        }
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
                let activationLink = activationLink(for: session)
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
            case "pause", "resume", "refresh":
                let response = try await client.controlMiner(discordUserId: userId, action: normalizedAction)
                return (response.ok, response.message)
            default:
                return (false, "Usage: `/miner action:status`, `/miner action:setup`, `/miner action:pause`, `/miner action:resume`, `/miner action:refresh`, or `/miner action:health`.")
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

    func swiftMinerDiscordUsers() async -> [AdminWebDiscordUser] {
        let users = await discordCache.humanUsers()
        return users.map { user in
            let avatar = avatarURL(forUserId: user.id) ?? fallbackAvatarURL(forUserId: user.id)
            return AdminWebDiscordUser(
                discordId: user.id,
                displayName: user.displayName,
                username: user.username,
                avatarURL: avatar?.absoluteString
            )
        }
    }

    // MARK: - SwiftMiner Typed DM Pipeline

    private func makeSwiftMinerDMSender() -> SwiftMinerDMSender {
        SwiftMinerDMSender(dependencies: .init(
                sendDMEmbed: { [weak self] userId, embed, components in
                    guard let self else { throw NSError(domain: "SwiftMinerDMSender", code: -1, userInfo: [NSLocalizedDescriptionKey: "AppModel deallocated"]) }
                    nonisolated(unsafe) let safeEmbed = embed
                    nonisolated(unsafe) let safeComponents = components
                    try await self.service.sendDMEmbed(userId: userId, embed: safeEmbed, components: safeComponents)
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
            gameArtworkURL: mockData.gameArtworkURL,
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
            headline = "SwiftMiner claimed a Drop."
        case "user.actionRequired":
            headline = "SwiftMiner needs a quick check."
        case "user.opportunityAvailable":
            headline = "SwiftMiner found a Drops campaign."
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
            return """
            **Twitch is not linked yet.**
            Run `/miner action:setup` and I'll send you a Twitch activation link.
            """
        case .active:
            if let campaign = projection.activeCampaign {
                return """
                **SwiftMiner is mining \(campaign.game).**
                Progress: **\(campaign.progress.pct)%** (\(campaign.progress.current)/\(campaign.progress.required) \(campaign.progress.unit))
                \(campaignEndLine(campaign.endsAt))
                \(recentCampaignsSection(projection))
                """
            }
            return """
            **SwiftMiner is active.**
            No specific campaign is showing in the status feed yet. I'll message you when something useful changes.
            \(recentCampaignsSection(projection))
            """
        case .idle:
            let account = projection.account.map { " for @\($0.username)" } ?? ""
            return """
            **Your miner is fully up to date\(account).**
            There are no active Drops ready to mine right now.
            \(recentCampaignsSection(projection))
            \(issueSummarySection(projection))
            """
        case .blocked:
            if let issue = projection.issues.first {
                return """
                **SwiftMiner needs a quick check.**
                \(issue.message)
                \(swiftMinerNextStep(for: issue))
                \(recentCampaignsSection(projection))
                """
            }
            return """
            **SwiftMiner needs a quick check.**
            Run `/miner action:status` again for details, or `/miner action:setup` if Twitch needs reconnecting.
            \(recentCampaignsSection(projection))
            """
        }
    }

    private func campaignEndLine(_ endsAt: Date?) -> String {
        guard let endsAt else {
            return "I'll message you when this campaign is complete."
        }
        return "Ends: <t:\(Int(endsAt.timeIntervalSince1970)):R>"
    }

    private func swiftMinerNextStep(for issue: SwiftMinerUserProjection.Issue) -> String {
        if issue.action.contains("link_account") {
            return "Next step: run `/miner action:setup` to reconnect Twitch."
        }
        return "Next step: run `/miner action:status` to check the latest details."
    }

    private func recentCampaignsSection(_ projection: SwiftMinerUserProjection) -> String {
        let campaigns = projection.recentCompletedCampaigns ?? []
        guard !campaigns.isEmpty else {
            return "Recently mined: none reported yet."
        }
        let rows = campaigns.prefix(3).map { campaign -> String in
            let title = campaignTitle(campaign)
            let drops = campaign.totalDrops > 0
                ? " — \(campaign.claimedDrops)/\(campaign.totalDrops) Drops claimed"
                : ""
            return "• \(title)\(drops)"
        }.joined(separator: "\n")
        return "Recently mined:\n\(rows)"
    }

    private func renderSwiftMinerPriorities(_ projection: SwiftMinerUserProjection) -> String {
        let priorities = projection.priorityGames ?? []
        guard !priorities.isEmpty else {
            return """
            **No priority games are set right now.**
            SwiftMiner will pick from available Drops campaigns automatically.
            """
        }
        let rows = priorities.prefix(10).enumerated().map { index, game in
            "\(index + 1). **\(game)**"
        }.joined(separator: "\n")
        let suffix = priorities.count > 10 ? "\n…and \(priorities.count - 10) more." : ""
        return """
        **Current SwiftMiner priorities**
        \(rows)\(suffix)
        """
    }

    private func renderSwiftMinerBlockerExplanation(
        projection: SwiftMinerUserProjection,
        messageGame: String?
    ) -> String {
        if let issue = projection.issues.first {
            let game = issue.game ?? messageGame
            let gameText = game.map { " for **\($0)**" } ?? ""
            return """
            **Why SwiftMiner is blocked\(gameText)**
            \(issue.message)
            \(swiftMinerNextStep(for: issue))
            """
        }
        if let messageGame {
            return """
            **Why SwiftMiner is blocked for \(messageGame)**
            SwiftMiner wants to mine **\(messageGame)** because it is in your priority list, but Twitch does not show that account as linked for this game's Drops yet.
            Next step: open Twitch Drops, link the game/account, then use **Refresh status** here.
            """
        }
        return """
        **No current blocker is showing.**
        Use **Refresh status** for the latest SwiftMiner state.
        """
    }

    private func issueSummarySection(_ projection: SwiftMinerUserProjection) -> String {
        guard let issue = projection.issues.first else { return "" }
        let game = issue.game.map { " on **\($0)**" } ?? ""
        return "Currently blocked\(game): \(issue.message)"
    }

    private func campaignTitle(_ campaign: SwiftMinerUserProjection.RecentCampaign) -> String {
        if campaign.campaignName.caseInsensitiveCompare(campaign.game) == .orderedSame {
            return "**\(campaign.game)**"
        }
        return "**\(campaign.game)** — \(campaign.campaignName)"
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

    private func activationLink(for session: SwiftMinerActivationSession) -> String {
        let verificationUri = session.verificationUri
        if verificationUri.contains("device-code=") || verificationUri.contains("code=") {
            return verificationUri
        }
        let encodedCode = session.userCode.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? session.userCode
        let separator = verificationUri.contains("?") ? "&" : "?"
        return "\(verificationUri)\(separator)device-code=\(encodedCode)"
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
