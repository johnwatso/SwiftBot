import Foundation
import Network
import Darwin

struct HardwareInfo: Sendable, Hashable {
    let modelIdentifier: String
    let cpuName: String
    let physicalMemoryBytes: UInt64

    static func current() -> HardwareInfo {
        HardwareInfo(
            modelIdentifier: readSysctlString("hw.model") ?? "Mac",
            cpuName: readSysctlString("machdep.cpu.brand_string") ?? "Unknown CPU",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func readSysctlString(_ key: String) -> String? {
        var length: Int = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 1 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &value, &length, nil, 0) == 0 else {
            return nil
        }

        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}

actor ClusterCoordinator {
    typealias AIHandler = @Sendable ([Message], String?, String?, String?) async -> String?
    typealias WikiHandler = @Sendable (String, WikiSource) async -> FinalsWikiLookupResult?
    typealias JobLogHandler = @Sendable (CommandLogEntry) async -> Void

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let startedAt = Date()
    private let hardwareInfo = HardwareInfo.current()
    private let workerRegistrationIntervalNanoseconds: UInt64 = 4_000_000_000
    private let registrationStaleAfter: TimeInterval = 20
    private static let maxHTTPRequestSize = 1_024 * 1024
    private static let httpReadTimeout: TimeInterval = 5.0

    private var mode: ClusterMode = .standalone
    private var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    private var leaderAddress: String = ""
    private var listenPort: Int = 38787
    private var sharedSecret: String = ""
    private var activeJobs = 0
    private var registeredWorkers: [String: RegisteredWorker] = [:]
    private var workerRegistrationTask: Task<Void, Never>?

    private var aiHandler: AIHandler?
    private var wikiHandler: WikiHandler?
    private var listener: NWListener?
    private var onSnapshot: (@Sendable (ClusterSnapshot) async -> Void)?
    private var onJobLog: JobLogHandler?
    private var snapshot = ClusterSnapshot()

    func configureHandlers(
        aiHandler: @escaping AIHandler,
        wikiHandler: @escaping WikiHandler,
        onSnapshot: @escaping @Sendable (ClusterSnapshot) async -> Void,
        onJobLog: @escaping JobLogHandler
    ) {
        self.aiHandler = aiHandler
        self.wikiHandler = wikiHandler
        self.onSnapshot = onSnapshot
        self.onJobLog = onJobLog
    }

    func applySettings(mode: ClusterMode, nodeName: String, leaderAddress: String, listenPort: Int, sharedSecret: String) async {
        self.mode = mode
        self.nodeName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.leaderAddress = normalizedBaseURL(leaderAddress) ?? leaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.listenPort = listenPort
        self.sharedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)

        snapshot.mode = mode
        snapshot.nodeName = self.nodeName
        snapshot.listenPort = listenPort
        snapshot.leaderAddress = self.leaderAddress
        snapshot.diagnostics = "Applied mode \(mode.rawValue)"
        snapshot.lastJobNode = self.nodeName

        if mode != .leader {
            registeredWorkers.removeAll()
        }

        await restartServerIfNeeded()
        await restartWorkerRegistrationIfNeeded()
        await refreshWorkerHealth()
        await publishSnapshot()
    }

    func stopAll() async {
        workerRegistrationTask?.cancel()
        workerRegistrationTask = nil
        listener?.cancel()
        listener = nil
        registeredWorkers.removeAll()
        snapshot.serverState = .stopped
        snapshot.serverStatusText = "Stopped"
        snapshot.workerState = .inactive
        snapshot.workerStatusText = "Stopped"
        snapshot.diagnostics = "Cluster services stopped"
        await publishSnapshot()
    }

    func currentSnapshot() -> ClusterSnapshot {
        snapshot
    }

    func refreshWorkerHealth() async {
        switch mode {
        case .standalone:
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Not applicable"
            snapshot.diagnostics = "Cluster mode is standalone"
            await publishSnapshot()
        case .leader:
            pruneStaleRegistrations()
            let workers = sortedRegisteredWorkers()
            guard !workers.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "No workers registered"
                snapshot.diagnostics = "Waiting for workers to register"
                await publishSnapshot()
                return
            }

            var reachable = 0
            for worker in workers {
                if await isWorkerReachable(worker.baseURL) {
                    reachable += 1
                }
            }

            if reachable == workers.count {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "\(reachable) workers reachable"
            } else if reachable > 0 {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "\(reachable)/\(workers.count) workers reachable"
            } else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "No workers reachable"
            }
            snapshot.diagnostics = "Registered workers: \(workers.count), reachable: \(reachable)"
            await publishSnapshot()
        case .worker:
            guard let leaderBaseURL = normalizedBaseURL(leaderAddress), !leaderBaseURL.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "Leader not configured"
                snapshot.diagnostics = "Worker requires a Leader Address"
                await publishSnapshot()
                return
            }

