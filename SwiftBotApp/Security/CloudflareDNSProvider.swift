import Foundation

struct CloudflareDNSProvider: Sendable {
    private struct APIError: Decodable {
        let code: Int?
        let message: String
    }

    struct TXTRecord: Sendable, Equatable {
        let zoneID: String
        let recordID: String
        let name: String
        let content: String
        let wasCreated: Bool
    }

    struct DNSRecordSummary: Sendable, Equatable {
        let zoneID: String
        let recordID: String
        let type: String
        let name: String
        let content: String
    }

    struct ZoneSummary: Sendable, Equatable {
        let id: String
        let name: String
    }

    enum Error: LocalizedError {
        case invalidDomain(String)
        case zoneNotFound(String)
        case identicalRecordAlreadyExists
        case apiFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDomain(let domain):
                return "Invalid Cloudflare DNS domain: \(domain)"
            case .zoneNotFound(let domain):
                return "Cloudflare zone not found for \(domain)"
            case .identicalRecordAlreadyExists:
                return "The required DNS record already exists and will be reused for certificate provisioning."
            case .apiFailed(let message):
                return message
            }
        }
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

    private struct CloudflareZoneResponse: Decodable {
        let success: Bool
        let result: [Zone]
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent([Zone].self, forKey: .result) ?? []
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct CloudflareDNSResponse: Decodable {
        let success: Bool
        let result: [CloudflareDNSRecord]
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent([CloudflareDNSRecord].self, forKey: .result) ?? []
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct Zone: Decodable {
        let id: String
        let name: String
    }

    private struct CloudflareDNSRecord: Decodable {
        let id: String
        let type: String
        let name: String
        let content: String
    }

    private struct DNSRecord: Decodable {
        let id: String
        let zoneID: String
        let type: String
        let name: String
        let content: String

        private enum CodingKeys: String, CodingKey {
            case id
            case zoneID = "zone_id"
            case type
            case name
            case content
        }
    }

    private struct CreateDNSRecordRequest: Encodable {
        let type: String
        let name: String
        let content: String
        let ttl: Int
        let proxied: Bool?
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

    func createACMEChallengeRecord(for hostname: String, content: String, ttl: Int = 120) async throws -> TXTRecord {
        guard let recordName = Self.acmeChallengeRecordName(for: hostname) else {
            throw Error.invalidDomain(hostname)
        }

        return try await createTXTRecord(name: recordName, content: content, ttl: ttl)
    }

    func createTXTRecord(name: String, content: String, ttl: Int = 120) async throws -> TXTRecord {
        let zoneID = try await resolveZoneID(for: name)
        let record: DNSRecordSummary
        do {
            record = try await createDNSRecord(
                zoneID: zoneID,
                type: "TXT",
                name: name,
                content: content,
                ttl: ttl
            )
        } catch Error.identicalRecordAlreadyExists {
            guard let existingRecord = try await findDNSRecord(
                zoneID: zoneID,
                hostname: name,
                allowedTypes: ["TXT"],
                expectedContent: content
            ) else {
                throw Error.apiFailed("Cloudflare reports that the DNS challenge record already exists, but SwiftBot could not verify it.")
            }

            return TXTRecord(
                zoneID: existingRecord.zoneID,
                recordID: existingRecord.recordID,
                name: existingRecord.name,
                content: existingRecord.content,
                wasCreated: false
            )
        }

        return TXTRecord(
            zoneID: record.zoneID,
            recordID: record.recordID,
            name: record.name,
            content: record.content,
            wasCreated: true
        )
    }

    func createDNSRecord(
        zoneID: String,
        type: String,
        name: String,
        content: String,
        ttl: Int = 120,
        proxied: Bool? = nil
    ) async throws -> DNSRecordSummary {
        let requestBody = CreateDNSRecordRequest(
            type: type,
            name: name,
            content: content,
            ttl: ttl,
            proxied: proxied
        )
        let requestURL = baseURL
            .appendingPathComponent("zones")
            .appendingPathComponent(zoneID)
            .appendingPathComponent("dns_records")

        var request = makeRequest(url: requestURL, method: "POST")
        request.httpBody = try encoder.encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let envelope: APIEnvelope<DNSRecord> = try await send(request)
        guard envelope.success, let record = envelope.result else {
            if Self.hasIdenticalRecordError(envelope.errors) {
                throw Error.identicalRecordAlreadyExists
            }
            throw Error.apiFailed(envelope.errors.map(\.message).joined(separator: ", "))
        }

        return DNSRecordSummary(
            zoneID: record.zoneID,
            recordID: record.id,
            type: record.type,
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

    func verifyAPIToken() async throws -> Bool {
        let requestURL = baseURL
            .appendingPathComponent("user")
            .appendingPathComponent("tokens")
            .appendingPathComponent("verify")

        let request = makeRequest(url: requestURL, method: "GET")
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.apiFailed("Cloudflare verification failed. Check your API token.")
        }

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let success = json["success"] as? Bool,
              success,
              let result = json["result"] as? [String: Any],
              let status = result["status"] as? String
        else {
            throw Error.apiFailed("Cloudflare verification failed. Check your API token.")
        }

        return status.lowercased() == "active"
    }

    func findZone(for fqdn: String) async throws -> ZoneSummary? {
        guard let zoneName = Self.extractRootZone(from: fqdn),
              let url = zonesURL(matchingName: zoneName)
        else {
            throw Error.invalidDomain(fqdn)
        }

        let request = makeRequest(url: url, method: "GET")
        let (data, http) = try await sendData(request)

        print("Cloudflare raw response:")
        print(String(data: data, encoding: .utf8) ?? "nil")

        let response: CloudflareZoneResponse
        do {
            response = try decoder.decode(CloudflareZoneResponse.self, from: data)
        } catch {
            print("Cloudflare decode error:", error)
            throw Error.apiFailed("Cloudflare zone lookup failed.")
        }

        print("Cloudflare success:", response.success)
        print("Zones returned:", response.result.count)

        guard (200..<300).contains(http.statusCode) else {
            let message = response.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        guard response.success else {
            let message = response.errors.isEmpty
                ? "Cloudflare zone lookup failed."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        guard !response.result.isEmpty, let zone = response.result.first else {
            return nil
        }

        return ZoneSummary(id: zone.id, name: zone.name)
    }

    func findDNSRecord(
        zoneID: String,
        hostname: String,
        allowedTypes: Set<String>? = nil,
        expectedContent: String? = nil
    ) async throws -> DNSRecordSummary? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("zones")
                .appendingPathComponent(zoneID)
                .appendingPathComponent("dns_records"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "per_page", value: "100")
        ]

        guard let url = components?.url else {
            throw Error.invalidDomain(hostname)
        }

        let request = makeRequest(url: url, method: "GET")
        let (data, http) = try await sendData(request)

        let response: CloudflareDNSResponse
        do {
            response = try decoder.decode(CloudflareDNSResponse.self, from: data)
        } catch {
            print("Cloudflare DNS decode error:", error)
            throw Error.apiFailed("Cloudflare DNS lookup failed.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = response.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        guard response.success else {
            let message = response.errors.isEmpty
                ? "Cloudflare DNS lookup failed."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        print("DNS records found:", response.result.count)

        let record = response.result.first { record in
            guard record.name.caseInsensitiveCompare(hostname) == .orderedSame else {
                return false
            }

            if let allowedTypes {
                guard allowedTypes.contains(record.type.uppercased()) else {
                    return false
                }
            }

            if let expectedContent {
                return record.content == expectedContent
            }

            return true
        }

        guard let record else {
            return nil
        }

        return DNSRecordSummary(
            zoneID: zoneID,
            recordID: record.id,
            type: record.type,
            name: record.name,
            content: record.content
        )
    }

    func dnsRecordExists(zoneID: String, hostname: String) async throws -> Bool {
        try await findDNSRecord(zoneID: zoneID, hostname: hostname) != nil
    }

    func resolveZoneID(for fqdn: String) async throws -> String {
        if let zone = try await findZone(for: fqdn) {
            return zone.id
        }

        throw Error.zoneNotFound(fqdn)
    }

    private func zonesURL(matchingName name: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("zones"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "per_page", value: "1")
        ]
        return components?.url
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
        let (data, http) = try await sendData(request)

        let envelope = try decoder.decode(APIEnvelope<ResultType>.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            if Self.hasIdenticalRecordError(envelope.errors) {
                throw Error.identicalRecordAlreadyExists
            }
            let message = envelope.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }
        return envelope
    }

    private func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.apiFailed("Cloudflare returned an invalid response.")
        }

        return (data, http)
    }

    private static func hasIdenticalRecordError(_ errors: [APIError]) -> Bool {
        errors.contains { error in
            if error.code == 81057 {
                return true
            }

            return error.message.localizedCaseInsensitiveContains("identical record already exists")
        }
    }

    static func extractRootZone(from hostname: String) -> String? {
        guard let normalized = normalizeHostname(hostname) else {
            return nil
        }

        let labels = normalized.split(separator: ".").map(String.init)
        guard labels.count >= 2 else {
            return nil
        }

        let publicSuffixLabelCount = publicSuffixLabelCount(for: labels)
        let registrableLabelCount = min(labels.count, publicSuffixLabelCount + 1)
        return labels.suffix(registrableLabelCount).joined(separator: ".")
    }

    static func acmeChallengeRecordName(for hostname: String) -> String? {
        guard let normalized = normalizeHostname(hostname) else {
            return nil
        }

        if normalized.hasPrefix("_acme-challenge.") {
            return normalized
        }

        return "_acme-challenge.\(normalized)"
    }

    static func normalizeHostname(_ hostname: String) -> String? {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parsedHost: String
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            parsedHost = host
        } else if let url = URL(string: "https://\(trimmed)"), let host = url.host, !host.isEmpty {
            parsedHost = host
        } else {
            parsedHost = trimmed
        }

        let withoutPath = parsedHost.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? parsedHost
        let withoutPort: String
        if withoutPath.hasPrefix("[") {
            withoutPort = withoutPath.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        } else {
            withoutPort = withoutPath.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? withoutPath
        }

        let normalized = withoutPort
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()

        return normalized.isEmpty ? nil : normalized
    }

    private static func publicSuffixLabelCount(for labels: [String]) -> Int {
        guard labels.count >= 2 else {
            return 1
        }

        let topLevelLabel = labels[labels.count - 1]
        let secondLevelLabel = labels[labels.count - 2]

        if topLevelLabel.count == 2, compoundPublicSuffixSecondLevelLabels.contains(secondLevelLabel) {
            return 2
        }

        return 1
    }

    private static let compoundPublicSuffixSecondLevelLabels: Set<String> = [
        "ac",
        "co",
        "com",
        "edu",
        "gen",
        "gov",
        "govt",
        "id",
        "mil",
        "net",
        "nom",
        "org",
        "sch"
    ]
}
