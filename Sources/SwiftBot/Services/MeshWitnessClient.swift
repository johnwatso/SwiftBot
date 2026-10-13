import Foundation
import RuruClient

/// Optional independent arbiter. Its credential is stored only in Keychain.
struct MeshWitnessConfiguration: Codable, Equatable, Sendable {
    var endpoint = ""
    var clusterID = ""
    var token = ""

    var isConfigured: Bool { !endpoint.isEmpty || !clusterID.isEmpty || !token.isEmpty }
    var isValid: Bool {
        Self.isValidEndpoint(endpoint)
            && !clusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && token.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32
    }

    /// HTTPS, or plain HTTP to loopback for development; never credentials,
    /// query or fragment in the URL.
    /// Which Ruru service this Mac's ownership depends on, without the token:
    /// cluster ID and endpoint host. Nodes compare fingerprints so a Mac set
    /// up differently cannot take over without the same lease authority.
    var ownershipFingerprint: String? {
        guard isValid, let host = URL(string: endpoint)?.host?.lowercased() else { return nil }
        return clusterID.trimmingCharacters(in: .whitespacesAndNewlines) + "@" + host
    }

    static func isValidEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
    }

    func toRuruConfiguration(nodeID: String, nodeName: String) -> RuruConfiguration? {
        guard isValid, let url = URL(string: endpoint) else { return nil }
        let name = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RuruConfiguration(endpoint: url, clusterID: clusterID, nodeID: nodeID,
                                 nodeName: name.isEmpty ? nil : name, token: token)
    }
}

enum MeshWitnessSettingsStore {
    private static let account = "swiftbot.mesh.witness"
    static func load() -> MeshWitnessConfiguration {
        guard let value = KeychainHelper.load(account: account), let data = value.data(using: .utf8),
              let config = try? JSONDecoder().decode(MeshWitnessConfiguration.self, from: data) else { return .init() }
        return config
    }
    @discardableResult static func save(_ config: MeshWitnessConfiguration) -> Bool {
        if !config.isConfigured { KeychainHelper.delete(account: account); return true }
        guard config.isValid, let data = try? JSONEncoder().encode(config),
              let value = String(data: data, encoding: .utf8) else { return false }
        return KeychainHelper.update(Data(value.utf8), account: account)
    }
}

/// Reachability of the witness from this Mac, from its unauthenticated
/// `GET /health`. Display only: never used to decide ownership.
enum MeshWitnessHealth: Equatable, Sendable {
    case checking
    /// Accepting lease requests.
    case ready
    /// Restarted and waiting out a full lease before new grants (503).
    case recovering
    case unreachable

    /// The WebUI's `witness.health` value.
    var webValue: String {
        switch self {
        case .checking: "checking"
        case .ready: "ready"
        case .recovering: "recovering"
        case .unreachable: "unreachable"
        }
    }

    var displayName: String {
        switch self {
        case .checking: "Checking"
        case .ready: "Ready"
        case .recovering: "Recovering"
        case .unreachable: "Unreachable"
        }
    }
}

/// The outcome of renewing a lease. Ruru answering "no" is different from
/// not hearing from Ruru: only the first means another Mac may now own it.
enum MeshOwnershipRenewal: Equatable, Sendable {
    case renewed
    /// Ruru refused: the lease expired, changed owner, or the token was rejected.
    case lost
    /// No usable answer (network, timeout, 503 during Ruru's restart
    /// quarantine). `stillValid` is whether this Mac's local deadline has
    /// not yet passed, so it may keep the lease and retry.
    case unreachable(stillValid: Bool)
}

