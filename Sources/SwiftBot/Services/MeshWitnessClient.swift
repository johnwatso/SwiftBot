import Foundation

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
}

/// A Ruru pairing code: `RURU1:` followed by unpadded base64url UTF-8 JSON
/// carrying one guarded service's endpoint, cluster ID and bearer token.
/// The code contains a secret and is not encrypted. Format reference:
/// `Documentation/RURU_PAIRING_CODE.md`. Errors never echo the code or token.
struct RuruPairingCode: Equatable, Sendable {
    static let prefix = "RURU1:"
    static let supportedVersion = 1
    static let maximumLength = 4096
    /// Limits match Ruru's server (`WitnessRouter`): UTF-8 bytes, not characters.
    static let maximumClusterIDBytes = 128
    static let maximumTokenBytes = 512
    static let maximumServiceNameLength = 64

    let configuration: MeshWitnessConfiguration
    /// Display metadata only; dropped when blank, too long or unprintable.
    let serviceName: String?

    enum DecodeError: LocalizedError, Equatable {
        case empty, tooLong, joinCode, wrongPrefix, invalidEncoding, invalidJSON
        case missingVersion, unsupportedVersion(Int), missingField(String)
        case invalidEndpoint, invalidClusterID, invalidToken

        var errorDescription: String? {
            switch self {
            case .empty: "Paste a Ruru pairing code."
            case .tooLong: "This code is too long to be a Ruru pairing code."
            case .joinCode: "This is a SwiftMesh Join Code. Paste the pairing code from Ruru instead."
            case .wrongPrefix: "This isn't a Ruru pairing code. Ruru pairing codes start with RURU1:."
            case .invalidEncoding: "The pairing code is damaged. Copy it from Ruru again."
            case .invalidJSON: "The pairing code's contents can't be read. Copy it from Ruru again."
            case .missingVersion: "The pairing code has no format version. Update Ruru and copy a new code."
            case .unsupportedVersion(let version): "This pairing code uses format version \(version). Update SwiftBot to use it."
            case .missingField(let name): "The pairing code is missing its \(name)."
            case .invalidEndpoint: "The pairing code's address must be an HTTPS URL without credentials, query or fragment."
            case .invalidClusterID: "The pairing code's cluster ID is empty, too long, or has leading or trailing spaces."
            case .invalidToken: "The pairing code's bearer token must be 32 to 512 characters without spaces."
            }
        }
    }

    private struct Payload: Codable {
        var version: Int?
        var endpoint: String?
        var clusterID: String?
        var token: String?
        var serviceName: String?
    }

    static func decode(_ rawCode: String) throws -> RuruPairingCode {
        guard rawCode.utf8.count <= maximumLength * 2 else { throw DecodeError.tooLong }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { throw DecodeError.empty }
        guard code.utf8.count <= maximumLength else { throw DecodeError.tooLong }
        let payload: Payload
        if code.hasPrefix(prefix) {
            guard let data = base64URLDecode(String(code.dropFirst(prefix.count))) else { throw DecodeError.invalidEncoding }
            guard let decoded = try? JSONDecoder().decode(Payload.self, from: data) else { throw DecodeError.invalidJSON }
            guard let version = decoded.version else { throw DecodeError.missingVersion }
            guard version == supportedVersion else { throw DecodeError.unsupportedVersion(version) }
            payload = decoded
        } else if code.hasPrefix("{") {
            // Ruru's current Connection Details → Copy output: bare
            // `{"endpoint","clusterID","token"}` JSON with no version.
            guard let decoded = try? JSONDecoder().decode(Payload.self, from: Data(code.utf8)),
                  decoded.version == nil || decoded.version == supportedVersion else { throw DecodeError.invalidJSON }
            payload = decoded
        } else {
            throw code.lowercased().hasPrefix("swiftmesh://") ? DecodeError.joinCode : DecodeError.wrongPrefix
        }
        guard let endpoint = payload.endpoint else { throw DecodeError.missingField("address") }
        guard let clusterID = payload.clusterID else { throw DecodeError.missingField("cluster ID") }
        guard let token = payload.token else { throw DecodeError.missingField("bearer token") }

        guard MeshWitnessConfiguration.isValidEndpoint(endpoint),
              endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines) else { throw DecodeError.invalidEndpoint }
        guard !clusterID.isEmpty, clusterID.utf8.count <= maximumClusterIDBytes,
              clusterID == clusterID.trimmingCharacters(in: .whitespacesAndNewlines),
              clusterID.rangeOfCharacter(from: .controlCharacters) == nil else { throw DecodeError.invalidClusterID }
        guard (32...maximumTokenBytes).contains(token.utf8.count),
              token.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { throw DecodeError.invalidToken }
        let configuration = MeshWitnessConfiguration(endpoint: endpoint, clusterID: clusterID, token: token)

