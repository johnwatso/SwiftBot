import Foundation

struct DiscordMessageRESTClient {
    let session: URLSession
    let restBase: URL

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
        var req = URLRequest(url: restBase.appendingPathComponent("channels/\(channelId)/messages/\(messageId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to edit message"])
        }
    }
}

private struct DiscordRESTMessageEnvelope: Decodable {
    let id: String
}
