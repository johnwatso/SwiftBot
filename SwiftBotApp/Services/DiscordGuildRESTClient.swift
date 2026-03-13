import Foundation

struct DiscordGuildRESTClient {
    static let defaultRestBase = URL(string: "https://discord.com/api/v10")!

    let session: URLSession
    let restBase: URL

    init(
        session: URLSession,
        restBase: URL = DiscordGuildRESTClient.defaultRestBase
    ) {
        self.session = session
        self.restBase = restBase
    }

    func fetchGuildOwnerID(guildID: String, token: String) async -> String? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedToken.isEmpty else { return nil }

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(trimmedToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let ownerID = json["owner_id"] as? String,
                !ownerID.isEmpty
            else {
                return nil
            }
            return ownerID
        } catch {
            return nil
        }
    }

    func fetchGuildMemberRoleIDs(guildID: String, userID: String, token: String) async -> [String]? {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedUserID.isEmpty, !trimmedToken.isEmpty else { return nil }

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)/members/\(trimmedUserID)"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(trimmedToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let roles = json["roles"] as? [String] else {
                return nil
            }
            return roles
        } catch {
            return nil
        }
    }

    func addRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)/roles/\(roleId)"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add role"])
        }
    }

    func removeRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)/roles/\(roleId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to remove role"])
        }
    }

    func timeoutMember(guildId: String, userId: String, durationSeconds: Int, token: String) async throws {
        let until = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = ["communication_disabled_until": formatter.string(from: until)]

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to timeout member"])
        }
    }

    func kickMember(guildId: String, userId: String, reason: String, token: String) async throws {
        var components = URLComponents(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"), resolvingAgainstBaseURL: false)
        if !reason.isEmpty {
            components?.queryItems = [URLQueryItem(name: "reason", value: reason)]
        }
        guard let url = components?.url else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to kick member"])
        }
    }

    func moveMember(guildId: String, userId: String, channelId: String, token: String) async throws {
        let body: [String: Any] = ["channel_id": channelId.isEmpty ? NSNull() : channelId]
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to move member"])
        }
    }

    func createChannel(guildId: String, name: String, token: String) async throws {
        let body: [String: Any] = ["name": name, "type": 0]
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/channels"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create channel"])
        }
    }
}