actor MeshWitnessClient {
    enum ParticipantRole: String, Encodable { case active, standby, worker, unknown }
    private struct ParticipantReport: Encodable {
        let version = 1
        let clusterID: String
        let nodeID: String
        let nodeName: String?
        let role: ParticipantRole
        let webUIURL: String?
        let powerSource: String?
        let externalPower: Bool?
        let batteryPercent: Int?
        let batteryTimeRemaining: Int?
        let sessionEnding: Bool?
    }
    private var config = MeshWitnessConfiguration()
    private var nodeID = ""
    private var nodeName: String?
    private var presenceCapability: (supported: Bool, checked: ContinuousClock.Instant)?
    private var configurationGeneration = UUID()
    private let session: URLSession

    init(session: URLSession? = nil) {
        let settings = URLSessionConfiguration.ephemeral
        settings.waitsForConnectivity = false
        settings.timeoutIntervalForRequest = 5
        settings.timeoutIntervalForResource = 5
        self.session = session ?? URLSession(configuration: settings)
    }

    func configure(_ configuration: MeshWitnessConfiguration, nodeID: String, nodeName: String = "") {
        let name = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.nodeName = !name.isEmpty && name.utf8.count <= 256 && name.rangeOfCharacter(from: .controlCharacters) == nil ? name : nil
        // A name change is cosmetic and must preserve the existing permission.
        guard config != configuration || self.nodeID != nodeID else { return }
        config = configuration
        self.nodeID = nodeID
        configurationGeneration = UUID()
        presenceCapability = nil
    }

    /// Reports this Mac even while it is standby. This neither requests nor
    /// extends ownership. Feature detection keeps earlier Ruru versions usable.
    @discardableResult
    func reportPresence(role: ParticipantRole, webUIURL: String? = nil, power: PowerSnapshot? = nil,
                        sessionEnding: Bool? = nil) async -> Bool {
        guard config.isValid, !nodeID.isEmpty, !Task.isCancelled else { return false }
        let generation = configurationGeneration
        let configuration = config
        let endpoint = configuration.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let needsDiscovery = presenceCapability.map { ContinuousClock.now - $0.checked >= .seconds(60) } ?? true
        if needsDiscovery {
            guard let url = URL(string: endpoint + "/v1/service") else { return false }
            var discovery = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
            discovery.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await session.data(for: discovery),
                  generation == configurationGeneration, !Task.isCancelled,
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
                  let service = try? JSONDecoder().decode(ServiceDescription.self, from: data),
                  service.version == 1, service.authority == "Ruru", service.clusterID == configuration.clusterID else { return false }
            presenceCapability = (service.capabilities["participantPresence"]?.version == 1 &&
                                  service.capabilities["participantPresence"]?.enabled == true, .now)
        }
        guard presenceCapability?.supported == true, generation == configurationGeneration, !Task.isCancelled,
              let url = URL(string: endpoint + "/v1/participants/report") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let report = ParticipantReport(
            clusterID: configuration.clusterID, nodeID: nodeID, nodeName: nodeName,
            role: role, webUIURL: Self.reportedWebUIURL(webUIURL),
            powerSource: power?.source.rawValue,
            externalPower: power?.externalPower,
            batteryPercent: power?.batteryPercent,
            batteryTimeRemaining: power?.timeRemainingSeconds,
            sessionEnding: sessionEnding
        )
        request.httpBody = try? JSONEncoder().encode(report)
        guard let (data, response) = try? await session.data(for: request),
              generation == configurationGeneration, !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4096,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["version"] as? Int == 1, reply["accepted"] as? Bool == true else { return false }
        return true
    }

    /// Only advertise this Mac's credential-free HTTPS website origin.
    nonisolated static func reportedWebUIURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= 256,
              value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 92 }),
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) != false, components.url != nil,
              host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [45, 46, 58, 91, 93].contains($0) }) else { return nil }
        var origin = URLComponents()
        origin.scheme = "https"; origin.host = host.lowercased()
        origin.port = components.port == 443 ? nil : components.port
        return origin.string
    }

    /// Verify the imported service token without competing with the Primary
    /// for its lease. Public `/health` alone cannot verify service access.
    func verifyServiceConnection() async -> Bool {
        guard config.isValid,
              let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/service") else { return false }
        let expectedClusterID = config.clusterID
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4096,
              let service = try? JSONDecoder().decode(ServiceDescription.self, from: data),
              service.version == 1, service.authority == "Ruru",
              service.clusterID == expectedClusterID,
              service.capabilities["lease"]?.version == 1,
              service.capabilities["lease"]?.enabled == true else { return false }
        return await health() == .ready
    }

    private struct ServiceDescription: Decodable {
        let version: Int
        let authority: String
        let clusterID: String
        let capabilities: [String: Capability]

        struct Capability: Decodable {
            let version: Int
            let enabled: Bool
        }
    }

    /// Reads Ruru's Preferred Primary with this service's bearer token. Returns
    /// nil when no valid witness is configured. Read-only on Ruru's side, and
    /// never a grant of permission here.
    func primaryPolicy() async -> MeshPrimaryPolicyFetch? {
        guard config.isValid,
              let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/service/policy"),
              let body = try? JSONEncoder().encode(["clusterID": config.clusterID]) else { return nil }
        let clusterID = config.clusterID
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unavailable }
        if status == 404 { return .unsupported }
        guard status == 200, data.count <= 4096,
              let policy = MeshPrimaryPolicy.decode(data, expectedClusterID: clusterID) else { return .unavailable }
        return .policy(policy)
    }

    /// Probes `GET /health`, which needs no credentials and reveals no service
    /// details. Returns nil when no valid witness is configured.
    func health() async -> MeshWitnessHealth? {
        guard config.isValid,
              let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/health") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        let ready = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ready"] as? Bool
        if status == 200, ready == true { return .ready }
        if status == 503, ready == false { return .recovering }
        return .unreachable
    }

}

/// Ruru’s code alphabet: no 0/1/I/L/O/U.
/// "7kq4 m2xp" → "7KQ4-M2XP"; nil if the text isn’t a short code.
enum RuruPairingCode {
    private static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")
    static func normalized(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { $0 != "-" && $0 != " " && !$0.isNewline }
        guard cleaned.count == 8, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return String(cleaned.prefix(4)) + "-" + String(cleaned.suffix(4))
    }
}

extension RuruPairing.Failure: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Ruru didn’t accept this code. It may be mistyped, already used, or expired; create a new one in Ruru."
        case .rejected: "The request was rejected in Ruru."
        case .expired: "Nobody approved the request in time. Create a new code in Ruru and try again."
        case .throttled: "Ruru received too many wrong codes. Wait a minute, then try again."
        case .server: "Ruru returned an unexpected error."
        case .transport(let detail): "Ruru couldn’t be reached: \(detail)"
        }
    }
}
