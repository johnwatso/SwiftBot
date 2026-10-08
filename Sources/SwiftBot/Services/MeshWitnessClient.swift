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
                  // Ruru allows per-service lease lengths of 10–300 seconds.
                  grant.expiresInSeconds >= 3, grant.expiresInSeconds <= 300 else { return .unreachable }
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

/// Ruru's pairing codes (`7KQ4-M2XP`). A code carries no secret: SwiftBot
/// exchanges it with Ruru for a pending
/// request, and Ruru releases this service's connection details only after
/// its operator approves the request. Codes are single-use and expire after
/// 10 minutes. Protocol: Ruru's `POST /v1/pair` and `POST /v1/pair/status`.
enum RuruShortCodePairing {
    /// Ruru's code alphabet: no 0/1/I/L/O/U.
    private static let alphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    enum Failure: LocalizedError, Equatable {
        case invalidAddress, missingNodeID, invalidCode, rejected, expired, throttled, unsupported
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "Enter Ruru’s HTTPS address, such as https://ruru.example.com."
            case .missingNodeID: "This Mac’s SwiftMesh identity isn’t ready yet. Try again in a moment."
            case .invalidCode: "Ruru didn’t accept this code. It may be mistyped, already used, or expired; create a new one in Ruru."
            case .rejected: "The request was rejected in Ruru."
            case .expired: "Nobody approved the request in time. Create a new code in Ruru and try again."
            case .throttled: "Ruru received too many wrong codes. Wait a minute, then try again."
            case .unsupported: "This Ruru is too old to pair with a code. Update Ruru, or enter the details under Advanced."
            case .unavailable(let detail): "Ruru couldn’t be reached: \(detail)"
            }
        }
    }

    /// "7kq4 m2xp" → "7KQ4-M2XP"; nil if the text isn't a short code.
    static func normalized(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { $0 != "-" && $0 != " " && !$0.isNewline }
        guard cleaned.count == 8, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return String(cleaned.prefix(4)) + "-" + String(cleaned.suffix(4))
    }

    /// Requests pairing and waits up to 10 minutes for approval in Ruru.
    /// Cancelling the calling task stops waiting. Saves nothing: the caller
    /// reviews and stores the returned configuration.
    static func pair(endpoint rawEndpoint: String, code: String, nodeID: String, nodeName: String,
                     session: URLSession = .shared) async throws -> MeshWitnessConfiguration {
        let endpoint = rawEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard MeshWitnessConfiguration.isValidEndpoint(endpoint) else { throw Failure.invalidAddress }
        guard !nodeID.isEmpty else { throw Failure.missingNodeID }
        guard let code = normalized(code) else { throw Failure.invalidCode }
        var claim = ["code": code, "nodeID": nodeID]
        let name = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { claim["nodeName"] = name }
        let pending = try await post(endpoint + "/v1/pair", claim, session)
        guard let pairingID = pending["pairingID"] as? String, !pairingID.isEmpty else {
            throw Failure.unavailable("unexpected response")
        }
        let deadline = ContinuousClock.now + .seconds(600)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let reply = try await post(endpoint + "/v1/pair/status", ["pairingID": pairingID], session)
            if reply["status"] as? String == "approved",
               let clusterID = reply["clusterID"] as? String, let token = reply["token"] as? String {
                let configuration = MeshWitnessConfiguration(endpoint: endpoint, clusterID: clusterID, token: token)
                guard configuration.isValid else { throw Failure.unavailable("Ruru sent incomplete details") }
                return configuration
            }
            let wait = min(10, max(1, (reply["retryAfter"] as? Double) ?? 2))
            try await Task.sleep(for: .seconds(wait))
        }
        throw Failure.expired
    }

    private static func post(_ address: String, _ body: [String: String], _ session: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: address) else { throw Failure.invalidAddress }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw Failure.unavailable(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch (status, object["error"] as? String) {
        case (200, _), (202, _): return object
        case (404, "invalid_code"): throw Failure.invalidCode
        case (404, _): throw Failure.unsupported
        case (403, _): throw Failure.rejected
        case (410, _): throw Failure.expired
        case (429, _): throw Failure.throttled
        default: throw Failure.unavailable("HTTP \(status)")
        }
    }
}
