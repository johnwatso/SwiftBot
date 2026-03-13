import Foundation

struct DiscordInteractionRESTClient {
    let session: URLSession
    let restBase: URL

    func registerGlobalApplicationCommands(
        applicationID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        let trimmedAppID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppID.isEmpty else { return }
        var req = URLRequest(url: restBase.appendingPathComponent("applications/\(trimmedAppID)/commands"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: commands)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to register slash commands",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func registerGuildApplicationCommands(
        applicationID: String,
        guildID: String,
        commands: [[String: Any]],
        token: String
    ) async throws {
        let trimmedAppID = applicationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAppID.isEmpty, !trimmedGuildID.isEmpty else { return }
        var req = URLRequest(url: restBase.appendingPathComponent("applications/\(trimmedAppID)/guilds/\(trimmedGuildID)/commands"))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: commands)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to register guild slash commands",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func respondToInteraction(
        interactionID: String,
        interactionToken: String,
        payload: [String: Any]
    ) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("interactions/\(interactionID)/\(interactionToken)/callback"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to respond to interaction",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func editOriginalInteractionResponse(
        applicationID: String,
        interactionToken: String,
        payload: [String: Any]
    ) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("webhooks/\(applicationID)/\(interactionToken)/messages/@original"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to edit interaction response",
                    "responseBody": String(data: data, encoding: .utf8) ?? ""
                ]
            )
        }
    }

    func sendWebhook(url: String, content: String) async throws {
        guard let webhookUrl = URL(string: url) else { return }
        var req = URLRequest(url: webhookUrl)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["content": content])

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to send webhook"])
        }
    }
}
