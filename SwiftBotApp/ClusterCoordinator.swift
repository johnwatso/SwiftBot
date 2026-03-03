import Foundation
import Network

actor ClusterCoordinator {
    typealias AIHandler = @Sendable ([Message]) async -> String?
    typealias WikiHandler = @Sendable (String, WikiBridgeSourceTarget) async -> FinalsWikiLookupResult?
    typealias JobLogHandler = @Sendable (CommandLogEntry) async -> Void

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var mode: ClusterMode = .standalone
    private var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    private var workerBaseURL: String = ""
    private var listenPort: Int = 38787

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

    func applySettings(mode: ClusterMode, nodeName: String, workerBaseURL: String, listenPort: Int) async {
        self.mode = mode
        self.nodeName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workerBaseURL = workerBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.listenPort = listenPort

        snapshot.mode = mode
        snapshot.nodeName = self.nodeName
        snapshot.listenPort = listenPort
        snapshot.workerBaseURL = self.workerBaseURL
        snapshot.diagnostics = "Applied mode \(mode.rawValue)"
        snapshot.lastJobNode = self.nodeName

        await restartServerIfNeeded()
        await refreshWorkerHealth()
        await publishSnapshot()
    }

    func stopAll() async {
        listener?.cancel()
        listener = nil
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
        guard mode == .leader, !workerBaseURL.isEmpty else {
            snapshot.workerState = mode == .leader ? .inactive : .inactive
            snapshot.workerStatusText = mode == .leader ? "No worker configured" : "Not applicable"
            snapshot.diagnostics = mode == .leader ? "Leader has no worker URL configured" : "Worker health is not checked in this mode"
            await publishSnapshot()
            return
        }

        guard let url = URL(string: workerBaseURL + "/health") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid worker URL"
            snapshot.diagnostics = "Worker URL is invalid: \(workerBaseURL)"
            await publishSnapshot()
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Reachable"
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                snapshot.diagnostics = "Worker health OK via \(url.absoluteString): \(body)"
            } else {
                snapshot.workerState = .degraded
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                snapshot.workerStatusText = "Health check failed (\(status))"
                snapshot.diagnostics = "Worker health returned HTTP \(status) via \(url.absoluteString)"
            }
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Unavailable"
            snapshot.diagnostics = "Worker health request failed for \(url.absoluteString): \(error.localizedDescription)"
        }
        await publishSnapshot()
    }

    func generateAIReply(messages: [Message]) async -> String? {
        let job = AIJobRequest(messages: messages)
        if mode == .leader, let remote = await performRemoteAI(job) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "AI reply via worker"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.reply
        }

        let local = await aiHandler?(messages)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "AI reply unavailable" : "AI reply local"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled AI reply locally on \(nodeName)"
        }
        await publishSnapshot()
        return local
    }

    func lookupWiki(query: String, source: WikiBridgeSourceTarget) async -> FinalsWikiLookupResult? {
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
            snapshot.diagnostics = "Remote worker probe is only available in leader mode"
            await publishSnapshot()
            return nil
        }

        guard let url = URL(string: workerBaseURL + "/v1/probe") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid worker URL"
            snapshot.diagnostics = "Remote probe URL invalid: \(workerBaseURL)"
            await publishSnapshot()
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Remote probe failed"
                snapshot.diagnostics = "Remote probe returned non-2xx from \(url.absoluteString)"
                await publishSnapshot()
                return nil
            }

            let decoded = try decoder.decode(ClusterProbeResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Remote probe OK"
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Remote worker probe"
            snapshot.lastJobNode = decoded.nodeName
            snapshot.diagnostics = "Worker \(decoded.nodeName) responded via \(url.absoluteString)"
            await publishSnapshot()
            return decoded
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Remote probe unavailable"
            snapshot.diagnostics = "Remote probe request failed for \(url.absoluteString): \(error.localizedDescription)"
            await publishSnapshot()
            return nil
        }
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
        while true {
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.upperBound]
                let contentLength = parseContentLength(headerData)
                let bodyLength = buffer.count - headerRange.upperBound
                if bodyLength >= contentLength {
                    return buffer
                }
            }
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

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let payload = HealthResponse(nodeName: nodeName, mode: mode.rawValue, status: "ok")
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
            guard let aiHandler,
                  let body = try? decoder.decode(AIJobRequest.self, from: request.body),
                  let reply = await aiHandler(body.messages) else {
                await recordJobLog(
                    user: "Remote AI",
                    server: "Cluster",
                    command: "POST /v1/ai-reply",
                    channel: "worker",
                    executionRoute: "Worker",
                    ok: false
                )
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
        return HTTPRequest(method: String(parts[0]), path: String(parts[1]), body: body)
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

    private func performRemoteAI(_ job: AIJobRequest) async -> AIJobResponse? {
        guard let url = URL(string: workerBaseURL + "/v1/ai-reply") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid worker URL"
            snapshot.diagnostics = "Remote AI URL invalid: \(workerBaseURL)"
            await publishSnapshot()
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(job)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Remote AI failed"
                snapshot.diagnostics = "Remote AI returned non-2xx from \(url.absoluteString)"
                await publishSnapshot()
                return nil
            }
            let decoded = try decoder.decode(AIJobResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Remote AI available"
            snapshot.diagnostics = "Remote AI succeeded via \(url.absoluteString)"
            await publishSnapshot()
            return decoded
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Remote AI unavailable"
            snapshot.diagnostics = "Remote AI request failed for \(url.absoluteString): \(error.localizedDescription)"
            await publishSnapshot()
            return nil
        }
    }

    private func performRemoteWikiLookup(query: String, source: WikiBridgeSourceTarget) async -> WikiJobResponse? {
        guard let url = URL(string: workerBaseURL + "/v1/wiki-lookup") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid worker URL"
            snapshot.diagnostics = "Remote wiki URL invalid: \(workerBaseURL)"
            await publishSnapshot()
            return nil
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(WikiJobRequest(query: query, source: source))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Remote wiki failed"
                snapshot.diagnostics = "Remote wiki returned non-2xx from \(url.absoluteString)"
                await publishSnapshot()
                return nil
            }
            let decoded = try decoder.decode(WikiJobResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Remote wiki available"
            snapshot.diagnostics = "Remote wiki succeeded via \(url.absoluteString)"
            await publishSnapshot()
            return decoded
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Remote wiki unavailable"
            snapshot.diagnostics = "Remote wiki request failed for \(url.absoluteString): \(error.localizedDescription)"
            await publishSnapshot()
            return nil
        }
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

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data
}

private struct AIJobRequest: Codable {
    let messages: [Message]
}

private struct AIJobResponse: Codable {
    let nodeName: String
    let reply: String
}

private struct WikiJobRequest: Codable {
    let query: String
    let source: WikiBridgeSourceTarget
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

struct ClusterProbeResponse: Codable {
    let nodeName: String
    let mode: String
    let listenPort: Int
    let timestamp: String
}
