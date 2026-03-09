import Foundation

struct CloudflareDNSProvider: Sendable {
    struct TXTRecord: Sendable, Equatable {
        let zoneID: String
        let recordID: String
        let name: String
        let content: String
    }

    enum Error: LocalizedError {
        case invalidDomain(String)
        case zoneNotFound(String)
        case apiFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDomain(let domain):
                return "Invalid Cloudflare DNS domain: \(domain)"
            case .zoneNotFound(let domain):
                return "Cloudflare zone not found for \(domain)"
            case .apiFailed(let message):
                return message
            }
        }
    }

    private struct APIEnvelope<ResultType: Decodable>: Decodable {
        struct APIError: Decodable {
            let code: Int?
            let message: String
        }

        let success: Bool
        let result: ResultType?
        let errors: [APIError]
    }

    private struct Zone: Decodable {
        let id: String
        let name: String
    }

    private struct DNSRecord: Decodable {
        let id: String
        let zoneID: String
        let name: String
        let content: String

        private enum CodingKeys: String, CodingKey {
            case id
            case zoneID = "zone_id"
            case name
            case content
        }
    }

    private struct CreateDNSRecordRequest: Encodable {
        let type = "TXT"
        let name: String
        let content: String
        let ttl: Int
    }

    private let apiToken: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    init(apiToken: String, session: URLSession = .shared) {
        self.apiToken = apiToken
        self.session = session
    }

    func createTXTRecord(name: String, content: String, ttl: Int = 120) async throws -> TXTRecord {
        let zoneID = try await resolveZoneID(for: name)
        let requestBody = CreateDNSRecordRequest(name: name, content: content, ttl: ttl)
        let requestURL = baseURL
            .appendingPathComponent("zones")
            .appendingPathComponent(zoneID)
            .appendingPathComponent("dns_records")

        var request = makeRequest(url: requestURL, method: "POST")
        request.httpBody = try encoder.encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let envelope: APIEnvelope<DNSRecord> = try await send(request)
        guard envelope.success, let record = envelope.result else {
            throw Error.apiFailed(envelope.errors.map(\.message).joined(separator: ", "))
        }

        return TXTRecord(
            zoneID: record.zoneID,
            recordID: record.id,
            name: record.name,
            content: record.content
        )
    }

    func deleteTXTRecord(_ record: TXTRecord) async throws {
        let requestURL = baseURL
            .appendingPathComponent("zones")
            .appendingPathComponent(record.zoneID)
            .appendingPathComponent("dns_records")
            .appendingPathComponent(record.recordID)

        let request = makeRequest(url: requestURL, method: "DELETE")
        let envelope: APIEnvelope<DNSRecord> = try await send(request)
        guard envelope.success else {
            throw Error.apiFailed(envelope.errors.map(\.message).joined(separator: ", "))
        }
    }

    func resolveZoneID(for fqdn: String) async throws -> String {
        for candidate in Self.zoneCandidates(for: fqdn) {
            var components = URLComponents(url: baseURL.appendingPathComponent("zones"), resolvingAgainstBaseURL: false)
            components?.queryItems = [
                URLQueryItem(name: "name", value: candidate),
                URLQueryItem(name: "per_page", value: "1")
            ]

            guard let url = components?.url else {
                throw Error.invalidDomain(fqdn)
            }

            let request = makeRequest(url: url, method: "GET")
            let envelope: APIEnvelope<[Zone]> = try await send(request)
            guard envelope.success else {
                throw Error.apiFailed(envelope.errors.map(\.message).joined(separator: ", "))
            }

            if let zone = envelope.result?.first(where: { $0.name.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return zone.id
            }
        }

        throw Error.zoneNotFound(fqdn)
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send<ResultType: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<ResultType> {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.apiFailed("Cloudflare returned an invalid response.")
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

    static func zoneCandidates(for fqdn: String) -> [String] {
        let normalized = fqdn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        guard !normalized.isEmpty else { return [] }

        let labels = normalized.split(separator: ".").map(String.init)
        return (0..<labels.count).map { index in
            labels[index...].joined(separator: ".")
        }
    }
}
