import Foundation
import OSLog

struct AdminWebPublicAccessRuntimeStatus: Sendable, Equatable {
    enum State: String, Sendable {
        case disabled
        case enabling
        case enabled
        case error
    }

    var state: State = .disabled
    var publicURL: String = ""
    var detail: String = ""

    var isEnabled: Bool {
        state == .enabled
    }
}

struct TunnelRuntimeConfiguration: Sendable, Equatable {
    let hostname: String
    let publicURL: String
    let originURL: String
    let tunnelToken: String
}

protocol TunnelProvider: Sendable {
    func configure(
        _ configuration: TunnelRuntimeConfiguration?,
        logger: @escaping @MainActor @Sendable (String) -> Void,
        statusHandler: @escaping @MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void
    ) async
}

actor TunnelManager: TunnelProvider {
    static let shared = TunnelManager()

    enum Error: LocalizedError {
        case missingTunnelToken
        case missingCloudflaredBinary
        case cloudflaredNotExecutable

        var errorDescription: String? {
            switch self {
            case .missingTunnelToken:
                return "SwiftBot could not find the stored Cloudflare Tunnel token."
            case .missingCloudflaredBinary:
                return "SwiftBot could not find the bundled cloudflared helper."
            case .cloudflaredNotExecutable:
                return "The bundled cloudflared helper is not executable."
            }
        }
    }

    private static let fallbackBinaryPaths = [
        "/usr/local/bin/cloudflared",
        "/opt/homebrew/bin/cloudflared"
    ]

    private let osLogger = Logger(subsystem: "com.swiftbot", category: "security")
    private var desiredConfiguration: TunnelRuntimeConfiguration?
    private var process: Process?
    private var restartTask: Task<Void, Never>?
    private var isStoppingProcess = false
    private var nextStartIsRestart = false
    private var logger: (@MainActor @Sendable (String) -> Void)?
    private var statusHandler: (@MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void)?
    private var consecutiveFailures = 0
    private var lastRegistrationError: String?
    /// Stop auto-restarting after this many consecutive failures so the loop
    /// doesn't burn CPU forever when the tunnel credential is bad.
    private static let maxConsecutiveFailures = 5

    func configure(
        _ configuration: TunnelRuntimeConfiguration?,
        logger: @escaping @MainActor @Sendable (String) -> Void,
        statusHandler: @escaping @MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void
    ) async {
        self.logger = logger
        self.statusHandler = statusHandler

        guard let configuration else {
            await stop(clearDesiredConfiguration: true)
            return
        }

        let previousConfiguration = desiredConfiguration
        desiredConfiguration = configuration

        if let process, process.isRunning, previousConfiguration == configuration {
            await publishStatus(.init(
                state: .enabled,
                publicURL: configuration.publicURL,
                detail: "Traffic is routed securely through Cloudflare Tunnel."
            ))
            return
        }

        // Fresh configuration ⇒ reset the failure counter so a corrected token
        // gets a full retry budget.
        if previousConfiguration != configuration {
            consecutiveFailures = 0
            lastRegistrationError = nil
        }
        await stop(clearDesiredConfiguration: false)
        await startProcess(using: configuration)
    }

    func stop(clearDesiredConfiguration: Bool = true) async {
        restartTask?.cancel()
        restartTask = nil

        if clearDesiredConfiguration {
            desiredConfiguration = nil
        }
        nextStartIsRestart = false

        guard let process else {
            await publishStatus(.init(
                state: .disabled,
                publicURL: desiredConfiguration?.publicURL ?? "",
                detail: "Public access disabled"
            ))
            return
        }

        isStoppingProcess = true
        process.terminationHandler = nil

        if process.isRunning {
            process.terminate()
            await logger?("Cloudflare tunnel stopped")
        }

        self.process = nil
        isStoppingProcess = false

        await publishStatus(.init(
            state: desiredConfiguration == nil ? .disabled : .enabling,
            publicURL: desiredConfiguration?.publicURL ?? "",
            detail: desiredConfiguration == nil ? "Public access disabled" : "Cloudflare tunnel starting"
        ))
    }

    private func startProcess(using configuration: TunnelRuntimeConfiguration) async {
        do {
            guard !configuration.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.missingTunnelToken
            }

            let binaryURL = try Self.resolveCloudflaredBinaryURL()

            await publishStatus(.init(
                state: .enabling,
                publicURL: configuration.publicURL,
                detail: "Cloudflare tunnel starting"
            ))

            let process = Process()
            process.executableURL = binaryURL
            process.arguments = [
                "tunnel",
                "--no-autoupdate",
                "run",
                "--token",
                configuration.tunnelToken
            ]
            process.environment = ProcessInfo.processInfo.environment

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe
            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
                #if DEBUG
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    self?.osLogger.debug("TunnelManager: \(trimmed)")
                }
                #endif
                Task { [weak self] in
                    await self?.handleCloudflaredOutput(output, publicURL: configuration.publicURL)
                }
            }

            process.terminationHandler = { [weak self] terminatedProcess in
                Task {
                    await self?.handleTermination(status: terminatedProcess.terminationStatus)
                }
            }

            try process.run()
            self.process = process

            if nextStartIsRestart {
                nextStartIsRestart = false
                await logger?("Cloudflare tunnel restarted")
            } else {
                await logger?("Cloudflare tunnel running")
            }
            // Don't claim `.enabled` until cloudflared actually registers with
            // the edge — see handleCloudflaredOutput.
            await publishStatus(.init(
                state: .enabling,
                publicURL: configuration.publicURL,
                detail: "Connecting to Cloudflare edge…"
            ))
        } catch {
            await publishStatus(.init(
                state: .error,
                publicURL: configuration.publicURL,
                detail: error.localizedDescription
            ))
            await logger?("⚠️ Tunnel failed: \(error.localizedDescription)")
        }
    }

    private func handleCloudflaredOutput(_ output: String, publicURL: String) async {
        // cloudflared logs "Registered tunnel connection" once a connection is
        // accepted by the edge — that's our signal we're really live.
        if output.contains("Registered tunnel connection") {
            if consecutiveFailures != 0 || lastRegistrationError != nil {
                consecutiveFailures = 0
                lastRegistrationError = nil
            }
            await publishStatus(.init(
                state: .enabled,
                publicURL: publicURL,
                detail: "Traffic is routed securely through Cloudflare Tunnel."
            ))
            return
        }
        // Cloudflare's edge rejected the tunnel — almost always a stale or
        // wrong token, or a tunnel that has been deleted on the dashboard.
        if output.contains("error registering the connection")
            || output.contains("Register tunnel error from server side") {
            lastRegistrationError = "Cloudflare rejected the tunnel registration. The tunnel token may be invalid, revoked, or for a deleted tunnel — check the Cloudflare Zero Trust dashboard."
        }
    }

    private func handleTermination(status: Int32) async {
        let currentConfiguration = desiredConfiguration
        process = nil

        guard let currentConfiguration else {
            await publishStatus(.init(state: .disabled, publicURL: "", detail: "Public access disabled"))
            return
        }

        if isStoppingProcess {
            await publishStatus(.init(
                state: .disabled,
                publicURL: currentConfiguration.publicURL,
                detail: "Public access disabled"
            ))
            return
        }

        consecutiveFailures += 1

        if consecutiveFailures >= Self.maxConsecutiveFailures {
            let detail = lastRegistrationError
                ?? "Cloudflare tunnel failed to start after \(consecutiveFailures) attempts."
            await logger?("⚠️ \(detail)")
            await publishStatus(.init(
                state: .error,
                publicURL: currentConfiguration.publicURL,
                detail: detail
            ))
            return
        }

        let detail = lastRegistrationError
            ?? "Cloudflare tunnel stopped unexpectedly. Restarting…"
        await logger?("⚠️ \(detail)")
        await publishStatus(.init(
            state: .error,
            publicURL: currentConfiguration.publicURL,
            detail: detail
        ))

        // Exponential backoff: 2s, 4s, 8s, 16s, …
        let delaySeconds = min(30, 1 << consecutiveFailures)
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.markNextStartAsRestart()
            await self?.startProcess(using: currentConfiguration)
        }
    }

    private func publishStatus(_ status: AdminWebPublicAccessRuntimeStatus) async {
        await statusHandler?(status)
    }

    private func markNextStartAsRestart() {
        nextStartIsRestart = true
    }

    nonisolated static func resolveCloudflaredBinaryURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) throws -> URL {
        var foundBundledBinaryThatIsNotExecutable = false
        for candidate in bundledCloudflaredCandidateURLs(bundle: bundle) {
            let path = candidate.path
            guard fileManager.fileExists(atPath: path) else {
                continue
            }
            guard fileManager.isExecutableFile(atPath: path) else {
                foundBundledBinaryThatIsNotExecutable = true
                continue
            }
            return candidate
        }

        if foundBundledBinaryThatIsNotExecutable {
            throw Error.cloudflaredNotExecutable
        }

        if let fallbackPath = fallbackBinaryPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: fallbackPath)
        }

        throw Error.missingCloudflaredBinary
    }

    nonisolated private static func bundledCloudflaredCandidateURLs(bundle: Bundle) -> [URL] {
        [
            bundle.url(forResource: "cloudflared", withExtension: nil),
            bundle.resourceURL?
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("cloudflared")
        ]
        .compactMap { $0 }
    }
}
