import Foundation
import Network
import Darwin
import NIOCore
import NIOPosix
@preconcurrency import NIOSSL

struct AdminWebStatusPayload: Codable {
    let botStatus: String
    let botUsername: String
    let connectedServerCount: Int
    let gatewayEventCount: Int
    let uptimeText: String?
    let webUIEnabled: Bool
    let webUIBaseURL: String
}

struct AdminWebMetricPayload: Codable {
    let title: String
    let value: String
    let subtitle: String
}

struct AdminWebClusterPayload: Codable {
    let connectedNodes: Int
    let leader: String
    let mode: String
}

struct AdminWebClusterNodePayload: Codable {
    let id: String
    let displayName: String
    let role: String
    let status: String
    let hostname: String
    let hardwareModel: String
    let jobsActive: Int
    let latencyMs: Double?
}

struct AdminWebRecentVoicePayload: Codable {
    let description: String
    let timeText: String
}

struct AdminWebRecentCommandPayload: Codable {
    let title: String
    let timeText: String
    let ok: Bool
}

struct AdminWebActiveVoicePayload: Codable {
    let userId: String
    let username: String
    let channelName: String
    let serverName: String
    let joinedText: String
}

struct AdminWebBotInfoPayload: Codable {
    let uptime: String
    let errors: Int
    let state: String
    let cluster: String?
}

struct AdminWebOverviewPayload: Codable {
    let metrics: [AdminWebMetricPayload]
    let cluster: AdminWebClusterPayload
    let clusterNodes: [AdminWebClusterNodePayload]
    let activeVoice: [AdminWebActiveVoicePayload]
    let recentVoice: [AdminWebRecentVoicePayload]
    let recentCommands: [AdminWebRecentCommandPayload]
    let botInfo: AdminWebBotInfoPayload
}

struct AdminWebConfigPayload: Codable {
    struct Commands: Codable {
        let enabled: Bool
        let prefixEnabled: Bool
        let slashEnabled: Bool
        let bugTrackingEnabled: Bool
        let prefix: String
    }

    struct AIBots: Codable {
        let localAIDMReplyEnabled: Bool
        let preferredProvider: String
        let openAIEnabled: Bool
        let openAIModel: String
        let openAIImageGenerationEnabled: Bool
        let openAIImageMonthlyLimitPerUser: Int
    }

    struct WikiBridge: Codable {
        let enabled: Bool
        let enabledSources: Int
        let totalSources: Int
    }

    struct Patchy: Codable {
        let monitoringEnabled: Bool
        let enabledTargets: Int
        let totalTargets: Int
    }

    struct SwiftMesh: Codable {
        let mode: String
        let nodeName: String
        let leaderAddress: String
        let listenPort: Int
        let offloadAIReplies: Bool
        let offloadWikiLookups: Bool
    }

    struct General: Codable {
        let autoStart: Bool
        let webUIEnabled: Bool
        let webUIBaseURL: String
    }

    let commands: Commands
    let aiBots: AIBots
    let wikiBridge: WikiBridge
    let patchy: Patchy
    let swiftMesh: SwiftMesh
    let general: General
}

struct AdminWebConfigPatch: Codable {
    var commandsEnabled: Bool?
    var prefixCommandsEnabled: Bool?
    var slashCommandsEnabled: Bool?
    var bugTrackingEnabled: Bool?
    var prefix: String?
    var localAIDMReplyEnabled: Bool?
    var preferredAIProvider: String?
    var openAIEnabled: Bool?
    var openAIModel: String?
    var openAIImageGenerationEnabled: Bool?
    var openAIImageMonthlyLimitPerUser: Int?
    var wikiBridgeEnabled: Bool?
    var patchyMonitoringEnabled: Bool?
    var clusterMode: String?
    var clusterNodeName: String?
    var clusterLeaderAddress: String?
    var clusterListenPort: Int?
    var clusterOffloadAIReplies: Bool?
    var clusterOffloadWikiLookups: Bool?
    var autoStart: Bool?
}

struct AdminWebCommandCatalogItem: Codable {
    let id: String
    let name: String
    let usage: String
    let description: String
    let category: String
    let surface: String
    let aliases: [String]
    let adminOnly: Bool
    let enabled: Bool
}

struct AdminWebCommandCatalogPayload: Codable {
    let commandsEnabled: Bool
    let prefixCommandsEnabled: Bool
    let slashCommandsEnabled: Bool
    let items: [AdminWebCommandCatalogItem]
}

struct AdminWebCommandTogglePatch: Codable {
    let name: String
    let surface: String
    let enabled: Bool
}

struct AdminWebSimpleOption: Codable {
    let id: String
    let name: String
}

struct AdminWebActionsPayload: Codable {
    let rules: [Rule]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    let voiceChannelsByServer: [String: [AdminWebSimpleOption]]
    let conditionTypes: [String]
    let actionTypes: [String]
}

struct AdminWebRulePatch: Codable {
    let rule: Rule
}

struct AdminWebRuleIDPatch: Codable {
    let ruleID: UUID
}

