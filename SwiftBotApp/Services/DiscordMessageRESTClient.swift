import Foundation

struct DiscordMessageRESTClient {
    static let defaultRestBase = URL(string: "https://discord.com/api/v10")!

    let session: URLSession
    let restBase: URL

    init(session: URLSession, restBase: URL = DiscordMessageRESTClient.defaultRestBase) {
        self.session = session
        self.restBase = restBase
    }

    func sendMessage(channelId: String, content: String, token: String) async throws {
        let payloadData = try Self.encodeJSONObject(["content": content])
        _ = try await sendMessage(channelId: channelId, payloadData: payloadData, token: token)
    }

    func sendMessageReturningID(channelId: String, content: String, token: String) async throws -> String {
        let payloadData = try Self.encodeJSONObject(["content": content])
        return try await sendMessageReturningID(channelId: channelId, payloadData: payloadData, token: token)
    }

    func sendMessageReturningID(channelId: String, payload: [String: Any], token: String) async throws -> String {
        let payloadData = try Self.encodeJSONObject(payload)
        return try await sendMessageReturningID(channelId: channelId, payloadData: payloadData, token: token)
    }

    func sendMessageReturningID(channelId: String, payloadData: Data, token: String) async throws -> String {
        let response = try await sendMessage(channelId: channelId, payloadData: payloadData, token: token)
        guard let data = response.responseBody.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(DiscordRESTMessageEnvelope.self, from: data) else {
            throw NSError(
                domain: "DiscordService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to parse Discord message id"]
            )
        }
        return decoded.id
    }

    @discardableResult
    func sendMessage(
        channelId: String,
        payload: [String: Any],
        token: String
    ) async throws -> (statusCode: Int, responseBody: String) {
        let payloadData = try Self.encodeJSONObject(payload)
        return try await sendMessage(channelId: channelId, payloadData: payloadData, token: token)
    }

    @discardableResult
    func sendMessage(
        channelId: String,
        payloadData: Data,
        token: String
    ) async throws -> (statusCode: Int, responseBody: String) {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payloadData

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(
                domain: "DiscordService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response",
                    "statusCode": -1,
                    "responseBody": ""
                ]
            )
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        if http.statusCode == 429 {
            throw NSError(
                domain: "DiscordService",
                code: 429,
                userInfo: [
                    NSLocalizedDescriptionKey: "Rate limited",
                    "statusCode": http.statusCode,
                    "responseBody": responseBody
                ]
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to send message",
                    "statusCode": http.statusCode,
                    "responseBody": responseBody
                ]
            )
        }
        return (http.statusCode, responseBody)
    }

    func editMessage(channelId: String, messageId: String, content: String, token: String) async throws {
        let payloadData = try Self.encodeJSONObject(["content": content])
        try await editMessage(channelId: channelId, messageId: messageId, payloadData: payloadData, token: token)
    }

    func editMessage(channelId: String, messageId: String, payload: [String: Any], token: String) async throws {
        let payloadData = try Self.encodeJSONObject(payload)
        try await editMessage(channelId: channelId, messageId: messageId, payloadData: payloadData, token: token)
    }

    func editMessage(channelId: String, messageId: String, payloadData: Data, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = payloadData
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to edit message", "responseBody": responseBody]
            )
        }
    }

    private static func encodeJSONObject(_ payload: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: payload)
    }

    func fetchMessage(channelId: String, messageId: String, token: String) async throws -> [String: DiscordJSON] {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch message", "responseBody": responseBody]
            )
        }
        return try JSONDecoder().decode([String: DiscordJSON].self, from: data)
    }

    func fetchRecentMessages(channelId: String, limit: Int, token: String, before: String? = nil) async throws -> [[String: DiscordJSON]] {
        var components = URLComponents(url: restBase.appendingPathComponent("channels/\(channelId)/messages"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
        if let before, !before.isEmpty {
            items.append(URLQueryItem(name: "before", value: before))
        }
        components?.queryItems = items
        guard let url = components?.url else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid messages URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch recent messages", "responseBody": responseBody]
            )
        }
        return try JSONDecoder().decode([[String: DiscordJSON]].self, from: data)
    }

    func addReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/reactions/\(encodedEmoji)/@me"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add reaction"])
        }
    }

    func removeOwnReaction(channelId: String, messageId: String, emoji: String, token: String) async throws {
        let encodedEmoji = emoji.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? emoji
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/reactions/\(encodedEmoji)/@me"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to remove reaction", "responseBody": responseBody]
            )
        }
    }

    func pinMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/pins/\(messageId)"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to pin message", "responseBody": responseBody]
            )
        }
    }

    func unpinMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/pins/\(messageId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to unpin message", "responseBody": responseBody]
            )
        }
    }

    func createThreadFromMessage(channelId: String, messageId: String, name: String, token: String) async throws -> String {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)/threads"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "auto_archive_duration": 1440
        ])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create thread", "responseBody": responseBody]
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              !id.isEmpty else {
            throw NSError(domain: "DiscordService", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse thread id"])
        }
        return id
    }

    @discardableResult
    func sendMessageWithImage(
        channelId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let url = restBase.appendingPathComponent("channels/\(channelId)/messages")
        return try await sendMultipartImage(
            url: url,
            method: "POST",
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    /// Sends a message whose JSON `payload` (embeds, content, allowed_mentions,
    /// …) references an uploaded file via `attachment://<filename>`. The file is
    /// attached as `files[0]` and registered in the payload's `attachments`.
    @discardableResult
    func sendMessageWithEmbedImage(
        channelId: String,
        payload: [String: Any],
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let url = restBase.appendingPathComponent("channels/\(channelId)/messages")
        var merged = payload
        merged["attachments"] = [["id": "0", "filename": filename]]
        return try await sendMultipartPayload(
            url: url,
            method: "POST",
            payload: merged,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    func editMessageWithImage(
        channelId: String,
        messageId: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws {
        let url = restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)")
        _ = try await sendMultipartImage(
            url: url,
            method: "PATCH",
            content: content,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    func triggerTyping(channelId: String, token: String) async {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/typing"))
        req.httpMethod = "POST"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await session.data(for: req)
    }

    func deleteMessage(channelId: String, messageId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete message", "responseBody": responseBody]
            )
        }
    }

    /// Fetch a guild's custom emoji as `(name, id, animated)` tuples, so callers
    /// can convert `:name:` shorthand into the `<:name:id>` token bots must use.
    func fetchGuildEmojis(guildId: String, token: String) async throws -> [(name: String, id: String, animated: Bool)] {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/emojis"))
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch guild emojis", "responseBody": responseBody]
            )
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { obj in
            guard let name = obj["name"] as? String, let id = obj["id"] as? String else { return nil }
            return (name, id, (obj["animated"] as? Bool) ?? false)
        }
    }

    /// Bulk-delete 2–100 messages in a single request. Discord rejects the
    /// whole batch (400) if any message is older than 14 days or a duplicate,
    /// so the caller must pre-filter to recent, unique IDs.
    func bulkDeleteMessages(channelId: String, messageIds: [String], token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/bulk-delete"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["messages": messageIds])
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to bulk-delete messages", "responseBody": responseBody]
            )
        }
    }

    func fetchChannel(channelId: String, token: String) async throws -> [String: DiscordJSON] {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)"))
        req.httpMethod = "GET"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to fetch channel",
                    "statusCode": (response as? HTTPURLResponse)?.statusCode ?? -1,
                    "responseBody": responseBody
                ]
            )
        }
        return try JSONDecoder().decode([String: DiscordJSON].self, from: data)
    }

    func createDirectMessageChannel(userId: String, token: String) async throws -> String {
        var req = URLRequest(url: restBase.appendingPathComponent("users/@me/channels"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["recipient_id": userId])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DM channel"])
        }

        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let channelId = json["id"] as? String else {
                throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DM channel"])
            }
            return channelId
        } catch {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DM channel"])
        }
    }

    private func sendMultipartImage(
        url: URL,
        method: String,
        content: String,
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let payload: [String: Any] = [
            "content": content,
            "attachments": [
                [
                    "id": "0",
                    "filename": filename
                ]
            ]
        ]
        return try await sendMultipartPayload(
            url: url,
            method: method,
            payload: payload,
            imageData: imageData,
            filename: filename,
            token: token
        )
    }

    private func sendMultipartPayload(
        url: URL,
        method: String,
        payload: [String: Any],
        imageData: Data,
        filename: String,
        token: String
    ) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 90
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        var body = Data()
        func appendString(_ value: String) {
            body.append(Data(value.utf8))
        }

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n")
        body.append(payloadData)
        appendString("\r\n")

        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: image/png\r\n\r\n")
        body.append(imageData)
        appendString("\r\n")
        appendString("--\(boundary)--\r\n")

        req.httpBody = body
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to upload image", "responseBody": responseBody]
            )
        }

        if let decoded = try? JSONDecoder().decode(DiscordRESTMessageEnvelope.self, from: data) {
            return decoded.id
        }
        return ""
    }
}

private struct DiscordRESTMessageEnvelope: Decodable {
    let id: String
}
