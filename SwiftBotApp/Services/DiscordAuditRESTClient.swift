import Foundation

/// Ingestion client for the Audit feature. Mirrors `DiscordGuildRESTClient`:
/// a value type holding the session + base URL, every call takes the bot token,
/// raw `URLSession` + `JSONSerialization`, errors thrown as `NSError`.
struct DiscordAuditRESTClient {
    static let defaultRestBase = URL(string: "https://discord.com/api/v10")!

    /// Discord snowflakes encode their creation time: (id >> 22) + Discord epoch.
    private static let discordEpochMs: Int64 = 1_420_070_400_000

    let session: URLSession
    let restBase: URL

    init(session: URLSession, restBase: URL = DiscordAuditRESTClient.defaultRestBase) {
        self.session = session
        self.restBase = restBase
    }

    // MARK: - Roles

    func fetchRoles(guildID: String, token: String) async throws -> [AuditRole] {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedToken.isEmpty else { return [] }

        var req = URLRequest(url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)/roles"))
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(trimmedToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to fetch roles"])
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array.compactMap(Self.parseRole)
    }

    // MARK: - Audit log

    /// Fetches the most recent audit-log entries and keeps the role-relevant
    /// ones. A single unfiltered request (rather than one per action type) keeps
    /// us gentle on rate limits; role events are correlated downstream.
    func fetchAuditLog(guildID: String, token: String, limit: Int = 100) async throws -> [DiscordAuditEvent] {
        let trimmedGuildID = guildID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuildID.isEmpty, !trimmedToken.isEmpty else { return [] }

        var components = URLComponents(
            url: restBase.appendingPathComponent("guilds/\(trimmedGuildID)/audit-logs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "limit", value: String(max(1, min(limit, 100))))]
        guard let url = components?.url else { return [] }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bot \(trimmedToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "DiscordService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to fetch audit log"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Build an id→username map from the embedded users array so the UI can
        // show "by John" instead of a raw snowflake.
        var actorNames: [String: String] = [:]
        if let users = json["users"] as? [[String: Any]] {
            for user in users {
                if let id = user["id"] as? String {
                    let name = (user["global_name"] as? String) ?? (user["username"] as? String)
                    if let name { actorNames[id] = name }
                }
            }
        }

        guard let entries = json["audit_log_entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { Self.parseEvent($0, actorNames: actorNames) }
            .filter { $0.actionType != .other }
    }

    // MARK: - Parsing

    private static func parseRole(_ item: [String: Any]) -> AuditRole? {
        guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }

        let permissions: UInt64 = {
            if let s = item["permissions"] as? String { return UInt64(s) ?? 0 }
            if let n = item["permissions"] as? NSNumber { return n.uint64Value }
            return 0
        }()

        return AuditRole(
            id: id,
            name: name,
            colorRGB: (item["color"] as? Int) ?? 0,
            position: (item["position"] as? Int) ?? 0,
            permissions: permissions,
            hoist: (item["hoist"] as? Bool) ?? false,
            mentionable: (item["mentionable"] as? Bool) ?? false,
            managed: (item["managed"] as? Bool) ?? false,
            memberCount: nil
        )
    }

    private static func parseEvent(_ item: [String: Any], actorNames: [String: String]) -> DiscordAuditEvent? {
        guard let id = item["id"] as? String else { return nil }
        let actionCode = (item["action_type"] as? Int) ?? -1
        let actorID = item["user_id"] as? String

        let changes: [AuditChange] = (item["changes"] as? [[String: Any]] ?? []).map { change in
            AuditChange(
                key: (change["key"] as? String) ?? "",
                oldValue: stringValue(change["old_value"]),
                newValue: stringValue(change["new_value"])
            )
        }

        return DiscordAuditEvent(
            id: id,
            actionType: AuditActionType(rawCode: actionCode),
            actorID: actorID,
            actorName: actorID.flatMap { actorNames[$0] },
            targetID: item["target_id"] as? String,
            createdAt: date(fromSnowflake: id),
            changes: changes,
            reason: item["reason"] as? String
        )
    }

    private static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    private static func date(fromSnowflake snowflake: String) -> Date {
        guard let value = Int64(snowflake) else { return Date() }
        let ms = (value >> 22) + discordEpochMs
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}
