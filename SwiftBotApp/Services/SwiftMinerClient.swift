import Foundation

struct SwiftMinerUserProjection: Codable, Sendable {
    enum State: String, Codable, Sendable {
        case notConfigured
        case active
        case idle
        case blocked
    }

    struct Account: Codable, Sendable {
        let twitchAccountId: String
        let username: String
    }

    struct Campaign: Codable, Sendable {
        let campaignId: String
        let game: String
        let progress: Progress
        let endsAt: Date?
    }

    struct Progress: Codable, Sendable {
        let current: Int
        let required: Int
        let unit: String
        let pct: Int
    }

    struct Issue: Codable, Sendable {
        let issueId: String
        let type: String
        let campaignId: String?
        let game: String?
        let message: String
        let action: String
    }

    let discordUserId: String
    let state: State
    let account: Account?
    let activeCampaign: Campaign?
    let issues: [Issue]
}

struct SwiftMinerActivationSession: Codable, Sendable {
    let sessionId: String
    let userCode: String
    let verificationUri: String
    let expiresAt: Date
    let intervalSeconds: Int
}

struct SwiftMinerActivationStatus: Codable, Sendable {
    let sessionId: String
    let status: String
    let linkedAccountId: String?
    let twitchUsername: String?
    let failureReason: String?
}

enum SwiftMinerClientError: LocalizedError {
    case disabled
    case invalidBaseURL
    case missingAPIKey
    case http(status: Int, code: String?, message: String?)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "SwiftMiner integration is disabled."
        case .invalidBaseURL:
            return "SwiftMiner base URL is invalid."
        case .missingAPIKey:
            return "SwiftMiner API key is not configured."
        case .http(let status, let code, let message):
            let detail = message ?? code ?? "Request failed."
            return "SwiftMiner returned \(status): \(detail)"
        }
    }
}

struct SwiftMinerClient {
    private let settings: SwiftMinerSettings
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    init(settings: SwiftMinerSettings, session: URLSession) {
        self.settings = settings
        self.session = session
    }

    func health() async throws -> Bool {
        let data = try await request(path: "/health", method: "GET", requiresAuth: false)
        return !data.isEmpty
    }

    func registerUser(discordUserId: String) async throws {
        struct Body: Encodable { let discordUserId: String }
        _ = try await request(path: "/v1/users", method: "POST", body: Body(discordUserId: discordUserId))
    }

    func projection(discordUserId: String) async throws -> SwiftMinerUserProjection {
        let data = try await request(path: "/v1/discord/users/\(discordUserId)", method: "GET")
        return try decoder.decode(SwiftMinerUserProjection.self, from: data)
    }

    func startActivation(discordUserId: String) async throws -> SwiftMinerActivationSession {
        let data = try await request(path: "/v1/users/\(discordUserId)/activation", method: "POST")
        return try decoder.decode(SwiftMinerActivationSession.self, from: data)
    }

    func ignoreCampaign(discordUserId: String, campaignId: String, scope: String) async throws {
        struct Body: Encodable { let scope: String }
        _ = try await request(
            path: "/v1/users/\(discordUserId)/campaigns/\(campaignId)/ignore",
            method: "POST",
            body: Body(scope: scope)
        )
    }

    private func request<T: Encodable>(
        path: String,
        method: String,
        body: T,
        requiresAuth: Bool = true
    ) async throws -> Data {
        try await request(path: path, method: method, bodyData: try encoder.encode(body), requiresAuth: requiresAuth)
    }

    private func request(
        path: String,
        method: String,
        bodyData: Data? = nil,
        requiresAuth: Bool = true
    ) async throws -> Data {
        guard settings.enabled else { throw SwiftMinerClientError.disabled }
        guard URL(string: settings.normalizedBaseURL) != nil else {
            throw SwiftMinerClientError.invalidBaseURL
        }
        if requiresAuth, settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SwiftMinerClientError.missingAPIKey
        }

        guard let url = URL(string: settings.normalizedBaseURL + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) else {
            throw SwiftMinerClientError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        if requiresAuth {
            request.setValue("Bot \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let bodyData {
            request.httpBody = bodyData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(SwiftMinerErrorEnvelope.self, from: data)
            throw SwiftMinerClientError.http(
                status: http.statusCode,
                code: envelope?.error,
                message: envelope?.message
            )
        }
        return data
    }
}

private struct SwiftMinerErrorEnvelope: Codable {
    let error: String?
    let message: String?
}