struct AdminWebPatchyPayload: Codable {
    let monitoringEnabled: Bool
    let showDebug: Bool
    let isCycleRunning: Bool
    let lastCycleAt: Date?
    let debugLogs: [String]
    let sourceKinds: [String]
    let targets: [PatchySourceTarget]
    let servers: [AdminWebSimpleOption]
    let textChannelsByServer: [String: [AdminWebSimpleOption]]
    let rolesByServer: [String: [AdminWebSimpleOption]]
    let steamAppNames: [String: String]
}

struct AdminWebPatchyStatePatch: Codable {
    let monitoringEnabled: Bool?
    let showDebug: Bool?
}

struct AdminWebPatchyTargetPatch: Codable {
    let target: PatchySourceTarget
}

struct AdminWebPatchyTargetEnabledPatch: Codable {
    let targetID: UUID
    let enabled: Bool
}

struct AdminWebPatchyTargetIDPatch: Codable {
    let targetID: UUID
}

struct AdminWebWikiBridgePayload: Codable {
    let enabled: Bool
    let sources: [WikiSource]
}

struct AdminWebWikiBridgeStatePatch: Codable {
    let enabled: Bool?
}

struct AdminWebWikiSourcePatch: Codable {
    let source: WikiSource
}

struct AdminWebWikiSourceIDPatch: Codable {
    let sourceID: UUID
}

