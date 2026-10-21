import AppKit
import Foundation

/// Runs SwiftBot's bundled Shortcuts workflows as a system-owned bridge to the
/// Apple Intelligence Cloud model. Results return through Apple's documented
/// x-callback-url flow because the macOS 27 command-line runner can leave its
/// background runner alive after a successful Use Model action.
actor ShortcutIntelligenceBridge {
    static let shared = ShortcutIntelligenceBridge()

    enum Profile: String, CaseIterable, Sendable, Hashable, Identifiable {
        case gamingPatch
        case softwareUpdate
        case generalPatch

        var id: String { rawValue }

        var shortcutName: String {
            switch self {
            case .gamingPatch: "SwiftBot Gaming Patch Update"
            case .softwareUpdate: "SwiftBot Software Update"
            case .generalPatch: "SwiftBot General Patch"
            }
        }

        var title: String {
            switch self {
            case .gamingPatch: "Gaming Patch Update"
            case .softwareUpdate: "Software Update"
            case .generalPatch: "General Patch"
            }
        }

        var detail: String {
            switch self {
            case .gamingPatch:
                "Balance, gameplay, modes, progression, fixes, and regressions."
            case .softwareUpdate:
                "Drivers, operating systems, apps, compatibility, security, and upgrade advice."
            case .generalPatch:
                "User-visible changes, breaking behaviour, migrations, fixes, and known issues."
            }
        }

        var symbolName: String {
            switch self {
            case .gamingPatch: "gamecontroller.fill"
            case .softwareUpdate: "gearshape.2.fill"
            case .generalPatch: "doc.text.fill"
            }
        }
    }

    struct Status: Sendable, Equatable {
        let isSupported: Bool
        let installedProfiles: Set<Profile>
        let readyProfiles: Set<Profile>

        var isInstalled: Bool { installedProfiles.count == Profile.allCases.count }
        var isReady: Bool { readyProfiles.count == Profile.allCases.count }
        var nextMissingProfile: Profile? {
            Profile.allCases.first { !installedProfiles.contains($0) }
        }

        var detail: String {
            if !isSupported { return "Requires macOS 27 or later." }
            if !isInstalled {
                return "Add SwiftBot’s three signed Shortcuts (\(installedProfiles.count)/\(Profile.allCases.count) installed)."
            }
            if !isReady {
                return "Installed. Test each Shortcut once to approve unattended access (\(readyProfiles.count)/\(Profile.allCases.count) ready)."
            }
            return "All three Shortcuts are ready for unattended Private Cloud Compute summaries."
        }
    }

    enum BridgeError: Error, LocalizedError {
        case unsupported
        case shortcutNotInstalled(Profile)
        case bundledShortcutMissing(Profile)
        case installationNotConfirmed(Profile)
        case launchFailed(String)
        case requestInProgress
        case timedOut
        case cancelled
        case executionFailed(String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "SwiftBot's Apple Intelligence Shortcuts require macOS 27 or later."
            case .shortcutNotInstalled(let profile):
                return "The \(profile.shortcutName) Shortcut is not installed."
            case .bundledShortcutMissing(let profile):
                return "SwiftBot's bundled \(profile.title) Shortcut could not be found."
            case .installationNotConfirmed(let profile):
                return "\(profile.title) was not added within five minutes. You can restart setup to try again."
            case .launchFailed(let message):
                return "The Shortcuts runner could not start: \(message)"
            case .requestInProgress:
                return "Another Private Cloud Compute summary is already running."
            case .timedOut:
                return "The Private Cloud Compute request timed out."
            case .cancelled:
                return "The Private Cloud Compute request was cancelled."
            case .executionFailed(let message):
                return message.isEmpty ? "The shortcut failed." : "The shortcut failed: \(message)"
            case .emptyResponse:
                return "The shortcut returned no text."
            }
        }
    }

    fileprivate struct CommandResult: Sendable {
        let terminationStatus: Int32
        let standardOutput: String
        let standardError: String
        let timedOut: Bool
    }

    private static let readinessRevision = 2
    private static let errorPrefix = "SWIFTBOT_BRIDGE_ERROR:"
    private static let maximumPromptCharacters = 60_000
    private static let maximumResponseCharacters = 16_000
    private let defaults: UserDefaults
    private var pendingRequest: PendingRequest?

    private struct PendingRequest {
        let id: String
        let profile: Profile
        let continuation: CheckedContinuation<String, Error>
        var timeoutTask: Task<Void, Never>?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func status() async -> Status {
        let supported = Self.isSupported
        guard supported else {
            return Status(isSupported: false, installedProfiles: [], readyProfiles: [])
        }
        let installed = await installedProfiles()
        let ready = Set(installed.filter {
            defaults.integer(forKey: Self.readinessKey(for: $0)) == Self.readinessRevision
        })
        return Status(isSupported: true, installedProfiles: installed, readyProfiles: ready)
    }

    /// Opens the signed shortcut in Shortcuts. Apple intentionally requires the
    /// user to review and add it; SwiftBot never edits the user's library.
    func openInstaller(for profile: Profile) async throws {
        guard Self.isSupported else { throw BridgeError.unsupported }
        guard let url = Self.bundledShortcutURL(for: profile) else {
            throw BridgeError.bundledShortcutMissing(profile)
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else { throw BridgeError.launchFailed("Shortcuts did not open the installer.") }
    }

    /// Runs a small Cloud-model request. The first run is where macOS can ask
    /// the user to allow model access; a successful response marks this bridge
    /// ready for later headless runs.
    @discardableResult
    func testAndAuthorize(profile: Profile) async throws -> String {
        let prompt = "SwiftBot Bridge Test 1.0 confirms the \(profile.title) workflow can run unattended."
        _ = try await generate(prompt: prompt, profile: profile, timeout: 90)
        defaults.set(Self.readinessRevision, forKey: Self.readinessKey(for: profile))
        return "\(profile.title) is ready."
    }

    func generate(
        prompt: String,
        profile: Profile,
        timeout: TimeInterval = 120
    ) async throws -> String {
        guard Self.isSupported else { throw BridgeError.unsupported }
        guard await installedProfiles().contains(profile) else {
            throw BridgeError.shortcutNotInstalled(profile)
        }
        guard pendingRequest == nil else { throw BridgeError.requestInProgress }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BridgeError.emptyResponse }
        let boundedPrompt = String(trimmed.prefix(Self.maximumPromptCharacters))
        let requestID = UUID().uuidString
        guard let runURL = Self.runURL(prompt: boundedPrompt, requestID: requestID, profile: profile) else {
            throw BridgeError.launchFailed("Could not construct the Shortcuts request URL.")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingRequest = PendingRequest(
                    id: requestID,
                    profile: profile,
                    continuation: continuation,
                    timeoutTask: nil
                )
                pendingRequest?.timeoutTask = Task { [weak self] in
                    let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    guard !Task.isCancelled else { return }
                    await self?.finish(requestID: requestID, result: .failure(BridgeError.timedOut))
                }

                Task { [weak self] in
                    let opened = await MainActor.run { NSWorkspace.shared.open(runURL) }
                    guard !opened else { return }
                    await self?.finish(
                        requestID: requestID,
                        result: .failure(BridgeError.launchFailed("Shortcuts did not accept the request."))
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.finish(requestID: requestID, result: .failure(BridgeError.cancelled))
            }
        }
    }

    /// Receives the result appended by Shortcuts to SwiftBot's x-callback URL.
    /// Unknown or stale request IDs are ignored so external URLs cannot satisfy
    /// a different generation request.
    func handleCallback(_ url: URL) {
        guard url.scheme == "swiftbot",
              url.host == "intelligence-bridge",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let requestID = components.queryItems?.first(where: { $0.name == "request" })?.value,
              pendingRequest?.id == requestID else { return }

        switch url.path {
        case "/success":
            let raw = components.queryItems?.first(where: { $0.name == "result" })?.value ?? ""
            let response = String(raw.prefix(Self.maximumResponseCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !response.isEmpty else {
                finish(requestID: requestID, result: .failure(BridgeError.emptyResponse))
                return
            }
            if response.hasPrefix(Self.errorPrefix) {
                let message = response
                    .dropFirst(Self.errorPrefix.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                finish(
                    requestID: requestID,
                    result: .failure(BridgeError.executionFailed(message))
                )
                return
            }
            if let profile = pendingRequest?.profile {
                defaults.set(Self.readinessRevision, forKey: Self.readinessKey(for: profile))
            }
            finish(requestID: requestID, result: .success(response))
        case "/error":
            let message = components.queryItems?
                .first(where: { $0.name == "errorMessage" })?.value ?? ""
            finish(requestID: requestID, result: .failure(BridgeError.executionFailed(message)))
        case "/cancel":
            finish(requestID: requestID, result: .failure(BridgeError.cancelled))
        default:
            break
        }
    }

    private func finish(requestID: String, result: Result<String, Error>) {
        guard let request = pendingRequest, request.id == requestID else { return }
        pendingRequest = nil
        request.timeoutTask?.cancel()
        request.continuation.resume(with: result)
    }

    private func installedProfiles() async -> Set<Profile> {
        guard let result = try? await Self.runCommand(arguments: ["list"], timeout: 10),
              !result.timedOut,
              result.terminationStatus == 0 else {
            return []
        }
        let names = Set(result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return Set(Profile.allCases.filter { names.contains($0.shortcutName) })
    }

    private nonisolated static var isSupported: Bool {
        if #available(macOS 27.0, *) { return true }
        return false
    }

    private nonisolated static func readinessKey(for profile: Profile) -> String {
        "swiftbot.intelligenceBridge.\(profile.rawValue).readinessRevision"
    }

    private nonisolated static func bundledShortcutURL(for profile: Profile) -> URL? {
        Bundle.main.url(
            forResource: profile.shortcutName,
            withExtension: "shortcut",
            subdirectory: "Shortcuts"
        )
    }

    private nonisolated static func runURL(
        prompt: String,
        requestID: String,
        profile: Profile
    ) -> URL? {
        func callbackURL(path: String) -> String? {
            var callback = URLComponents()
            callback.scheme = "swiftbot"
            callback.host = "intelligence-bridge"
            callback.path = path
            callback.queryItems = [URLQueryItem(name: "request", value: requestID)]
            return callback.url?.absoluteString
        }

        guard let success = callbackURL(path: "/success"),
              let error = callbackURL(path: "/error"),
              let cancel = callbackURL(path: "/cancel") else { return nil }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: profile.shortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: prompt),
            URLQueryItem(name: "x-success", value: success),
            URLQueryItem(name: "x-error", value: error),
            URLQueryItem(name: "x-cancel", value: cancel)
        ]
        return components.url
    }

    private nonisolated static func runCommand(
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let execution = ShortcutProcessExecution(arguments: arguments)
        do {
            try execution.start()
        } catch {
            throw BridgeError.launchFailed(error.localizedDescription)
        }

        let timeoutTask = Task.detached {
            let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            execution.terminateForTimeout()
        }
        let result = await execution.result()
        timeoutTask.cancel()
        return result
    }
}

/// `Process` predates Swift concurrency. This small locked wrapper guarantees a
/// continuation is resumed once and lets the timeout task terminate the child.
private final class ShortcutProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let outputPipe = Pipe()
    private let errorPipe = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ShortcutIntelligenceBridge.CommandResult, Never>?
    private var completedResult: ShortcutIntelligenceBridge.CommandResult?
    private var didTimeOut = false

    init(arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            self?.finish(status: process.terminationStatus)
        }
    }

    func start() throws {
        try process.run()
    }

    func result() async -> ShortcutIntelligenceBridge.CommandResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(returning: completedResult)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func terminateForTimeout() {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        didTimeOut = true
        lock.unlock()
        if process.isRunning {
            process.terminate()
        }
    }

    private func finish(status: Int32) {
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        let result = ShortcutIntelligenceBridge.CommandResult(
            terminationStatus: status,
            standardOutput: output,
            standardError: error,
            timedOut: didTimeOut
        )
        completedResult = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }
}
