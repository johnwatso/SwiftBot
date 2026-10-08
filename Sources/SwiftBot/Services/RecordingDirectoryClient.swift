import Foundation

/// Never forward credentials through an HTTP redirect, including a TLS downgrade.
final class RecordingRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 15
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config, delegate: RecordingRedirectPolicy(), delegateQueue: nil)
    }
}

/// Ruru discovers libraries, not individual files. One location per Mac keeps
/// the directory bounded independently of how many recordings a folder holds.
actor RecordingDirectoryClient {
    static let namespace = "swiftbot.recording-library.v1"
    static let resourceID = "library"

    struct Configuration: Equatable, Sendable {
        var witness: MeshWitnessConfiguration
        var nodeID: String
        var nodeName: String
        var libraryURL: String?
        var enabled: Bool
    }

    struct Library: Equatable, Sendable {
        var nodeID: String
        var nodeName: String
        var baseURL: String
        var deadline: ContinuousClock.Instant
    }

    struct Snapshot: Sendable {
        var libraries: [Library]
        var message: String
    }

    private struct Scope: Encodable {
        var version = 1
        var clusterID: String
        var offset: Int?
        var revision: String?
    }
    private struct Resource: Codable {
        var namespace: String
        var resourceID: String
        var title: String?
        var url: String?
    }
    private struct Report: Encodable {
        var version = 1
        var clusterID: String
        var nodeID: String
        var nodeName: String?
        var resources: [Resource]
        var removed: [Resource]
    }
    private struct Capabilities: Decodable {
        var version: Int
        var clusterID: String
        var enabled: Bool
        var capabilities: [String]
        var allowedOrigins: [String]
        var enrollmentSupported: Bool?
    }
    private struct Enrollment: Encodable {
        var version = 1
        var clusterID: String
        var nodeID: String
        var nodeName: String?
        var origin: String
        var withdraw: Bool
    }
    private struct EnrollmentReply: Decodable {
        var version: Int
        var clusterID: String
        var status: String
    }
    private struct Location: Decodable {
        var clusterID: String
        var nodeID: String
        var nodeName: String?
        var resource: Resource
        var ageSeconds: Double
        var fresh: Bool
    }
    private struct Page: Decodable {
        var version: Int
        var clusterID: String
        var revision: String
        var locations: [Location]
        var nextOffset: Int?
    }
    private struct Acknowledgement: Decodable {
        var version: Int
        var accepted: Bool
    }
    private enum Failure: Error { case invalid, unavailable, changed, revoked }
    private let session: URLSession
    private let now: @Sendable () -> ContinuousClock.Instant
    private var configuration: Configuration?
    private var generation = 0
    private var libraries: [Library] = []
    private var message = "Sharing is off."
    private var lastAttempt: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?
    private var transition: Task<Void, Never>?

    init(session: URLSession = RecordingRedirectPolicy.session(),
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.session = session
        self.now = now
    }

    func configure(_ next: Configuration) async {
        guard next != configuration else { await transition?.value; return }
        let previous = configuration
        configuration = next
        generation += 1
        let epoch = generation
        libraries = []
        lastAttempt = nil
        message = next.enabled ? "Connecting to Ruru…" : "Sharing is off."
        let oldRequest = pending
        pending = nil
        oldRequest?.cancel()
        // Withdraw only after the previous request finishes: a delayed upsert
        // must not resurrect a location after the operator turns sharing off.
        let predecessor = transition
        let cleanup = Task {
            await predecessor?.value
            await oldRequest?.value
            if let previous, previous.enabled, previous.witness.isValid, previous.libraryURL != nil {
                _ = try? await self.send(self.report(previous, removing: true), route: "report", config: previous)
                if let origin = previous.libraryURL.flatMap(Self.origin) {
                    _ = try? await self.send(self.enrollment(previous, origin: origin, withdraw: true), route: "enrollment", config: previous)
                }
            }
        }
        transition = cleanup
        await cleanup.value
        guard epoch == generation else { return }
        transition = nil
    }

    func refresh(force: Bool = false) async -> Snapshot {
        guard transition == nil else { return snapshot() }
        if let pending { await pending.value; return snapshot() }
        guard let config = configuration, config.enabled else { return snapshot() }
        if !force, let lastAttempt, lastAttempt.duration(to: now()) < .seconds(15) { return snapshot() }
        lastAttempt = now()
        let epoch = generation
        let task = Task { await self.update(config, generation: epoch) }
        pending = task
        await task.value
        if epoch == generation { pending = nil }
        return snapshot()
    }

    func snapshot() -> Snapshot {
        Snapshot(libraries: libraries.filter { now() < $0.deadline }, message: message)
    }

    private func update(_ config: Configuration, generation epoch: Int) async {
        guard epoch == generation, !Task.isCancelled else { return }
        guard config.witness.isValid, !config.nodeID.isEmpty else {
            message = "Pair this Mac with Ruru in SwiftMesh settings."
            return
        }
        do {
            let (_, data) = try await send(Scope(clusterID: config.witness.clusterID), route: "capabilities", config: config)
            let capabilities = try JSONDecoder().decode(Capabilities.self, from: data)
            guard epoch == generation, !Task.isCancelled else { return }
            guard capabilities.version == 1, capabilities.clusterID == config.witness.clusterID,
                  capabilities.allowedOrigins.count <= 8,
                  capabilities.allowedOrigins.allSatisfy({ Self.origin($0) == $0 }) else { throw Failure.invalid }
            let origin = config.libraryURL.flatMap(Self.origin)
            let canPublish = capabilities.enabled && origin.map(capabilities.allowedOrigins.contains) == true
            libraries.removeAll { !capabilities.enabled || !capabilities.allowedOrigins.contains($0.baseURL) }
            var enrollmentMessage: String?
            if !canPublish, let origin, capabilities.enrollmentSupported == true {
                let (_, data) = try await send(enrollment(config, origin: origin, withdraw: false), route: "enrollment", config: config)
                let reply = try JSONDecoder().decode(EnrollmentReply.self, from: data)
                guard epoch == generation, !Task.isCancelled else { return }
                guard reply.version == 1, reply.clusterID == config.witness.clusterID else { throw Failure.invalid }
                switch reply.status {
                case "pending": enrollmentMessage = "Website sent to Ruru. Open this service in Coordination and approve \(origin)."
                case "rejected": enrollmentMessage = "Ruru declined this website. Review this service’s allowed websites in Ruru, or retry sharing after the request expires."
                case "approved": enrollmentMessage = "Website approved. Refreshing Ruru’s directory…"
                default: throw Failure.invalid
                }
            }
            guard capabilities.enabled, capabilities.capabilities.contains("resource-catalogue.v1") else {
                libraries = []
                message = enrollmentMessage ?? "Enable Resource catalogue for this service in Ruru."
                return
            }
            if canPublish {
                let (_, reply) = try await send(report(config, removing: false), route: "report", config: config)
                let acknowledgement = try JSONDecoder().decode(Acknowledgement.self, from: reply)
                guard acknowledgement.version == 1, acknowledgement.accepted else { throw Failure.invalid }
            }
            let discovered = try await readLibraries(config, origins: capabilities.allowedOrigins)
            guard epoch == generation, !Task.isCancelled else { return }
            libraries = discovered
            message = enrollmentMessage ?? (canPublish ? "Connected to Ruru. Libraries are shared on Primary and Fail Over nodes."
                : "Browsing shared libraries. Configure this Mac’s HTTPS Web Interface address and allow it in Ruru to share recordings.")
        } catch Failure.revoked {
            guard epoch == generation, !Task.isCancelled else { return }
            libraries = []
            message = "Ruru has revoked access to this library directory. Review the service’s pairing and catalogue settings."
        } catch Failure.invalid {
            guard epoch == generation, !Task.isCancelled else { return }
            libraries = []
            message = "Ruru returned an unsupported library directory. Update the apps and review the service settings."
        } catch {
            guard epoch == generation, !Task.isCancelled else { return }
            // A failed read cannot make observations newer. Only previously
            // verified, still-fresh locations survive a transport outage.
            libraries = libraries.filter { now() < $0.deadline }
            message = "Ruru could not refresh the library directory. Local recordings remain available."
        }
    }

    private func readLibraries(_ config: Configuration, origins: [String]) async throws -> [Library] {
        let began = now()
        // A report between pages invalidates the revision. Never publish a
        // partial traversal. Bound both restarts and the whole traversal time.
        for _ in 0..<3 {
            var offset = 0
            var revision: String?
            var result: [Library] = []
            var ids = Set<String>()
            do {
                for _ in 0..<26 {
                    guard !Task.isCancelled, began.duration(to: now()) < .seconds(15) else { throw Failure.unavailable }
                    let requested = now()
                    let (_, data) = try await send(Scope(clusterID: config.witness.clusterID, offset: offset, revision: revision),
                                                   route: "catalogue", config: config)
                    let page = try JSONDecoder().decode(Page.self, from: data)
                    guard page.version == 1, page.clusterID == config.witness.clusterID, page.locations.count <= 20,
                          !page.revision.isEmpty, revision == nil || revision == page.revision else { throw Failure.invalid }
                    revision = page.revision
                    for location in page.locations where location.resource.namespace == Self.namespace && location.resource.resourceID == Self.resourceID {
                        guard location.clusterID == config.witness.clusterID, !location.nodeID.isEmpty,
                              location.nodeID.utf8.count <= 128, location.fresh,
                              location.ageSeconds.isFinite, location.ageSeconds >= 0, location.ageSeconds < 90,
                              let url = location.resource.url, let origin = Self.origin(url), origins.contains(origin),
                              URLComponents(string: url)?.path == "/v1/media/library",
                              ids.insert(location.nodeID).inserted else { continue }
                        let deadline = requested.advanced(by: .milliseconds(Int64((90 - location.ageSeconds) * 1000)))
                        result.append(Library(nodeID: location.nodeID, nodeName: location.nodeName ?? "SwiftBot",
                                              baseURL: origin, deadline: deadline))
                        guard result.count <= 16 else { throw Failure.invalid }
                    }
                    guard let next = page.nextOffset else { return result }
                    guard next == offset + 20 else { throw Failure.invalid }
                    offset = next
                }
                throw Failure.invalid
            } catch Failure.changed { continue }
        }
        throw Failure.changed
    }

    private func report(_ config: Configuration, removing: Bool) -> Report {
        let name = String(config.nodeName.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        let validName = !name.isEmpty && name.utf8.count <= 256 && name.rangeOfCharacter(from: .controlCharacters) == nil
        let key = Resource(namespace: Self.namespace, resourceID: Self.resourceID)
        let resource = Resource(namespace: Self.namespace, resourceID: Self.resourceID,
                                title: "SwiftBot recording library", url: config.libraryURL)
        return Report(clusterID: config.witness.clusterID, nodeID: config.nodeID,
                      nodeName: validName ? name : nil, resources: removing ? [] : [resource],
                      removed: removing ? [key] : [])
    }

    private func enrollment(_ config: Configuration, origin: String, withdraw: Bool) -> Enrollment {
        let name = String(config.nodeName.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = !name.isEmpty && name.utf8.count <= 256 && name.rangeOfCharacter(from: .controlCharacters) == nil
        return Enrollment(clusterID: config.witness.clusterID, nodeID: config.nodeID,
                          nodeName: valid ? name : nil, origin: origin, withdraw: withdraw)
    }

    private func send<T: Encodable>(_ value: T, route: String, config: Configuration) async throws -> (Int, Data) {
        guard let url = URL(string: config.witness.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/coordination/" + route) else { throw Failure.invalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + config.witness.token, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(value)
        guard request.httpBody!.count <= 4096 else { throw Failure.invalid }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count <= 65536 else { throw Failure.invalid }
        if [401, 403, 404].contains(http.statusCode) { throw Failure.revoked }
        if http.statusCode == 409, route == "catalogue" { throw Failure.changed }
        guard http.statusCode == 200 else { throw Failure.unavailable }
        return (http.statusCode, data)
    }

    static func origin(_ raw: String) -> String? {
        guard raw.utf8.count <= 512, raw.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 92 }),
              let input = URLComponents(string: raw), input.scheme == "https",
              let host = input.host, !host.isEmpty, input.user == nil, input.password == nil,
              input.query == nil, input.fragment == nil, input.port.map({ (1...65535).contains($0) }) != false else { return nil }
        var result = URLComponents()
        result.scheme = "https"
        result.host = host.lowercased()
        result.port = input.port == 443 ? nil : input.port
        return result.string
    }
}
