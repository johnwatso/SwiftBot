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

    func sendTypingIndicator(_ channelId: String) async {
        await service.triggerTyping(channelId: channelId, token: settings.token)
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
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "sendMessage", log: { logs.append($0) }) else { return false }
        do {
            try await service.sendMessage(channelId: channelId, content: message, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func sendMessageReturningID(channelId: String, content: String) async -> String? {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "sendMessageReturningID", log: { logs.append($0) }) else { return nil }
        do {
            return try await service.sendMessageReturningID(channelId: channelId, content: content, token: settings.token)
        } catch {
            return nil
        }
    }

    func sendEmbed(_ channelId: String, embed: [String: Any]) async -> Bool {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "sendEmbed", log: { logs.append($0) }) else { return false }
        do {
            _ = try await service.sendMessage(
                channelId: channelId,
                payload: ["embeds": [embed]],
                token: settings.token
            )
            return true
        } catch {
            return false
        }
    }

    func editMessage(channelId: String, messageId: String, content: String) async -> Bool {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "editMessage", log: { logs.append($0) }) else { return false }
        do {
            try await service.editMessage(channelId: channelId, messageId: messageId, content: content, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func fetchMessage(channelId: String, messageId: String) async -> [String: DiscordJSON]? {
        do {
            return try await service.fetchMessage(channelId: channelId, messageId: messageId, token: settings.token)
        } catch {
            return nil
        }
    }

    func fetchRecentMessages(channelId: String, limit: Int = 30) async -> [[String: DiscordJSON]] {
        do {
            return try await service.fetchRecentMessages(channelId: channelId, limit: limit, token: settings.token)
        } catch {
            return []
        }
    }

    func addReaction(channelId: String, messageId: String, emoji: String) async -> Bool {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "addReaction", log: { logs.append($0) }) else { return false }
        do {
            try await service.addReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String) async -> Bool {
        do {
            try await service.removeOwnReaction(channelId: channelId, messageId: messageId, emoji: emoji, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func pinMessage(channelId: String, messageId: String) async -> Bool {
        do {
            try await service.pinMessage(channelId: channelId, messageId: messageId, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func unpinMessage(channelId: String, messageId: String) async -> Bool {
        do {
            try await service.unpinMessage(channelId: channelId, messageId: messageId, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String) async -> Bool {
        do {
            try await service.createThreadFromMessage(channelId: channelId, messageId: messageId, name: name, token: settings.token)
            return true
        } catch {
            return false
        }
    }

    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String
    ) async -> Bool {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "sendMessageWithImage", log: { logs.append($0) }) else { return false }
        do {
            _ = try await service.sendMessageWithImage(
                channelId: channelId,
                content: content,
                imageData: imageData,
                filename: filename,
                token: settings.token
            )
            return true
        } catch {
            return false
        }
    }

    func editMessageWithImage(
        channelId: String,
        messageId: String,
        content: String,
        imageData: Data,
        filename: String
    ) async -> Bool {
        guard ActionDispatcher.canSend(clusterMode: settings.clusterMode, action: "editMessageWithImage", log: { logs.append($0) }) else { return false }
        do {
            try await service.editMessageWithImage(
                channelId: channelId,
                messageId: messageId,
                content: content,
                imageData: imageData,
                filename: filename,
                token: settings.token
            )
            return true
        } catch {
            return false
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
        var usingEmbedPayload = false
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
            usingEmbedPayload = true
        } else {
            let fallbackBody = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = [roleMentionText, fallbackBody].filter { !$0.isEmpty }.joined(separator: " ")
            payload["content"] = content.isEmpty ? "Patchy update available." : content
            if let allowedMentions {
                payload["allowed_mentions"] = allowedMentions
            }
        }

        do {
            let response = try await service.sendMessage(channelId: channelId, payload: payload, token: token)
            let mode = usingEmbedPayload ? "embed" : "fallback"
            let detail = "Patchy send succeeded (\(mode), status=\(response.statusCode))."
            logs.append("✅ \(detail)")
            return (true, detail)
        } catch {
            let diagnostic = patchyErrorDiagnostic(from: error)
            let detail = "Patchy send failed (\(usingEmbedPayload ? "embed" : "fallback")). \(diagnostic)"
            logs.append("❌ \(detail)")
            return (false, detail)
        }
    }

}
