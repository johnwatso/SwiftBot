import Foundation

struct DiscordIdentityRESTClient {
    let session: URLSession
    let identitySession: URLSession
    let restBase: URL

    func validateBotToken(_ token: String) async -> (isValid: Bool, message: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return (false, "Token is empty.")
        }

        var req = URLRequest(url: restBase.appendingPathComponent("users/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return (false, "Discord returned an invalid response.")
            }
            if (200..<300).contains(http.statusCode) {
                return (true, "Valid token")
            }
            if http.statusCode == 401 {
                return (false, "Unauthorized (401). Token is invalid or revoked.")
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.isEmpty {
                return (false, "Discord API returned HTTP \(http.statusCode).")
            }
            return (false, "Discord API returned HTTP \(http.statusCode): \(body)")
        } catch {
            return (false, "Token validation request failed: \(error.localizedDescription)")
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
            let (data, response) = try await identitySession.data(for: req)
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
            let (data, response) = try await identitySession.data(for: req)
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
}
