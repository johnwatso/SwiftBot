import Foundation

struct CloudflareTunnelClient: Sendable {
    struct TunnelSummary: Sendable, Equatable {
        let accountID: String
        let id: String
        let name: String
        let token: String
    }

    enum Error: LocalizedError {
        case missingAccountID
        case invalidResponse
        case apiFailed(String)

        var errorDescription: String? {
            switch self {
            case .missingAccountID:
                return "Cloudflare did not return an account ID for the selected zone."
            case .invalidResponse:
                return "Cloudflare returned an invalid tunnel response."
            case .apiFailed(let message):
                return message
            }
        }
    }

    private struct APIError: Decodable {
        let code: Int?
        let message: String
    }

    private struct APIEnvelope<ResultType: Decodable>: Decodable {
        let success: Bool
        let result: ResultType?
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent(ResultType.self, forKey: .result)
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct CreateTunnelRequest: Encodable {
        let name: String
        let configSrc: String

        private enum CodingKeys: String, CodingKey {
            case name
            case configSrc = "config_src"
        }
    }

    private struct TunnelConfigurationRequest: Encodable {
        let config: TunnelConfiguration
    }

    private struct TunnelConfiguration: Encodable {
        let ingress: [TunnelIngressRule]
    }

    private struct TunnelIngressRule: Encodable {
        let hostname: String?
        let service: String
    }

    private struct TunnelResponse: Decodable {
        let id: String
        let name: String
        let token: String?
    }

    private struct IgnoredResult: Decodable {
        init(from decoder: Decoder) throws {}
    }

    private let apiToken: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    init(apiToken: String, session: URLSession = .shared) {
        self.apiToken = apiToken
        self.session = session
    }

    func createTunnel(hostname: String, zone: CloudflareDNSProvider.ZoneSummary) async throws -> TunnelSummary {
        let accountID = try await resolveAccountID(for: zone)
        let requestURL = baseURL
            .appendingPathComponent("accounts")
            .appendingPathComponent(accountID)
            .appendingPathComponent("cfd_tunnel")

        let sanitizedName = Self.tunnelName(for: hostname)
        var request = makeRequest(url: requestURL, method: "POST")
        request.httpBody = try encoder.encode(CreateTunnelRequest(name: sanitizedName, configSrc: "cloudflare"))

        let envelope: APIEnvelope<TunnelResponse> = try await send(request)
        guard envelope.success, let tunnel = envelope.result else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare tunnel creation failed."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        let token = try await fetchTunnelTokenIfNeeded(
            accountID: accountID,
            tunnelID: tunnel.id,
            inlineToken: tunnel.token
        )

        return TunnelSummary(
            accountID: accountID,
            id: tunnel.id,
            name: tunnel.name,
            token: token
        )
    }

    func configureTunnel(_ tunnel: TunnelSummary, hostname: String, originURL: String) async throws {
        let requestURL = baseURL
            .appendingPathComponent("accounts")
            .appendingPathComponent(tunnel.accountID)
            .appendingPathComponent("cfd_tunnel")
            .appendingPathComponent(tunnel.id)
            .appendingPathComponent("configurations")

        let config = TunnelConfigurationRequest(
            config: TunnelConfiguration(
                ingress: [
                    TunnelIngressRule(hostname: hostname, service: originURL),
                    TunnelIngressRule(hostname: nil, service: "http_status:404")
                ]
            )
        )

        var request = makeRequest(url: requestURL, method: "PUT")
        request.httpBody = try encoder.encode(config)

        let envelope: APIEnvelope<IgnoredResult> = try await send(request)
        guard envelope.success else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare tunnel configuration failed."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }
    }

    func deleteTunnel(accountID: String, tunnelID: String) async throws {
        let requestURL = baseURL
            .appendingPathComponent("accounts")
            .appendingPathComponent(accountID)
            .appendingPathComponent("cfd_tunnel")
            .appendingPathComponent(tunnelID)

        let request = makeRequest(url: requestURL, method: "DELETE")
        let envelope: APIEnvelope<IgnoredResult> = try await send(request)
        guard envelope.success else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare tunnel deletion failed."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }
    }

    static func tunnelTargetHostname(for tunnelID: String) -> String {
        "\(tunnelID).cfargotunnel.com"
    }

    private func fetchTunnelTokenIfNeeded(accountID: String, tunnelID: String, inlineToken: String?) async throws -> String {
        if let inlineToken, !inlineToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inlineToken
        }

        let requestURL = baseURL
            .appendingPathComponent("accounts")
            .appendingPathComponent(accountID)
            .appendingPathComponent("cfd_tunnel")
            .appendingPathComponent(tunnelID)
            .appendingPathComponent("token")

        let request = makeRequest(url: requestURL, method: "GET")
        let envelope: APIEnvelope<String> = try await send(request)
        guard envelope.success, let token = envelope.result, !token.isEmpty else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare did not return a tunnel token."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        return token
    }

    private func resolveAccountID(for zone: CloudflareDNSProvider.ZoneSummary) async throws -> String {
        if let accountID = zone.accountID, !accountID.isEmpty {
            return accountID
        }

        let requestURL = baseURL
            .appendingPathComponent("zones")
            .appendingPathComponent(zone.id)

        let request = makeRequest(url: requestURL, method: "GET")
        let envelope: APIEnvelope<ZoneDetails> = try await send(request)
        guard envelope.success, let details = envelope.result, let accountID = details.account?.id, !accountID.isEmpty else {
            throw Error.missingAccountID
        }

        return accountID
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send<ResultType: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<ResultType> {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }

        let envelope = try decoder.decode(APIEnvelope<ResultType>.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        return envelope
    }

    private static func tunnelName(for hostname: String) -> String {
        let normalized = hostname
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
        let trimmed = normalized.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let prefix = trimmed.isEmpty ? "swiftbot-public-access" : "swiftbot-\(trimmed)"
        return String(prefix.prefix(62))
    }
}

private struct ZoneDetails: Decodable {
    let account: ZoneAccountReference?
}

private struct ZoneAccountReference: Decodable {
    let id: String
}
