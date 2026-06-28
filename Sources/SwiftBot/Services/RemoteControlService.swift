import Foundation
import SwiftUI

@MainActor
final class RemoteControlService: ObservableObject {
    @Published var configuration = RemoteModeSettings()
    @Published private(set) var connectionState: RemoteConnectionState = .disconnected
    @Published private(set) var status: RemoteStatusPayload?
    @Published private(set) var rulesPayload: RemoteRulesPayload?
    @Published private(set) var eventsPayload: RemoteEventsPayload?
    @Published private(set) var settingsPayload: AdminWebConfigPayload?
    @Published private(set) var lastLatencyMs: Double?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isTestingConnection = false
    @Published var lastError: String?

    private var pollingTask: Task<Void, Never>?

    init(configuration: RemoteModeSettings = RemoteModeSettings()) {
        var normalized = configuration
        normalized.normalize()
        self.configuration = normalized
    }

    deinit {
        pollingTask?.cancel()
    }

    func updateConfiguration(_ configuration: RemoteModeSettings) {
        var normalized = configuration
        normalized.normalize()
        self.configuration = normalized
    }

    @discardableResult
    func testConnection() async -> Bool {
        guard configuration.isConfigured else {
            connectionState = .disconnected
            lastError = RemoteAPI.Error.missingConfiguration.localizedDescription
            return false
        }

        isTestingConnection = true
        connectionState = .connecting
        defer { isTestingConnection = false }

        do {
            let api = try RemoteAPI(configuration: configuration)
            let clock = ContinuousClock()
            let startedAt = clock.now
            let status: RemoteStatusPayload = try await api.get("/api/remote/status")
            let duration = startedAt.duration(to: clock.now)

            self.status = status
            self.lastLatencyMs = milliseconds(from: duration)
            self.connectionState = .connected
            self.lastError = nil
            return true
        } catch {
            connectionState = .failed
            lastError = error.localizedDescription
            return false
        }
    }

    func refreshAll() async {
        guard configuration.isConfigured else {
            connectionState = .disconnected
            lastError = RemoteAPI.Error.missingConfiguration.localizedDescription
            return
        }

        isRefreshing = true
        connectionState = .connecting
        defer { isRefreshing = false }

        do {
            let api = try RemoteAPI(configuration: configuration)
            let clock = ContinuousClock()
            let startedAt = clock.now
            let status: RemoteStatusPayload = try await api.get("/api/remote/status")
            let duration = startedAt.duration(to: clock.now)

            async let rules: RemoteRulesPayload = api.get("/api/remote/rules")
            async let events: RemoteEventsPayload = api.get("/api/remote/events")
            async let settings: AdminWebConfigPayload = api.get("/api/remote/settings")

            self.status = status
            self.rulesPayload = try await rules
            self.eventsPayload = try await events
            self.settingsPayload = try await settings
            self.lastLatencyMs = milliseconds(from: duration)
            self.connectionState = .connected
            self.lastError = nil
        } catch {
            connectionState = .failed
            lastError = error.localizedDescription
        }
    }

    func startMonitoring(intervalSeconds: Double = 8) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshAll()

            let sleepDuration = UInt64(max(intervalSeconds, 2) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepDuration)
                if Task.isCancelled { break }
                await self.refreshAll()
            }
        }
    }

    func stopMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @discardableResult
    func upsertRule(_ rule: Rule) async -> Bool {
        do {
            let api = try RemoteAPI(configuration: configuration)
            try await api.post("/api/remote/rules/update", body: RemoteRuleUpsertRequest(rule: rule))
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func updateSettings(_ patch: AdminWebConfigPatch) async -> Bool {
        do {
            let api = try RemoteAPI(configuration: configuration)
            try await api.post("/api/remote/settings/update", body: patch)
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    private func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        let seconds = Double(components.seconds)
        let attoseconds = Double(components.attoseconds)
        return max(0, seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
    }
}