        let name = payload.serviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serviceName = !name.isEmpty && name.count <= maximumServiceNameLength
            && name.rangeOfCharacter(from: .controlCharacters) == nil ? name : nil
        return RuruPairingCode(configuration: configuration, serviceName: serviceName)
    }

    /// The exporter's half of the format, used by tests and kept here so both
    /// directions stay in step.
    static func encode(_ configuration: MeshWitnessConfiguration, serviceName: String? = nil) -> String? {
        let payload = Payload(version: supportedVersion, endpoint: configuration.endpoint,
                              clusterID: configuration.clusterID, token: configuration.token, serviceName: serviceName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(payload) else { return nil }
        let body = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return prefix + body
    }

    /// Strict unpadded base64url: only `A–Z a–z 0–9 - _`.
    private static func base64URLDecode(_ text: String) -> Data? {
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(alphabet.contains), text.count % 4 != 1 else { return nil }
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
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
    struct Grant: Codable, Sendable {
        let ownerNodeID: String
        let term: Int
        let expiresInSeconds: Double
    }
    private struct Request: Encodable {
        let clusterID: String
        let nodeID: String
        let term: Int
        let nodeName: String?
    }
    private var config = MeshWitnessConfiguration()
    private var nodeID = ""
    private var nodeName: String?
    private var currentTerm: Int?
    private var deadline: ContinuousClock.Instant?
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
        currentTerm = nil
        deadline = nil
    }

    func leaseDeadline() -> ContinuousClock.Instant? { deadline }

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

    func acquire(minimumTerm: Int) async -> Int? {
        guard case .granted(let grant) = await request("acquire", term: minimumTerm), grant.term >= minimumTerm else { return nil }
        return grant.term
    }

    func renew(term: Int) async -> MeshOwnershipRenewal {
        guard currentTerm == term else { return .lost }
        switch await request("renew", term: term) {
        case .granted(let grant):
            return grant.term == term ? .renewed : .lost
        case .refused:
            return .lost
        case .unreachable:
            return .unreachable(stillValid: deadline.map { ContinuousClock.now < $0 } ?? false)
        }
    }

    func release(term: Int) async {
        guard config.isValid, let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/lease/release") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Request(clusterID: config.clusterID, nodeID: nodeID, term: term, nodeName: nodeName))
        _ = try? await session.data(for: request)
        if currentTerm == term { currentTerm = nil; deadline = nil }
    }

    private enum LeaseResponse {
        case granted(Grant)
        /// A definite answer from Ruru: 401, 403 or 409.
        case refused
        case unreachable
    }

    private func request(_ action: String, term: Int) async -> LeaseResponse {
        guard config.isValid, !nodeID.isEmpty,
              let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/lease/\(action)") else { return .refused }
        let began = ContinuousClock.now
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Request(clusterID: config.clusterID, nodeID: nodeID, term: term, nodeName: nodeName))
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return .unreachable }
            if [401, 403, 409].contains(response.statusCode) { return .refused }
            guard response.statusCode == 200,
                  let grant = try? JSONDecoder().decode(Grant.self, from: data),
                  grant.ownerNodeID == nodeID, grant.term >= 0,
                  grant.expiresInSeconds >= 3, grant.expiresInSeconds <= 60 else { return .unreachable }
            // Start the local deadline before the HTTP request, with a safety
            // margin. Slow requests can never extend our permission to act.
            let expires = began.advanced(by: .milliseconds(Int64((grant.expiresInSeconds - 2) * 1000)))
            guard ContinuousClock.now < expires else { return .unreachable }
            currentTerm = grant.term
            deadline = expires
            return .granted(grant)
        } catch { return .unreachable }
    }
}