            guard let url = URL(string: leaderBaseURL + "/health") else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Invalid leader address"
                snapshot.diagnostics = "Leader Address is invalid: \(leaderAddress)"
                await publishSnapshot()
                return
            }

            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    snapshot.workerState = .connected
                    snapshot.workerStatusText = "Leader reachable"
                    snapshot.diagnostics = "Leader reachable via \(url.absoluteString)"
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    snapshot.workerState = .degraded
                    snapshot.workerStatusText = "Leader health check failed (\(status))"
                    snapshot.diagnostics = "Leader health returned HTTP \(status) via \(url.absoluteString)"
                }
            } catch {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Leader unavailable"
                snapshot.diagnostics = "Leader health request failed for \(url.absoluteString): \(error.localizedDescription)"
            }
            await publishSnapshot()
        }
    }

    func generateAIReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
    ) async -> String? {
        let job = AIJobRequest(
            messages: messages,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
        if mode == .leader, let remote = await performRemoteAI(job) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "AI reply via worker"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.reply
        }

        let local = await aiHandler?(messages, serverName, channelName, wikiContext)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "AI reply unavailable" : "AI reply local"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled AI reply locally on \(nodeName)"
        }
        await publishSnapshot()
        return local
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        if mode == .leader, let remote = await performRemoteWikiLookup(query: query, source: source) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Wiki lookup via worker (\(source.name))"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.result
        }

        let local = await wikiHandler?(query, source)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "Wiki lookup unavailable" : "Wiki lookup local (\(source.name))"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled wiki lookup locally on \(nodeName) for \(source.name)"
        }
        await publishSnapshot()
        return local
    }

    func probeWorker() async -> ClusterProbeResponse? {
        guard mode == .leader else {
            snapshot.diagnostics = "Remote cluster worker probe is only available in leader mode"
            await publishSnapshot()
            return nil
        }

        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No workers registered for probe"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/probe") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                if !sharedSecret.isEmpty {
                    request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
                }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(ClusterProbeResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote probe OK"
                snapshot.lastJobRoute = .remote
                snapshot.lastJobSummary = "Remote cluster worker probe"
                snapshot.lastJobNode = decoded.nodeName
                snapshot.diagnostics = "Worker \(decoded.nodeName) responded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote probe unavailable"
        snapshot.diagnostics = "Remote probe failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func restartServerIfNeeded() async {
        listener?.cancel()
        listener = nil

        guard mode == .worker || mode == .leader else {
            snapshot.serverState = .inactive
            snapshot.serverStatusText = "Disabled"
            return
        }

        do {
            snapshot.serverState = .starting
            snapshot.serverStatusText = "Starting on :\(listenPort)"
            snapshot.diagnostics = "Starting worker server on port \(listenPort)"
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(listenPort)))
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleConnection(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Failed to bind port \(listenPort): \(error.localizedDescription)"
        }
    }

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            snapshot.serverState = .listening
            snapshot.serverStatusText = "Listening on :\(listenPort)"
            snapshot.diagnostics = "Worker server listening on port \(listenPort)"
        case .failed(let error):
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Worker server failed: \(error.localizedDescription)"
        case .cancelled:
            snapshot.serverState = .stopped
            snapshot.serverStatusText = "Stopped"
            snapshot.diagnostics = "Worker server stopped"
        default:
            break
        }
        await publishSnapshot()
    }

    private func handleConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .utility))
        do {
            let requestData = try await readHTTPRequest(connection)
            let response = await processHTTPRequest(requestData)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            let body = #"{"error":"bad_request"}"#.data(using: .utf8) ?? Data()
            let response = httpResponse(status: "400 Bad Request", body: body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func readHTTPRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let start = Date()

        while buffer.count < Self.maxHTTPRequestSize {
            if Date().timeIntervalSince(start) > Self.httpReadTimeout {
                throw NWError.posix(.ETIMEDOUT)
            }

            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.upperBound]
                let contentLength = parseContentLength(headerData)
                let bodyLength = buffer.count - headerRange.upperBound
                
                if contentLength > Self.maxHTTPRequestSize {
                    throw NWError.posix(.EMSGSIZE)
                }

                if bodyLength >= contentLength {
                    return buffer
                }
            }
        }
        
        if buffer.count >= Self.maxHTTPRequestSize {
            throw NWError.posix(.EMSGSIZE)
        }
        
        return buffer
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in headerText.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let intValue = Int(value.trimmingCharacters(in: .whitespaces)) {
                return intValue
            }
        }
        return 0
    }

    private func processHTTPRequest(_ requestData: Data) async -> Data {
        guard let request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_request"}"#.utf8))
        }

        // Enforce shared-secret auth on all routes except /health.
        if !sharedSecret.isEmpty, request.path != "/health" {
            let provided = request.headers["x-cluster-secret"] ?? ""
            guard provided == sharedSecret else {
                return httpResponse(status: "401 Unauthorized", body: Data(#"{"error":"unauthorized"}"#.utf8))
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let payload = HealthResponse(nodeName: nodeName, mode: mode.rawValue, status: "ok")
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/cluster/ping"):
            let payload = ClusterPingResponse(
                status: "ok",
                role: mode == .leader ? "leader" : "worker",
                node: nodeName
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/cluster/register"):
            return await handleWorkerRegistration(request.body)
        case ("GET", "/cluster/status"):
            let payload = await clusterStatusPayload()
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/v1/probe"):
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote worker probe"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote probe on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: "Cluster",
                server: "Cluster",
                command: "GET /v1/probe",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let payload = ClusterProbeResponse(
                nodeName: nodeName,
                mode: mode.rawValue,
                listenPort: listenPort,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/v1/ai-reply"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let aiHandler,
                  let body = try? decoder.decode(AIJobRequest.self, from: request.body),
                  let reply = await aiHandler(body.messages, body.serverName, body.channelName, body.wikiContext) else {
                return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"ai_unavailable"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote AI reply"
            snapshot.lastJobNode = nodeName
            let requestUser = body.messages.last(where: { $0.role == .user })?.username ?? "Unknown"
            snapshot.diagnostics = "Handled remote AI reply for \(requestUser) on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: requestUser,
                server: "Remote AI",
                command: "AI reply",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = AIJobResponse(nodeName: nodeName, reply: reply)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/wiki-lookup"), ("POST", "/v1/finals-wiki"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let wikiHandler,
                  let body = decodeWikiJobRequest(from: request.body),
                  let result = await wikiHandler(body.query, body.source) else {
                await recordJobLog(
                    user: "Remote Wiki",
                    server: "Cluster",
                    command: "Wiki lookup failed",
                    channel: "worker",
                    executionRoute: "Worker",
                    ok: false
                )
                return httpResponse(status: "404 Not Found", body: Data(#"{"error":"not_found"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote wiki lookup"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote wiki lookup for \"\(body.query)\" on \(nodeName) (\(body.source.name))"
            await publishSnapshot()
            await recordJobLog(
                user: body.source.name,
                server: "Remote Wiki",
                command: "!wiki \(body.query)",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = WikiJobResponse(nodeName: nodeName, result: result)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        default:
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"unknown_route"}"#.utf8))
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<marker.lowerBound], encoding: .utf8) else {
            return nil
        }

        let body = Data(data[marker.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    private func httpResponse(status: String, body: Data) -> Data {
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func restartWorkerRegistrationIfNeeded() async {
        workerRegistrationTask?.cancel()
        workerRegistrationTask = nil

        guard mode == .worker else { return }
        guard let normalizedLeader = normalizedBaseURL(leaderAddress), !normalizedLeader.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Leader not configured"
            snapshot.diagnostics = "Set Leader Address to enable worker registration"
            return
        }

        workerRegistrationTask = Task {
            while !Task.isCancelled {
                await registerWithLeader(normalizedLeader)
                try? await Task.sleep(nanoseconds: workerRegistrationIntervalNanoseconds)
            }
        }
    }

    private func registerWithLeader(_ leaderBaseURL: String) async {
        guard mode == .worker else { return }
        guard let url = URL(string: leaderBaseURL + "/cluster/register") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid leader address"
            snapshot.diagnostics = "Invalid registration URL: \(leaderBaseURL)"
            await publishSnapshot()
            return
        }

        let payload = WorkerRegistrationRequest(
            nodeName: nodeName,
            baseURL: localWorkerAdvertisedBaseURL(),
            listenPort: listenPort
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !sharedSecret.isEmpty {
                request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
            }
            request.timeoutInterval = 3
            request.httpBody = try encoder.encode(payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Registration failed (\(code))"
                snapshot.diagnostics = "Leader rejected registration at \(url.absoluteString)"
                await publishSnapshot()
                return
            }

            let ack = try? decoder.decode(WorkerRegistrationResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Registered with leader"
            if let ack {
                snapshot.diagnostics = "Registered with leader \(ack.leaderNodeName) (\(ack.registeredWorkers) workers total)"
            } else {
                snapshot.diagnostics = "Registered with leader via \(url.absoluteString)"
            }
            await publishSnapshot()
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Leader unavailable"
            snapshot.diagnostics = "Registration request failed for \(url.absoluteString): \(error.localizedDescription)"
            await publishSnapshot()
        }
    }

    private func handleWorkerRegistration(_ body: Data) async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: Data(#"{"error":"leader_mode_required"}"#.utf8))
        }

        guard let registration = try? decoder.decode(WorkerRegistrationRequest.self, from: body),
              let baseURL = normalizedBaseURL(registration.baseURL),
              !baseURL.isEmpty else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_registration"}"#.utf8))
        }

        let workerName = registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Worker"
            : registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = baseURL.lowercased()
        registeredWorkers[key] = RegisteredWorker(
            nodeName: workerName,
            baseURL: baseURL,
            listenPort: registration.listenPort,
            lastSeen: Date()
        )
        pruneStaleRegistrations()

        snapshot.workerState = .connected
        let workerCount = registeredWorkers.count
        snapshot.workerStatusText = "\(workerCount) worker\(workerCount == 1 ? "" : "s") registered"
        snapshot.diagnostics = "Worker \(workerName) registered from \(baseURL)"
        await publishSnapshot()

        let response = WorkerRegistrationResponse(
            status: "ok",
            leaderNodeName: nodeName,
            registeredWorkers: workerCount
        )
        let payload = (try? encoder.encode(response)) ?? Data()
        return httpResponse(status: "200 OK", body: payload)
    }

    private func sortedRegisteredWorkers() -> [RegisteredWorker] {
        registeredWorkers.values
            .filter { !isSelfClusterEndpoint($0.baseURL) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    private func pruneStaleRegistrations() {
        let cutoff = Date().addingTimeInterval(-registrationStaleAfter)
        registeredWorkers = registeredWorkers.filter { $0.value.lastSeen >= cutoff }
    }

    private func localWorkerAdvertisedBaseURL() -> String {
        let host = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        return "http://\(resolvedHost):\(listenPort)"
    }

    private func normalizedBaseURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }
        
        // SSRF guard: only allow private network ranges or localhost
        if !isSSRFSafeHost(host) {
            return nil
        }

        let portSuffix = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portSuffix)"
    }

    private func isSSRFSafeHost(_ host: String) -> Bool {
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1" {
            return true
        }
        
        // Basic private range check for typical home/office networks
        let privatePrefixes = ["192.168.", "10.", "172.16.", "172.17.", "172.18.", "172.19.", "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.", "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31."]
        for prefix in privatePrefixes {
            if lowerHost.hasPrefix(prefix) {
                return true
            }
        }
        
        // Also allow local .local hostnames (Bonjour)
        if lowerHost.hasSuffix(".local") {
            return true
        }
        
        return false
    }

    private func isWorkerReachable(_ baseURL: String) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if !sharedSecret.isEmpty {
                request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
            }
            request.timeoutInterval = 2
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func performRemoteAI(_ job: AIJobRequest) async -> AIJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote AI"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/ai-reply") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !sharedSecret.isEmpty {
                    request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
                }
                request.httpBody = try encoder.encode(job)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(AIJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote AI available"
                snapshot.diagnostics = "Remote AI succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote AI unavailable"
        snapshot.diagnostics = "Remote AI failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func performRemoteWikiLookup(query: String, source: WikiSource) async -> WikiJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote wiki lookup"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/wiki-lookup") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !sharedSecret.isEmpty {
                    request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
                }
                request.httpBody = try encoder.encode(WikiJobRequest(query: query, source: source))
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(WikiJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote wiki available"
                snapshot.diagnostics = "Remote wiki succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote wiki unavailable"
        snapshot.diagnostics = "Remote wiki failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func clusterStatusPayload() async -> ClusterStatusResponse {
        var nodes: [ClusterNodeStatus] = [localNodeStatus()]

        if mode == .leader {
            pruneStaleRegistrations()
            let workers = sortedRegisteredWorkers()
            var reachable = 0

            for worker in workers {
                if let remoteStatus = await fetchRemoteClusterStatus(baseURL: worker.baseURL) {
                    reachable += 1
                    for var node in remoteStatus.response.nodes where !nodes.contains(where: { $0.id == node.id }) {
                        if node.role == .worker, node.latencyMs == nil {
                            node.latencyMs = remoteStatus.latencyMs
                        }
                        nodes.append(node)
                    }
                } else {
                    nodes.append(unreachableWorkerNode(worker: worker))
                }
            }

            if workers.isEmpty {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "No workers registered"
                snapshot.diagnostics = "Waiting for worker registrations via /cluster/register"
            } else if reachable == workers.count {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "\(reachable) workers connected"
                snapshot.diagnostics = "All registered workers reachable"
            } else if reachable > 0 {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "\(reachable)/\(workers.count) workers connected"
                snapshot.diagnostics = "Some registered workers are unreachable"
            } else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Cluster status unavailable"
                snapshot.diagnostics = "Unable to reach any registered workers"
            }
        }

        return ClusterStatusResponse(
            mode: mode,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            nodes: nodes
        )
    }

    private func localNodeStatus() -> ClusterNodeStatus {
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole = mode == .worker ? .worker : .leader
        let uptime = max(0, Date().timeIntervalSince(startedAt))
        let status = snapshot.serverState.nodeHealthStatus

        return ClusterNodeStatus(
            id: "\(role.rawValue)-\(hostname.lowercased())-\(listenPort)",
            hostname: hostname,
            displayName: nodeName,
            role: role,
            hardwareModel: hardwareInfo.modelIdentifier,
            cpu: currentCPUPercent(),
            mem: currentMemoryPercent(),
            cpuName: hardwareInfo.cpuName,
            physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
            uptime: uptime,
            latencyMs: nil,
            status: status,
            jobsActive: activeJobs
        )
    }

    private func unreachableWorkerNode(worker: RegisteredWorker) -> ClusterNodeStatus {
        let host = URL(string: worker.baseURL)?.host ?? worker.nodeName

        return ClusterNodeStatus(
            id: "worker-\(host.lowercased())-\(worker.listenPort)",
            hostname: host,
            displayName: worker.nodeName,
            role: .worker,
            hardwareModel: "Unknown",
            cpu: 0,
            mem: 0,
            cpuName: "Unknown CPU",
            physicalMemoryBytes: 0,
            uptime: 0,
            latencyMs: nil,
            status: .disconnected,
            jobsActive: 0
        )
    }

    private func fetchRemoteClusterStatus(baseURL: String) async -> (response: ClusterStatusResponse, latencyMs: Double)? {
        guard let url = URL(string: baseURL + "/cluster/status") else {
            return nil
        }

        do {
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if !sharedSecret.isEmpty {
                request.setValue(sharedSecret, forHTTPHeaderField: "X-Cluster-Secret")
            }
            request.timeoutInterval = 3
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let decoded = try decoder.decode(ClusterStatusResponse.self, from: data)
            let latencyMs = max(0, Date().timeIntervalSince(started) * 1000)
            return (decoded, latencyMs)
        } catch {
            return nil
        }
    }

    private func currentCPUPercent() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    private func currentMemoryPercent() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let usedPages = Double(vmStats.active_count)
            + Double(vmStats.inactive_count)
            + Double(vmStats.wire_count)
            + Double(vmStats.compressor_page_count)
        let usedBytes = usedPages * Double(vm_kernel_page_size)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, (usedBytes / totalBytes) * 100))
    }

    private func isSelfClusterEndpoint(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return false
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let localHosts = Set([
            "127.0.0.1",
            "localhost",
            "::1",
            ProcessInfo.processInfo.hostName.lowercased(),
            Host.current().name?.lowercased(),
            Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased()
        ].compactMap { $0 })

        return localHosts.contains(host) && port == listenPort
    }

    private func publishSnapshot() async {
        await onSnapshot?(snapshot)
    }

    private func recordJobLog(
        user: String,
        server: String,
        command: String,
        channel: String,
        executionRoute: String,
        ok: Bool
    ) async {
        let entry = CommandLogEntry(
            time: Date(),
            user: user,
            server: server,
            command: command,
            channel: channel,
            executionRoute: executionRoute,
            executionNode: nodeName,
            ok: ok
        )
        await onJobLog?(entry)
    }

    private func decodeWikiJobRequest(from data: Data) -> WikiJobRequest? {
        if let request = try? decoder.decode(WikiJobRequest.self, from: data) {
            return request
        }
        if let legacy = try? decoder.decode(LegacyWikiJobRequest.self, from: data) {
            return WikiJobRequest(query: legacy.query, source: .defaultFinals())
        }
        return nil
    }
}