actor AdminWebServer {
    struct RuntimeState: Equatable {
        var isEnabled: Bool
        var isListening: Bool
        var usesTLS: Bool
        var publicBaseURL: String
    }

    private enum OAuthError: LocalizedError {
        case invalidURL
        case tokenExchangeFailed(Int, String)
        case userFetchFailed(Int, String)
        case guildFetchFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid Discord OAuth URL."
            case .tokenExchangeFailed(let status, let body):
                return "Token exchange failed (\(status)): \(body)"
            case .userFetchFailed(let status, let body):
                return "User fetch failed (\(status)): \(body)"
            case .guildFetchFailed(let status, let body):
                return "Guild fetch failed (\(status)): \(body)"
            }
        }
    }

    struct Configuration: Equatable {
        struct HTTPSConfiguration: Equatable {
            var certificatePath: String
            var privateKeyPath: String
            var hostOverride: String?
            var reloadToken: String
        }

        var enabled: Bool
        var bindHost: String
        var port: Int
        var publicBaseURL: String
        var https: HTTPSConfiguration?
        var discordClientID: String
        var discordClientSecret: String
        var redirectPath: String
        var allowedUserIDs: [String]
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private struct Session: Codable {
        let id: String
        let userID: String
        let username: String
        let globalName: String?
        let discriminator: String?
        let avatar: String?
        let csrfToken: String
        let expiresAt: Date
    }

    private struct PendingState {
        let value: String
        let expiresAt: Date
    }

    private struct DiscordUser {
        let id: String
        let username: String
        let globalName: String?
        let discriminator: String?
        let avatar: String?
    }

    private struct DiscordGuildSummary {
        let id: String
        let owner: Bool?
        let permissions: String?
    }

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var config = Configuration(
        enabled: false,
        bindHost: "127.0.0.1",
        port: 38888,
        publicBaseURL: "",
        https: nil,
        discordClientID: "",
        discordClientSecret: "",
        redirectPath: "/auth/discord/callback",
        allowedUserIDs: []
    )
    private var listener: NWListener?
    private var nioChannel: Channel?
    private var nioGroup: MultiThreadedEventLoopGroup?
    private var activePublicBaseURL = ""
    private var activeTransportUsesTLS = false
    private var statusProvider: (@Sendable () async -> AdminWebStatusPayload)?
    private var overviewProvider: (@Sendable () async -> AdminWebOverviewPayload)?
    private var connectedGuildIDsProvider: (@Sendable () async -> Set<String>)?
    private var currentPrefixProvider: (@Sendable () async -> String)?
    private var updatePrefix: (@Sendable (String) async -> Bool)?
    private var configProvider: (@Sendable () async -> AdminWebConfigPayload)?
    private var updateConfig: (@Sendable (AdminWebConfigPatch) async -> Bool)?
    private var commandCatalogProvider: (@Sendable () async -> AdminWebCommandCatalogPayload)?
    private var updateCommandEnabled: (@Sendable (String, String, Bool) async -> Bool)?
    private var actionsProvider: (@Sendable () async -> AdminWebActionsPayload)?
    private var createActionRule: (@Sendable () async -> Rule?)?
    private var updateActionRule: (@Sendable (Rule) async -> Bool)?
    private var deleteActionRule: (@Sendable (UUID) async -> Bool)?
    private var patchyProvider: (@Sendable () async -> AdminWebPatchyPayload)?
    private var updatePatchyState: (@Sendable (AdminWebPatchyStatePatch) async -> Bool)?
    private var createPatchyTarget: (@Sendable () async -> PatchySourceTarget?)?
    private var updatePatchyTarget: (@Sendable (PatchySourceTarget) async -> Bool)?
    private var setPatchyTargetEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var deletePatchyTarget: (@Sendable (UUID) async -> Bool)?
    private var sendPatchyTestTarget: (@Sendable (UUID) async -> Bool)?
    private var runPatchyCheckNow: (@Sendable () async -> Bool)?
    private var wikiBridgeProvider: (@Sendable () async -> AdminWebWikiBridgePayload)?
    private var updateWikiBridgeState: (@Sendable (AdminWebWikiBridgeStatePatch) async -> Bool)?
    private var createWikiSource: (@Sendable () async -> WikiSource?)?
    private var updateWikiSource: (@Sendable (WikiSource) async -> Bool)?
    private var setWikiSourceEnabled: (@Sendable (UUID, Bool) async -> Bool)?
    private var setWikiSourcePrimary: (@Sendable (UUID) async -> Bool)?
    private var testWikiSource: (@Sendable (UUID) async -> Bool)?
    private var deleteWikiSource: (@Sendable (UUID) async -> Bool)?
    private var startBot: (@Sendable () async -> Bool)?
    private var stopBot: (@Sendable () async -> Bool)?
    private var refreshSwiftMesh: (@Sendable () async -> Bool)?
    private var logger: (@Sendable (String) async -> Void)?
    private var sessions: [String: Session] = [:]
    private var pendingStates: [String: PendingState] = [:]
    private let stateTTL: TimeInterval = 600
    private let sessionTTL: TimeInterval = 30 * 24 * 60 * 60
    private let sessionsDefaultsKey = "swiftbot.admin.web.sessions"
    private let maxHTTPRequestSize = 1_024 * 1_024

    func configure(
        config: Configuration,
        statusProvider: @escaping @Sendable () async -> AdminWebStatusPayload,
        overviewProvider: @escaping @Sendable () async -> AdminWebOverviewPayload,
        connectedGuildIDsProvider: @escaping @Sendable () async -> Set<String>,
        currentPrefixProvider: @escaping @Sendable () async -> String,
        updatePrefix: @escaping @Sendable (String) async -> Bool,
        configProvider: @escaping @Sendable () async -> AdminWebConfigPayload,
        updateConfig: @escaping @Sendable (AdminWebConfigPatch) async -> Bool,
        commandCatalogProvider: @escaping @Sendable () async -> AdminWebCommandCatalogPayload,
        updateCommandEnabled: @escaping @Sendable (String, String, Bool) async -> Bool,
        actionsProvider: @escaping @Sendable () async -> AdminWebActionsPayload,
        createActionRule: @escaping @Sendable () async -> Rule?,
        updateActionRule: @escaping @Sendable (Rule) async -> Bool,
        deleteActionRule: @escaping @Sendable (UUID) async -> Bool,
        patchyProvider: @escaping @Sendable () async -> AdminWebPatchyPayload,
        updatePatchyState: @escaping @Sendable (AdminWebPatchyStatePatch) async -> Bool,
        createPatchyTarget: @escaping @Sendable () async -> PatchySourceTarget?,
        updatePatchyTarget: @escaping @Sendable (PatchySourceTarget) async -> Bool,
        setPatchyTargetEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        deletePatchyTarget: @escaping @Sendable (UUID) async -> Bool,
        sendPatchyTestTarget: @escaping @Sendable (UUID) async -> Bool,
        runPatchyCheckNow: @escaping @Sendable () async -> Bool,
        wikiBridgeProvider: @escaping @Sendable () async -> AdminWebWikiBridgePayload,
        updateWikiBridgeState: @escaping @Sendable (AdminWebWikiBridgeStatePatch) async -> Bool,
        createWikiSource: @escaping @Sendable () async -> WikiSource?,
        updateWikiSource: @escaping @Sendable (WikiSource) async -> Bool,
        setWikiSourceEnabled: @escaping @Sendable (UUID, Bool) async -> Bool,
        setWikiSourcePrimary: @escaping @Sendable (UUID) async -> Bool,
        testWikiSource: @escaping @Sendable (UUID) async -> Bool,
        deleteWikiSource: @escaping @Sendable (UUID) async -> Bool,
        startBot: @escaping @Sendable () async -> Bool,
        stopBot: @escaping @Sendable () async -> Bool,
        refreshSwiftMesh: @escaping @Sendable () async -> Bool,
        log: @escaping @Sendable (String) async -> Void
    ) async -> RuntimeState {
        self.statusProvider = statusProvider
        self.overviewProvider = overviewProvider
        self.connectedGuildIDsProvider = connectedGuildIDsProvider
        self.currentPrefixProvider = currentPrefixProvider
        self.updatePrefix = updatePrefix
        self.configProvider = configProvider
        self.updateConfig = updateConfig
        self.commandCatalogProvider = commandCatalogProvider
        self.updateCommandEnabled = updateCommandEnabled
        self.actionsProvider = actionsProvider
        self.createActionRule = createActionRule
        self.updateActionRule = updateActionRule
        self.deleteActionRule = deleteActionRule
        self.patchyProvider = patchyProvider
        self.updatePatchyState = updatePatchyState
        self.createPatchyTarget = createPatchyTarget
        self.updatePatchyTarget = updatePatchyTarget
        self.setPatchyTargetEnabled = setPatchyTargetEnabled
        self.deletePatchyTarget = deletePatchyTarget
        self.sendPatchyTestTarget = sendPatchyTestTarget
        self.runPatchyCheckNow = runPatchyCheckNow
        self.wikiBridgeProvider = wikiBridgeProvider
        self.updateWikiBridgeState = updateWikiBridgeState
        self.createWikiSource = createWikiSource
        self.updateWikiSource = updateWikiSource
        self.setWikiSourceEnabled = setWikiSourceEnabled
        self.setWikiSourcePrimary = setWikiSourcePrimary
        self.testWikiSource = testWikiSource
        self.deleteWikiSource = deleteWikiSource
        self.startBot = startBot
        self.stopBot = stopBot
        self.refreshSwiftMesh = refreshSwiftMesh
        self.logger = log

        loadPersistedSessions()
        let previous = self.config
        self.config = config

        if !config.enabled {
            await stop()
            return runtimeState()
        }

        let hasActiveListener = listener != nil || nioChannel != nil
        let needsRestart = !hasActiveListener
            || previous.bindHost != config.bindHost
            || previous.port != config.port
            || previous.https != config.https

        if needsRestart {
            await restart()
        } else {
            activePublicBaseURL = resolvedPublicBaseURL(usingTLS: activeTransportUsesTLS)
        }
        return runtimeState()
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        await stopNIOServer()
        activeTransportUsesTLS = false
        activePublicBaseURL = resolvedPublicBaseURL(usingTLS: false)
        pendingStates.removeAll()
        await logger?("Admin Web UI stopped")
    }

    func restartListener() async -> RuntimeState {
        guard config.enabled else {
            await stop()
            return runtimeState()
        }
        await restart()
        return runtimeState()
    }

    private func restart() async {
        listener?.cancel()
        listener = nil
        await stopNIOServer()

        if let httpsConfiguration = config.https {
            do {
                try await startTLSServer(httpsConfiguration)
                return
            } catch {
                await logger?("Admin Web UI TLS failed: \(error.localizedDescription). Falling back to HTTP.")
            }
        }

        await startPlainHTTPServer()
    }

    private func startPlainHTTPServer() async {
        do {
            let port = NWEndpoint.Port(rawValue: UInt16(config.port)) ?? NWEndpoint.Port(integerLiteral: 38888)
            let listener = try NWListener(using: .tcp, on: port)
            markListenerReady(usingTLS: false)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: DispatchQueue.global(qos: .utility))
                Task {
                    await self.handleConnection(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task {
                    switch state {
                    case .ready:
                        await self.markListenerReady(usingTLS: false)
                        await self.logger?("Admin Web UI listening on http://\(self.config.bindHost):\(self.config.port)")
                    case .failed(let error):
                        await self.logger?("Admin Web UI failed: \(error.localizedDescription)")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: DispatchQueue.global(qos: .utility))
            self.listener = listener
        } catch {
            await logger?("Admin Web UI failed to start: \(error.localizedDescription)")
        }
    }

    private func startTLSServer(_ httpsConfiguration: Configuration.HTTPSConfiguration) async throws {
        let certificateChain = try NIOSSLCertificate
            .fromPEMFile(httpsConfiguration.certificatePath)
            .map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: httpsConfiguration.privateKeyPath, format: .pem)
        let tlsConfiguration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificateChain,
            privateKey: .privateKey(privateKey)
        )
        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
                .childChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
                .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
                .childChannelInitializer { channel in
                    do {
                        let tlsHandler = NIOSSLServerHandler(context: sslContext)
                        let httpHandler = AdminWebNIOHTTPHandler(
                            maxHTTPRequestSize: self.maxHTTPRequestSize,
                            processor: { requestData in
                                return await self.process(requestData)
                            }
                        )
                        try channel.pipeline.syncOperations.addHandlers(tlsHandler, httpHandler)
                        return channel.eventLoop.makeSucceededFuture(())
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

            let channel = try await bootstrap.bind(host: config.bindHost, port: config.port).get()
            self.nioGroup = group
            self.nioChannel = channel
            markListenerReady(usingTLS: true)
            await logger?("Admin Web UI listening on https://\(config.bindHost):\(config.port)")
        } catch {
            try? await shutdownEventLoopGroup(group)
            throw error
        }
    }

    private func stopNIOServer() async {
        if let channel = nioChannel {
            nioChannel = nil
            try? await channel.close().get()
        }

        if let group = nioGroup {
            nioGroup = nil
            try? await shutdownEventLoopGroup(group)
        }
    }

    private func shutdownEventLoopGroup(_ group: EventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func markListenerReady(usingTLS: Bool) {
        activeTransportUsesTLS = usingTLS
        activePublicBaseURL = resolvedPublicBaseURL(usingTLS: usingTLS)
    }

    private func runtimeState() -> RuntimeState {
        RuntimeState(
            isEnabled: config.enabled,
            isListening: listener != nil || nioChannel != nil,
            usesTLS: activeTransportUsesTLS && (listener != nil || nioChannel != nil),
            publicBaseURL: activePublicBaseURL.isEmpty
                ? resolvedPublicBaseURL(usingTLS: config.https != nil)
                : activePublicBaseURL
        )
    }

    private func resolvedPublicBaseURL(usingTLS: Bool) -> String {
        let explicit = config.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let scheme = usingTLS ? "https" : "http"
        let host = usingTLS ? (config.https?.hostOverride ?? config.bindHost) : config.bindHost
        let isDefaultPort = (usingTLS && config.port == 443) || (!usingTLS && config.port == 80)
        if isDefaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(config.port)"
    }

    private func handleConnection(_ connection: NWConnection) async {
        defer {
            connection.cancel()
        }

        do {
            let requestData = try await receiveHTTPRequest(from: connection)
            let response = await process(requestData)
            try await send(response, over: connection)
        } catch {
            let response = httpResponse(
                status: "400 Bad Request",
                body: Data("{\"error\":\"bad_request\"}".utf8),
                contentType: "application/json; charset=utf-8"
            )
            try? await send(response, over: connection)
        }
    }

    private func receiveHTTPRequest(from connection: NWConnection) async throws -> Data {
        var buffer = Data()

        while true {
            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if buffer.count > maxHTTPRequestSize {
                throw NSError(domain: "AdminWebServer", code: 1)
            }

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
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    private func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let count = Int(value.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }

    private func process(_ requestData: Data) async -> Data {
        guard let request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data("Invalid request".utf8))
        }

        pruneExpiredState()
        pruneExpiredSessions()

        if request.method == "GET" && request.path == config.redirectPath {
            return await handleDiscordCallback(request: request)
        }

        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return serveIndex()
        case ("GET", "/assets/AppIcon.png"):
            return serveAsset(named: "AppIcon", ext: "png")
        case ("GET", "/health"):
            return jsonResponse(["status": "ok"])
        case ("GET", "/api/status"):
            let payload = await statusProvider?() ?? AdminWebStatusPayload(
                botStatus: "stopped",
                botUsername: "SwiftBot",
                connectedServerCount: 0,
                gatewayEventCount: 0,
                uptimeText: nil,
                webUIEnabled: false,
                webUIBaseURL: ""
            )
            return codableResponse(payload)
        case ("GET", "/api/overview"):
            let payload = await overviewProvider?() ?? AdminWebOverviewPayload(
                metrics: [],
                cluster: AdminWebClusterPayload(connectedNodes: 0, leader: "Unavailable", mode: "standalone"),
                clusterNodes: [],
                activeVoice: [],
                recentVoice: [],
                recentCommands: [],
                botInfo: AdminWebBotInfoPayload(uptime: "--", errors: 0, state: "Stopped", cluster: nil)
            )
            return codableResponse(payload)
        case ("GET", "/api/me"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            return jsonResponse([
                "id": session.userID,
                "username": session.username,
                "globalName": session.globalName ?? "",
                "discriminator": session.discriminator ?? "",
                "avatar": session.avatar ?? "",
                "csrfToken": session.csrfToken
            ])
        case ("GET", "/api/settings"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            let prefix = await currentPrefixProvider?() ?? "/"
            return jsonResponse(["prefix": prefix])
        case ("GET", "/api/config"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await configProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "config_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/settings/prefix"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard
                let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                let prefix = body["prefix"] as? String,
                await updatePrefix?(prefix) == true
            else {
                return jsonResponse(["error": "invalid_prefix"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI updated command prefix")
            return jsonResponse(["ok": true])
        case ("POST", "/api/config"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebConfigPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateConfig?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI updated configuration")
            return jsonResponse(["ok": true])
        case ("GET", "/api/commands"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await commandCatalogProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "commands_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/commands/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebCommandTogglePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateCommandEnabled?(patch.name, patch.surface, patch.enabled) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            await logger?("Admin Web UI toggled command \(patch.surface):\(patch.name) -> \(patch.enabled)")
            return jsonResponse(["ok": true])
        case ("GET", "/api/actions"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await actionsProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "actions_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/actions/new"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let rule = await createActionRule?() else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            return codableResponse(rule)
        case ("POST", "/api/actions/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebRulePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateActionRule?(patch.rule) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/actions/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebRuleIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteActionRule?(patch.ruleID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/patchy"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await patchyProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "patchy_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/patchy/state"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyStatePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updatePatchyState?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/check"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard await runPatchyCheckNow?() == true else {
                return jsonResponse(["error": "run_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/new"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let target = await createPatchyTarget?() else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            return codableResponse(target)
        case ("POST", "/api/patchy/target/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updatePatchyTarget?(patch.target) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetEnabledPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setPatchyTargetEnabled?(patch.targetID, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deletePatchyTarget?(patch.targetID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/patchy/target/test"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await sendPatchyTestTarget?(patch.targetID) == true else {
                return jsonResponse(["error": "test_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("GET", "/api/wikibridge"):
            guard authenticatedSession(for: request) != nil else {
                return unauthorizedResponse()
            }
            if let payload = await wikiBridgeProvider?() {
                return codableResponse(payload)
            }
            return jsonResponse(["error": "wikibridge_unavailable"], status: "503 Service Unavailable")
        case ("POST", "/api/wikibridge/state"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiBridgeStatePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateWikiBridgeState?(patch) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/new"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let source = await createWikiSource?() else {
                return jsonResponse(["error": "create_failed"], status: "400 Bad Request")
            }
            return codableResponse(source)
        case ("POST", "/api/wikibridge/source/upsert"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourcePatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await updateWikiSource?(patch.source) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/toggle"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebPatchyTargetEnabledPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setWikiSourceEnabled?(patch.targetID, patch.enabled) == true else {
                return jsonResponse(["error": "toggle_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/primary"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await setWikiSourcePrimary?(patch.sourceID) == true else {
                return jsonResponse(["error": "update_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/test"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await testWikiSource?(patch.sourceID) == true else {
                return jsonResponse(["error": "test_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/wikibridge/source/delete"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            guard let patch = try? decoder.decode(AdminWebWikiSourceIDPatch.self, from: request.body) else {
                return jsonResponse(["error": "invalid_payload"], status: "400 Bad Request")
            }
            guard await deleteWikiSource?(patch.sourceID) == true else {
                return jsonResponse(["error": "delete_failed"], status: "400 Bad Request")
            }
            return jsonResponse(["ok": true])
        case ("POST", "/api/bot/start"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await startBot?()
            await logger?("Admin Web UI requested bot start")
            return jsonResponse(["ok": true])
        case ("POST", "/api/bot/stop"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await stopBot?()
            await logger?("Admin Web UI requested bot stop")
            return jsonResponse(["ok": true])
        case ("POST", "/api/swiftmesh/refresh"):
            guard let session = authenticatedSession(for: request) else {
                return unauthorizedResponse()
            }
            guard validateCSRF(session: session, request: request) else {
                return jsonResponse(["error": "csrf_mismatch"], status: "403 Forbidden")
            }
            _ = await refreshSwiftMesh?()
            await logger?("Admin Web UI requested SwiftMesh refresh")
            return jsonResponse(["ok": true])
        case ("GET", "/auth/discord/login"):
            return await handleDiscordLogin()
        case ("POST", "/auth/logout"):
            return handleLogout(request: request)
        default:
            return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
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

        let rawTarget = String(parts[1])
        let components = URLComponents(string: "http://localhost\(rawTarget)")
        let path = components?.path.isEmpty == false ? components?.path ?? "/" : "/"
        var query: [String: String] = [:]
        components?.queryItems?.forEach { item in
            query[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: body)
    }

    private func serveIndex() -> Data {
        var candidates: [(Bundle, String)] = [
            (.main, "admin"),
            (.main, "Resources/admin")
        ]

#if SWIFT_PACKAGE
        candidates.append((.module, "admin"))
#endif

        for (bundle, subdirectory) in candidates {
            if let url = bundle.url(forResource: "index", withExtension: "html", subdirectory: subdirectory),
               let data = try? Data(contentsOf: url) {
                return httpResponse(status: "200 OK", body: data, contentType: "text/html; charset=utf-8")
            }
        }

        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let data = try? Data(contentsOf: url) {
            return httpResponse(status: "200 OK", body: data, contentType: "text/html; charset=utf-8")
        }

        let fallback = "<html><body><h1>SwiftBot Admin UI</h1><p>Missing bundled resource.</p></body></html>"
        return httpResponse(status: "200 OK", body: Data(fallback.utf8), contentType: "text/html; charset=utf-8")
    }

    private func serveAsset(named name: String, ext: String) -> Data {
        let candidates: [(Bundle, String)] = [
            (.main, "Resources"),
            (.main, "admin"),
            (.main, "Resources/admin")
        ]

        for (bundle, subdirectory) in candidates {
            if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
               let data = try? Data(contentsOf: url) {
                return httpResponse(status: "200 OK", body: data, contentType: "image/png")
            }
        }

        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return httpResponse(status: "200 OK", body: data, contentType: "image/png")
        }

        return httpResponse(status: "404 Not Found", body: Data("Not Found".utf8))
    }

    private func handleDiscordLogin() async -> Data {
        let clientID = config.discordClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = config.discordClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return httpResponse(status: "503 Service Unavailable", body: Data("Discord OAuth is not configured.".utf8))
        }

        let state = randomToken()
        pendingStates[state] = PendingState(value: state, expiresAt: Date().addingTimeInterval(stateTTL))

        var components = URLComponents(string: "https://discord.com/api/oauth2/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI()),
            URLQueryItem(name: "scope", value: "identify guilds"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        guard let url = components?.url else {
            return httpResponse(status: "500 Internal Server Error", body: Data("Failed to build OAuth URL.".utf8))
        }

        return redirectResponse(to: url.absoluteString)
    }

    private func handleDiscordCallback(request: HTTPRequest) async -> Data {
        guard let code = request.query["code"], let state = request.query["state"] else {
            return httpResponse(status: "400 Bad Request", body: Data("Missing code or state.".utf8))
        }
        guard pendingStates.removeValue(forKey: state) != nil else {
            return httpResponse(status: "400 Bad Request", body: Data("State expired or invalid.".utf8))
        }

        do {
            let token = try await exchangeDiscordCode(code: code)
            let user = try await fetchDiscordUser(accessToken: token)
            let guilds = try await fetchDiscordGuilds(accessToken: token)
            guard await isAuthorized(userID: user.id, guilds: guilds) else {
                return httpResponse(status: "403 Forbidden", body: Data("This Discord account is not allowed.".utf8))
            }

            let session = Session(
                id: randomToken(),
                userID: user.id,
                username: user.username,
                globalName: user.globalName,
                discriminator: user.discriminator,
                avatar: user.avatar,
                csrfToken: randomToken(),
                expiresAt: Date().addingTimeInterval(sessionTTL)
            )
            sessions[session.id] = session
            persistSessions()
            await logger?("Admin Web UI login for \(user.username) (\(user.id))")
            return redirectResponse(
                to: "/",
                headers: ["Set-Cookie": sessionCookie(for: session.id)]
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await logger?("Admin Web UI OAuth failed: \(message)")
            return httpResponse(status: "502 Bad Gateway", body: Data("Discord OAuth failed: \(message)".utf8))
        }
    }

    private func handleLogout(request: HTTPRequest) -> Data {
        if let sessionID = cookie(named: "swiftbot_admin_session", request: request) {
            sessions.removeValue(forKey: sessionID)
            persistSessions()
        }
        return jsonResponse(
            ["ok": true],
            headers: ["Set-Cookie": "swiftbot_admin_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"]
        )
    }

    private func authenticatedSession(for request: HTTPRequest) -> Session? {
        guard let sessionID = cookie(named: "swiftbot_admin_session", request: request),
              let session = sessions[sessionID],
              session.expiresAt > Date() else {
            return nil
        }
        return session
    }

    private func validateCSRF(session: Session, request: HTTPRequest) -> Bool {
        request.headers["x-admin-csrf"] == session.csrfToken
    }

    private func cookie(named name: String, request: HTTPRequest) -> String? {
        guard let cookieHeader = request.headers["cookie"] else { return nil }
        let cookies = cookieHeader.split(separator: ";")
        for cookie in cookies {
            let parts = cookie.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if key == name {
                return String(parts[1])
            }
        }
        return nil
    }

    private func isAuthorized(userID: String, guilds: [DiscordGuildSummary]) async -> Bool {
        let allowed = config.allowedUserIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if allowed.contains(userID) {
            return true
        }

        let connectedGuildIDs = await connectedGuildIDsProvider?() ?? []
        guard !connectedGuildIDs.isEmpty else { return false }

        return guilds.contains { guild in
            guard connectedGuildIDs.contains(guild.id) else { return false }
            if guild.owner == true { return true }
            guard let raw = guild.permissions, let permissions = UInt64(raw) else { return false }
            let administratorBit: UInt64 = 1 << 3
            let manageGuildBit: UInt64 = 1 << 5
            return (permissions & administratorBit) != 0 || (permissions & manageGuildBit) != 0
        }
    }

    private func exchangeDiscordCode(code: String) async throws -> String {
        guard let url = URL(string: "https://discord.com/api/oauth2/token") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = [
            "client_id": config.discordClientID,
            "client_secret": config.discordClientSecret,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI()
        ]
        request.httpBody = form
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = object["access_token"] as? String,
            !accessToken.isEmpty
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed(http.statusCode, "Unexpected token payload: \(body)")
        }

        return accessToken
    }

    private func fetchDiscordUser(accessToken: String) async throws -> DiscordUser {
        guard let url = URL(string: "https://discord.com/api/users/@me") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.userFetchFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String,
            let username = object["username"] as? String
        else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.userFetchFailed(http.statusCode, "Unexpected user payload: \(body)")
        }

        return DiscordUser(
            id: id,
            username: username,
            globalName: object["global_name"] as? String,
            discriminator: object["discriminator"] as? String,
            avatar: object["avatar"] as? String
        )
    }

    private func fetchDiscordGuilds(accessToken: String) async throws -> [DiscordGuildSummary] {
        guard let url = URL(string: "https://discord.com/api/users/@me/guilds") else {
            throw OAuthError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.guildFetchFailed((response as? HTTPURLResponse)?.statusCode ?? -1, body)
        }

        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.guildFetchFailed(http.statusCode, "Unexpected guild payload: \(body)")
        }

        return array.compactMap { item in
            guard let id = item["id"] as? String else { return nil }

            let owner: Bool?
            if let value = item["owner"] as? Bool {
                owner = value
            } else {
                owner = nil
            }

            let permissions = (item["permissions"] as? String)
                ?? (item["permissions_new"] as? String)
                ?? (item["permissions"] as? NSNumber)?.stringValue
                ?? (item["permissions_new"] as? NSNumber)?.stringValue

            return DiscordGuildSummary(id: id, owner: owner, permissions: permissions)
        }
    }

    private func redirectURI() -> String {
        let resolvedBase = activePublicBaseURL.isEmpty
            ? resolvedPublicBaseURL(usingTLS: config.https != nil)
            : activePublicBaseURL
        let base = resolvedBase.hasSuffix("/") ? String(resolvedBase.dropLast()) : resolvedBase
        return base + config.redirectPath
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    private func randomToken() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sessionCookie(for sessionID: String) -> String {
        "swiftbot_admin_session=\(sessionID); Path=/; HttpOnly; SameSite=Lax; Max-Age=\(Int(sessionTTL))"
    }

    private func pruneExpiredState() {
        let now = Date()
        pendingStates = pendingStates.filter { $0.value.expiresAt > now }
    }

    private func pruneExpiredSessions() {
        let now = Date()
        let beforeCount = sessions.count
        sessions = sessions.filter { $0.value.expiresAt > now }
        if sessions.count != beforeCount {
            persistSessions()
        }
    }

    private func loadPersistedSessions() {
        guard let data = UserDefaults.standard.data(forKey: sessionsDefaultsKey),
              let decoded = try? decoder.decode([String: Session].self, from: data) else {
            sessions = [:]
            return
        }
        let now = Date()
        sessions = decoded.filter { $0.value.expiresAt > now }
    }

    private func persistSessions() {
        if sessions.isEmpty {
            UserDefaults.standard.removeObject(forKey: sessionsDefaultsKey)
            return
        }
        guard let data = try? encoder.encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: sessionsDefaultsKey)
    }

    private func codableResponse<T: Encodable>(_ value: T) -> Data {
        let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return httpResponse(status: "200 OK", body: body, contentType: "application/json; charset=utf-8")
    }

    private func jsonResponse(_ object: [String: Any], status: String = "200 OK", headers: [String: String] = [:]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return httpResponse(status: status, body: data, contentType: "application/json; charset=utf-8", headers: headers)
    }

    private func unauthorizedResponse() -> Data {
        jsonResponse(["error": "unauthorized"], status: "401 Unauthorized")
    }

    private func redirectResponse(to location: String, headers: [String: String] = [:]) -> Data {
        var finalHeaders = headers
        finalHeaders["Location"] = location
        return httpResponse(status: "302 Found", body: Data(), headers: finalHeaders)
    }

    private func httpResponse(
        status: String,
        body: Data,
        contentType: String = "text/plain; charset=utf-8",
        headers: [String: String] = [:]
    ) -> Data {
        var response = "HTTP/1.1 \(status)\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Cache-Control: no-store\r\n"
        headers.forEach { key, value in
            response += "\(key): \(value)\r\n"
        }
        response += "Connection: close\r\n\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }
}

private final class AdminWebNIOHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let badRequestResponse = Data(
        "HTTP/1.1 400 Bad Request\r\nContent-Length: 11\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\nBad Request".utf8
    )

    private let maxHTTPRequestSize: Int
    private let processor: @Sendable (Data) async -> Data
    private var buffer = Data()
    private var isProcessing = false
    private var hasWrittenResponse = false

    init(maxHTTPRequestSize: Int, processor: @escaping @Sendable (Data) async -> Data) {
        self.maxHTTPRequestSize = maxHTTPRequestSize
        self.processor = processor
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !hasWrittenResponse else { return }

        var chunk = unwrapInboundIn(data)
        if let bytes = chunk.readBytes(length: chunk.readableBytes) {
            buffer.append(contentsOf: bytes)
        }

        guard buffer.count <= maxHTTPRequestSize else {
            writeResponse(Self.badRequestResponse, context: context)
            return
        }

        guard !isProcessing, Self.isCompleteHTTPRequest(buffer) else {
            return
        }

        isProcessing = true
        let requestData = buffer
        buffer.removeAll(keepingCapacity: false)

        Task { [weak self] in
            guard let self else { return }
            let response = await self.processor(requestData)
            self.writeResponse(response, context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !hasWrittenResponse else {
            context.close(promise: nil)
            return
        }

        writeResponse(Self.badRequestResponse, context: context)
    }

    private func writeResponse(_ response: Data, context: ChannelHandlerContext) {
        guard !hasWrittenResponse else { return }
        hasWrittenResponse = true

        context.eventLoop.execute {
            var buffer = context.channel.allocator.buffer(capacity: response.count)
            buffer.writeBytes(response)
            context.writeAndFlush(self.wrapOutboundOut(buffer)).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    private static func isCompleteHTTPRequest(_ buffer: Data) -> Bool {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return false
        }

        let headerData = buffer[..<headerRange.upperBound]
        let contentLength = parseContentLength(headerData)
        let bodyLength = buffer.count - headerRange.upperBound
        return bodyLength >= contentLength
    }

    private static func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let text = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in text.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let count = Int(value.trimmingCharacters(in: .whitespaces)) {
                return count
            }
        }
        return 0
    }
}
