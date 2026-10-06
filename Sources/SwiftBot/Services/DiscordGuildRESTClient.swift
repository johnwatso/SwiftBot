import Foundation

struct DiscordGuildRESTClient {
    static let defaultRestBase = URL(string: "https://discord.com/api/v10")!

    let restBase: URL
    private let transport: DiscordRESTTransport

    init(
        session: URLSession,
        restBase: URL = DiscordGuildRESTClient.defaultRestBase,
        limiter: DiscordRateLimiter = .shared
    ) {
        self.restBase = restBase
        self.transport = DiscordRESTTransport(session: session, limiter: limiter)
    }

    func fetchGuildInvites(guildID: String, token: String) async throws -> [WelcomeFlowService.InviteSnapshot] {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedToken.isEmpty else { return [] }

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)/invites"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(trimmedToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "DiscordService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to fetch guild invites"]
            )
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return array.compactMap { item in
            guard let code = item["code"] as? String, !code.isEmpty else { return nil }
            let channel = item["channel"] as? [String: Any]
            let inviter = item["inviter"] as? [String: Any]
            return WelcomeFlowService.InviteSnapshot(
                code: code,
                channelID: channel?["id"] as? String,
                channelName: channel?["name"] as? String,
                inviterID: inviter?["id"] as? String,
                uses: item["uses"] as? Int ?? 0
            )
        }
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
            let (data, response) = try await transport.perform(req)
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
            let (data, response) = try await transport.perform(req)
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
        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to add role"])
        }
    }

    func removeRole(guildId: String, userId: String, roleId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)/roles/\(roleId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to remove role"])
        }
    }

    func timeoutMember(guildId: String, userId: String, durationSeconds: Int, token: String) async throws {
        guard (1...2419200).contains(durationSeconds) else {
            throw ValidationError.outOfRange("durationSeconds", min: 1, max: 2419200)
        }
        let until = Date().addingTimeInterval(TimeInterval(durationSeconds))
        let formatter = ISO8601DateFormatter()
        let body: [String: Any] = ["communication_disabled_until": formatter.string(from: until)]

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to timeout member"])
        }
    }

    func kickMember(guildId: String, userId: String, reason: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "DELETE"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        setAuditReason(reason, on: &req)
        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to kick member"])
        }
    }

    func removeTimeout(guildId: String, userId: String, token: String) async throws {
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["communication_disabled_until": NSNull()])
        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to remove member timeout"])
        }
    }

    func banMember(guildId: String, userId: String, reason: String, deleteMessageSeconds: Int, token: String) async throws {
        guard (0...604800).contains(deleteMessageSeconds) else {
            throw ValidationError.outOfRange("deleteMessageSeconds", min: 0, max: 604800)
        }
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/bans/\(userId)"))
        req.httpMethod = "PUT"
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        setAuditReason(reason, on: &req)
        req.httpBody = try JSONSerialization.data(withJSONObject: ["delete_message_seconds": deleteMessageSeconds])
        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to ban member"])
        }
    }

    private func setAuditReason(_ reason: String, on request: inout URLRequest) {
        guard !reason.isEmpty else { return }
        let encoded = String(reason.prefix(512)).addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        request.setValue(encoded, forHTTPHeaderField: "X-Audit-Log-Reason")
    }

    func moveMember(guildId: String, userId: String, channelId: String, token: String) async throws {
        let body: [String: Any] = ["channel_id": channelId.isEmpty ? NSNull() : channelId]
        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(guildId)/members/\(userId)"))
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await transport.perform(req)
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

        let (_, response) = try await transport.perform(req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create channel"])
        }
    }
}

struct DiscordScheduledEvent: Codable, Sendable, Identifiable, Hashable {
    let id: String
    let guildId: String
    let name: String
    let description: String?
    let scheduledStartTime: String
    let scheduledEndTime: String?
    let status: Int
    let image: String?
    let userCount: Int?
    enum CodingKeys: String, CodingKey {
        case id, name, description, status, image
        case guildId = "guild_id"
        case scheduledStartTime = "scheduled_start_time"
        case scheduledEndTime = "scheduled_end_time"
        case userCount = "user_count"
    }
    var startDate: Date? { Automations.Schedule.parse(scheduledStartTime) }
    var url: String { "https://discord.com/events/" + guildId + "/" + id }
    var imageURL: String? { image.map { "https://cdn.discordapp.com/guild-events/" + id + "/" + $0 + ".png" } }
}
extension DiscordGuildRESTClient {
    func fetchScheduledEvents(guildID: String, token: String) async throws -> [DiscordScheduledEvent] {
        guard !guildID.isEmpty, !token.isEmpty else { return [] }
        let endpoint = restBase.appendingPathComponent("guilds/\(guildID)/scheduled-events")
            .appending(queryItems: [URLQueryItem(name: "with_user_count", value: "true")])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("Bot " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.perform(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not load Discord scheduled events"])
        }
        return try JSONDecoder().decode([DiscordScheduledEvent].self, from: data)
    }
}