#if DEBUG
extension ClusterCoordinator {
    func testIsSSRFSafeHost(_ host: String) -> Bool {
        isSSRFSafeHost(host)
    }

    func testNormalizedBaseURL(_ raw: String) -> String? {
        normalizedBaseURL(raw)
    }

    func testProcessHTTPRequest(_ data: Data) async -> Data {
        await processHTTPRequest(data)
    }

    func testExceedsHTTPRequestSizeCap(_ contentLength: Int) -> Bool {
        contentLength > Self.maxHTTPRequestSize
    }
}
#endif

private struct RegisteredWorker: Hashable, Sendable {
    var nodeName: String
    var baseURL: String
    var listenPort: Int
    var lastSeen: Date
}

private struct WorkerRegistrationRequest: Codable {
    let nodeName: String
    let baseURL: String
    let listenPort: Int
}

private struct WorkerRegistrationResponse: Codable {
    let status: String
    let leaderNodeName: String
    let registeredWorkers: Int
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct AIJobRequest: Codable {
    let messages: [Message]
    let serverName: String?
    let channelName: String?
    let wikiContext: String?
}

private struct AIJobResponse: Codable {
    let nodeName: String
    let reply: String
}

private struct WikiJobRequest: Codable {
    let query: String
    let source: WikiSource
}

private struct LegacyWikiJobRequest: Codable {
    let query: String
}

private struct WikiJobResponse: Codable {
    let nodeName: String
    let result: FinalsWikiLookupResult
}

private struct HealthResponse: Codable {
    let nodeName: String
    let mode: String
    let status: String
}

private struct ClusterPingResponse: Codable {
    let status: String
    let role: String
    let node: String
}

struct ClusterProbeResponse: Codable {
    let nodeName: String
    let mode: String
    let listenPort: Int
    let timestamp: String
}
