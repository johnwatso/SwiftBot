import Foundation

extension AppModel {
    // MARK: - AI typing indicator + timeout

    /// Outcome of `generateAIReplyWithTimeout`. Callers must inspect this to avoid
    /// emitting a second fallback message when the hard timeout has already fired.
    enum AIReplyOutcome {
        case reply(String)       // Generation succeeded — reply text to send.
        case handledFallback     // Hard timeout fired; fallback message already sent.
        case noReply             // Engine returned nil — caller may use its own fallback.
    }

    private func sendPayloadResponse(
        channelId: String,
        payload: [String: Any],
        action: String
    ) async throws -> (statusCode: Int, responseBody: String) {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: action, log: { logs.append($0) }) else {
            throw NSError(domain: "AppModel", code: 403, userInfo: [NSLocalizedDescriptionKey: "Output blocked by ActionDispatcher"])
        }
        return try await service.sendMessage(channelId: channelId, payload: payload, token: settings.token)
    }

    private func performOutputRequest<T>(
        action: String,
        operation: () async throws -> T
    ) async -> T? {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: action, log: { logs.append($0) }) else {
            return nil
        }
        do {
            return try await operation()
        } catch {
            return nil
        }
    }

    private func performOutputAction(
        action: String,
        operation: () async throws -> Void
    ) async -> Bool {
        await performOutputRequest(action: action) {
            try await operation()
            return true
        } ?? false
    }

    private func performOutputSideEffect(
        action: String,
        operation: () async -> Void
    ) async {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: action, log: { logs.append($0) }) else {
            return
        }
        await operation()
    }

    func sendPayload(
        channelId: String,
        payload: [String: Any],
        action: String
    ) async -> Bool {
        await performOutputAction(action: action) {
            _ = try await sendPayloadResponse(channelId: channelId, payload: payload, action: action)
        }
    }

    func sendTypingIndicator(_ channelId: String) async {
        await performOutputSideEffect(action: "triggerTyping") {
            await service.triggerTyping(channelId: channelId, token: settings.token)
        }
    }

    /// Runs AI generation with a typing indicator, a 10s soft notice, and a 30s hard timeout.
    func generateAIReplyWithTimeout(
        channelId: String,
        messages: [Message],
        serverName: String?,
        channelName: String?,
        wikiContext: String?
    ) async -> AIReplyOutcome {
        await sendTypingIndicator(channelId)

        // Timing overrides for tests (compliant with March 2026 standards).
#if DEBUG
        let softNoticeNs = AITestOverrides.softNoticeNs ?? 10_000_000_000
        let hardTimeoutNs = AITestOverrides.hardTimeoutNs ?? 30_000_000_000
        let typingRefreshNs = AITestOverrides.typingRefreshNs ?? 9_000_000_000
#else
        let softNoticeNs: UInt64 = 10_000_000_000
        let hardTimeoutNs: UInt64 = 30_000_000_000
        let typingRefreshNs: UInt64 = 9_000_000_000
#endif

        let typingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: typingRefreshNs)
                guard !Task.isCancelled else { return }
                await sendTypingIndicator(channelId)
            }
        }
        defer { typingTask.cancel() }

        var softNoticeSent = false

        return await withTaskGroup(of: String?.self) { group in
            // Main generation task
            group.addTask {
                await self.cluster.generateAIReply(
                    messages: messages,
                    serverName: serverName,
                    channelName: channelName,
                    wikiContext: wikiContext
                )
            }

            // Soft notice
            group.addTask {
                try? await Task.sleep(nanoseconds: softNoticeNs)
                return "__soft_notice__"
            }

            // Hard timeout
            group.addTask {
                try? await Task.sleep(nanoseconds: hardTimeoutNs)
                return "__hard_timeout__"
            }

            for await value in group {
                switch value {
                case "__soft_notice__":
                    if !softNoticeSent {
                        softNoticeSent = true
                        _ = await send(channelId, "One moment — I'm still working on that.")
                    }
                case "__hard_timeout__":
                    group.cancelAll()
                    _ = await send(channelId, "Whoops — that one's a bit beyond my current limits. Try a shorter or more specific prompt.")
                    return .handledFallback
                case let text?:
                    group.cancelAll()
                    return .reply(text)
                default:
                    // Engine returned nil. If the soft notice was already sent the user is
                    // waiting for a terminal reply — send the hard-timeout fallback so they
                    // are not left hanging. Without a soft notice, return .noReply so callers
                    // can decide whether to send their own fallback.
                    group.cancelAll()
                    if softNoticeSent {
                        _ = await send(channelId, "Whoops — that one's a bit beyond my current limits. Try a shorter or more specific prompt.")
                        return .handledFallback
                    }
                    return .noReply
                }
            }
            return .noReply
        }
    }

    func send(_ channelId: String, _ message: String) async -> Bool {
        await sendPayload(channelId: channelId, payload: ["content": message], action: "sendMessage")
    }

    func sendMessageReturningID(channelId: String, content: String) async -> String? {
        await performOutputRequest(action: "sendMessageReturningID") {
            try await service.sendMessageReturningID(channelId: channelId, content: content, token: settings.token)
        }
    }

    func sendEmbed(_ channelId: String, embed: [String: Any]) async -> Bool {
        await sendPayload(channelId: channelId, payload: ["embeds": [embed]], action: "sendEmbed")
    }

    func editMessage(channelId: String, messageId: String, content: String) async -> Bool {
        await performOutputAction(action: "editMessage") {
            try await service.editMessage(channelId: channelId, messageId: messageId, content: content, token: settings.token)
        }
    }

    func fetchMessage(channelId: String, messageId: String) async -> [String: DiscordJSON]? {
        do {
            return try await messageRESTClient.fetchMessage(channelId: channelId, messageId: messageId, token: settings.token)
        } catch {
            return nil
        }
    }

    func fetchRecentMessages(channelId: String, limit: Int = 30) async -> [[String: DiscordJSON]] {
        do {
            return try await messageRESTClient.fetchRecentMessages(channelId: channelId, limit: limit, token: settings.token)
        } catch {
            return []
        }
    }

    func addReaction(channelId: String, messageId: String, emoji: String) async -> Bool {
        await performOutputAction(action: "addReaction") {
            try await service.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: settings.token)
        }
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String) async -> Bool {
        await performOutputAction(action: "removeOwnReaction") {
            try await service.removeOwnReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: settings.token)
        }
    }

    func pinMessage(channelId: String, messageId: String) async -> Bool {
        await performOutputAction(action: "pinMessage") {
            try await service.pinMessage(channelId: channelId, messageId: messageId, token: settings.token)
        }
    }

    func unpinMessage(channelId: String, messageId: String) async -> Bool {
        await performOutputAction(action: "unpinMessage") {
            try await service.unpinMessage(channelId: channelId, messageId: messageId, token: settings.token)
        }
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String) async -> Bool {
        await performOutputAction(action: "createThreadFromMessage") {
            try await service.createThreadFromMessage(channelId: channelId, messageId: messageId, name: name, token: settings.token)
        }
    }

    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String
    ) async -> Bool {
        await performOutputAction(action: "sendMessageWithImage") {
            _ = try await service.sendMessageWithImage(
                channelId: channelId,
                content: content,
                imageData: imageData,
                filename: filename,
                token: settings.token
            )
        }
    }

    func editMessageWithImage(
        channelId: String,
        messageId: String,
        content: String,
        imageData: Data,
        filename: String
    ) async -> Bool {
        await performOutputAction(action: "editMessageWithImage") {
            try await service.editMessageWithImage(
                channelId: channelId,
                messageId: messageId,
                content: content,
                imageData: imageData,
                filename: filename,
                token: settings.token
            )
        }
    }

    func sendPatchyNotificationDetailed(
        channelId: String,
        message: String,
        embedJSON: String?,
        roleIDs: [String]
    ) async -> (ok: Bool, detail: String) {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "sendPatchyNotification", log: { logs.append($0) }) else {
            return (false, "Patchy send blocked — node is not Primary.")
        }
        let token = settings.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            let detail = "Patchy send failed. status=- token missing."
            logs.append("❌ \(detail)")
            return (false, detail)
        }

        let cleanedRoleIDs = roleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let roleMentionText = cleanedRoleIDs.map { "<@&\($0)>" }.joined(separator: " ")
        let allowedMentions: [String: Any]? = cleanedRoleIDs.isEmpty ? nil : [
            "parse": [],
            "roles": cleanedRoleIDs
        ]

        var payload: [String: Any] = [:]
        if let rawEmbedJSON = embedJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawEmbedJSON.isEmpty,
           let data = rawEmbedJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let embeds = object["embeds"] as? [Any],
           !embeds.isEmpty {
            payload["embeds"] = embeds
            if !roleMentionText.isEmpty {
                payload["content"] = roleMentionText
            }
            if let allowedMentions {
                payload["allowed_mentions"] = allowedMentions
            }
        } else {
            let fallbackBody = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = [roleMentionText, fallbackBody].filter { !$0.isEmpty }.joined(separator: " ")
            payload["content"] = content.isEmpty ? "Patchy update available." : content
            if let allowedMentions {
                payload["allowed_mentions"] = allowedMentions
            }
        }

        do {
            _ = try await sendPayloadResponse(
                channelId: channelId,
                payload: payload,
                action: "sendPatchyNotification"
            )
            let detail = "Notification sent successfully."
            logs.append("✅ Patchy: \(detail)")
            return (true, detail)
        } catch {
            let diagnostic = patchyErrorDiagnostic(from: error)
            logs.append("❌ Patchy: \(diagnostic)")
            return (false, diagnostic)
        }
    }

}
