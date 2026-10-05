import Foundation

/// Optional independent arbiter. Its credential is stored only in Keychain.
struct MeshWitnessConfiguration: Codable, Equatable, Sendable {
    var endpoint = ""
    var clusterID = ""
    var token = ""

    var isConfigured: Bool { !endpoint.isEmpty || !clusterID.isEmpty || !token.isEmpty }
    var isValid: Bool {
        guard let url = URL(string: endpoint), let host = url.host,
              !clusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.trimmingCharacters(in: .whitespacesAndNewlines).count >= 32,
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

    func acquire(minimumTerm: Int) async -> Int? {
        guard let grant = await request("acquire", term: minimumTerm), grant.term >= minimumTerm else { return nil }
        return grant.term
    }

    func renew(term: Int) async -> Bool {
        guard currentTerm == term, let grant = await request("renew", term: term) else { return false }
        return grant.term == term
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

    private func request(_ action: String, term: Int) async -> Grant? {
        guard config.isValid, !nodeID.isEmpty,
              let url = URL(string: config.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/lease/\(action)") else { return nil }
        let began = ContinuousClock.now
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Request(clusterID: config.clusterID, nodeID: nodeID, term: term, nodeName: nodeName))
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let grant = try? JSONDecoder().decode(Grant.self, from: data),
                  grant.ownerNodeID == nodeID, grant.term >= 0,
                  grant.expiresInSeconds >= 3, grant.expiresInSeconds <= 60 else { return nil }
            // Start the local deadline before the HTTP request, with a safety
            // margin. Slow requests can never extend our permission to act.
            let expires = began.advanced(by: .milliseconds(Int64((grant.expiresInSeconds - 2) * 1000)))
            guard ContinuousClock.now < expires else { return nil }
            currentTerm = grant.term
            deadline = expires
            return grant
        } catch { return nil }
    }
}
