import Foundation

struct DiscordIdentityRESTClient {
    static let defaultRestBase = URL(string: "https://discord.com/api/v10")!

    static func makeIdentitySession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    let session: URLSession
    let identitySession: URLSession
    let restBase: URL

    init(
        session: URLSession,
        identitySession: URLSession = DiscordIdentityRESTClient.makeIdentitySession(),
        restBase: URL = DiscordIdentityRESTClient.defaultRestBase
    ) {
        self.session = session
        self.identitySession = identitySession
        self.restBase = restBase
    }

    func validateBotTokenRich(_ token: String) async -> DiscordService.TokenValidationResult {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return DiscordService.TokenValidationResult(
                isValid: false,
                userId: nil,
                username: nil,
                discriminator: nil,
                avatarURL: nil,
                errorCategory: .invalidToken,
                errorMessage: "Token is empty."
            )
        }

        var req = URLRequest(url: restBase.appendingPathComponent("users/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.networkFailure)
            }

            switch http.statusCode {
            case 200..<300:
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let userId = json?["id"] as? String
                let username = json?["username"] as? String
                let discriminator = json?["discriminator"] as? String
                let avatarHash = json?["avatar"] as? String
                let avatarURL: URL?
                if let userId, let avatarHash, !avatarHash.isEmpty {
                    avatarURL = URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(avatarHash).png")
                } else {
                    avatarURL = nil
                }
                return DiscordService.TokenValidationResult(
                    isValid: true,
                    userId: userId,
                    username: username,
                    discriminator: discriminator,
                    avatarURL: avatarURL,
                    errorCategory: nil,
                    errorMessage: "Valid token"
                )
            case 401:
                return .failure(.invalidToken)
            case 429:
                return .failure(.rateLimited)
            default:
                return .failure(.serverError(http.statusCode))
            }
        } catch {
            return .failure(.networkFailure)
        }
    }

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

    func resolveClientID(token: String) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var req = URLRequest(url: restBase.appendingPathComponent("oauth2/applications/@me"))
        req.httpMethod = "GET"
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appID = json["id"] as? String else {
                return nil
            }
            return appID
        } catch {
            return nil
        }
    }

    func restHealthProbe(token: String) async -> (isOK: Bool, httpStatus: Int?, rateLimitRemaining: Int?) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, nil, nil) }
        var req = URLRequest(url: restBase.appendingPathComponent("users/@me"))
        req.setValue("Bot \(trimmed)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        do {
            let (_, response) = try await identitySession.data(for: req)
            guard let http = response as? HTTPURLResponse else { return (false, nil, nil) }
            let remaining = (http.value(forHTTPHeaderField: "X-RateLimit-Remaining"))
                .flatMap { Int($0) }
            return (http.statusCode == 200, http.statusCode, remaining)
        } catch {
            return (false, nil, nil)
        }
    }
}
