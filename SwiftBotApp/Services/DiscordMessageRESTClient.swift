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
        _ = try await sendMessage(channelId: channelId, payload: ["content": content], token: token)
    }

    func sendMessageReturningID(channelId: String, content: String, token: String) async throws -> String {
        let response = try await sendMessage(channelId: channelId, payload: ["content": content], token: token)
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
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

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
        try await editMessage(channelId: channelId, messageId: messageId, payload: ["content": content], token: token)
    }

    func editMessage(channelId: String, messageId: String, payload: [String: Any], token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to edit message"])
        }
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

    func fetchRecentMessages(channelId: String, limit: Int, token: String) async throws -> [[String: DiscordJSON]] {
        var components = URLComponents(url: restBase.appendingPathComponent("channels/\(channelId)/messages"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(100, limit))))]
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
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to delete message"])
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
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channelId = json["id"] as? String else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create DM channel"])
        }
        return channelId
    }

    private func sendMultipartImage(
        url: URL,
        method: String,
        content: String,
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

        let payload: [String: Any] = [
            "content": content,
            "attachments": [
                [
                    "id": "0",
                    "filename": filename
                ]
            ]
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"payload_json\"\r\n\r\n".data(using: .utf8)!)
        body.append(payloadData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"files[0]\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

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
