import Foundation

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

actor PublicAccessManager {
    struct Configuration: Sendable, Equatable {
        let hostname: String
        let publicURL: String
        let originURL: String
        let tunnelToken: String
    }

    enum Error: LocalizedError {
        case missingTunnelToken
        case missingCloudflaredBinary

        var errorDescription: String? {
            switch self {
            case .missingTunnelToken:
                return "SwiftBot could not find the stored Cloudflare Tunnel token."
            case .missingCloudflaredBinary:
                return "cloudflared is unavailable. Reinstall SwiftBot or install cloudflared manually."
            }
        }
    }

    private var desiredConfiguration: Configuration?
    private var process: Process?
    private var restartTask: Task<Void, Never>?
    private var isStoppingProcess = false
    private var runtimeStatus = AdminWebPublicAccessRuntimeStatus()
    private var logger: (@MainActor @Sendable (String) -> Void)?
    private var statusHandler: (@MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void)?

    func configure(
        _ configuration: Configuration?,
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
                detail: "Public access enabled"
            ))
            return
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
        }

        self.process = nil
        isStoppingProcess = false

        await publishStatus(.init(
            state: desiredConfiguration == nil ? .disabled : .enabling,
            publicURL: desiredConfiguration?.publicURL ?? "",
            detail: desiredConfiguration == nil ? "Public access disabled" : "Restarting public access"
        ))
    }

    private func startProcess(using configuration: Configuration) async {
        do {
            guard !configuration.tunnelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.missingTunnelToken
            }

            guard let binaryPath = CertificateManager.detectCloudflaredInstallation().detectedPath else {
                throw Error.missingCloudflaredBinary
            }

            await logger?("🌐 Starting Public Access tunnel for \(configuration.hostname)")
            await publishStatus(.init(
                state: .enabling,
                publicURL: configuration.publicURL,
                detail: "Starting Cloudflare Tunnel"
            ))

            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
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

            let outputHandle = outputPipe.fileHandleForReading
            outputHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty,
                      let output = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !output.isEmpty
                else {
                    return
                }

                Task {
                    await self?.logger?("🌐 Public Access: \(output)")
                }
            }

            process.terminationHandler = { [weak self] terminatedProcess in
                Task {
                    await self?.handleTermination(status: terminatedProcess.terminationStatus)
                }
            }

            try process.run()
            self.process = process

            await publishStatus(.init(
                state: .enabled,
                publicURL: configuration.publicURL,
                detail: "SwiftBot is available at \(configuration.publicURL)"
            ))
        } catch {
            await publishStatus(.init(
                state: .error,
                publicURL: configuration.publicURL,
                detail: error.localizedDescription
            ))
            await logger?("⚠️ Public Access failed to start: \(error.localizedDescription)")
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

        await logger?("⚠️ Public Access tunnel exited unexpectedly with status \(status). Restarting…")
        await publishStatus(.init(
            state: .error,
            publicURL: currentConfiguration.publicURL,
            detail: "The Cloudflare Tunnel stopped unexpectedly. Restarting…"
        ))

        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.startProcess(using: currentConfiguration)
        }
    }

    private func publishStatus(_ status: AdminWebPublicAccessRuntimeStatus) async {
        runtimeStatus = status
        await statusHandler?(status)
    }
}
