import SwiftUI
import UpdateEngine

private enum TesterSource: String, CaseIterable, Identifiable {
    case nvidia = "NVIDIA"
    case amd = "AMD"
    case intel = "Intel Arc"
    case steam = "Steam"

    var id: String { rawValue }
}

@MainActor
private final class UpdateEngineUITesterViewModel: ObservableObject {
    @Published var source: TesterSource = .nvidia
    @Published var steamAppID: String = "570"
    @Published var webhookURL: String = ""
    @Published var saveAfterFetch: Bool = true

    @Published private(set) var isFetching: Bool = false
    @Published private(set) var isSendingWebhook: Bool = false
    @Published private(set) var status: String = "Ready"
    @Published private(set) var sourceKey: String = ""
    @Published private(set) var cacheKey: String = ""
    @Published private(set) var identifier: String = ""
    @Published private(set) var version: String = ""
    @Published private(set) var embedJSON: String = ""
    @Published private(set) var debugOutput: String = ""

    private let checker: UpdateChecker?

    init() {
        do {
            let store = try JSONVersionStore(fileURL: Self.defaultStoreURL())
            self.checker = UpdateChecker(store: store)
            self.status = "Ready"
        } catch {
            self.checker = nil
            self.status = "Failed to initialize store: \(error.localizedDescription)"
        }
    }

    func fetchLatest() {
        guard let checker else {
            status = "Checker unavailable."
            return
        }

        if source == .steam, steamAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = "Steam App ID is required for Steam source."
            return
        }

        isFetching = true
        status = "Fetching \(source.rawValue)..."

        Task {
            defer { isFetching = false }

            do {
                let updateSource = makeSource()
                let item = try await updateSource.fetchLatest()

                let effectiveCacheKey: String
                if let webhookScopeID {
                    effectiveCacheKey = CacheKeyBuilder.buildScoped(
                        scopeType: "webhook",
                        scopeID: webhookScopeID,
                        baseKey: item.sourceKey
                    )
                } else {
                    effectiveCacheKey = item.sourceKey
                }

                let result = try await checker.check(item: item, for: effectiveCacheKey)

                sourceKey = item.sourceKey
                cacheKey = effectiveCacheKey
                identifier = item.identifier
                version = item.version

                if let driver = item as? DriverUpdateItem {
                    embedJSON = driver.embedJSON
                    debugOutput = driver.rawDebug
                } else if let steam = item as? SteamUpdateItem {
                    embedJSON = steam.embedJSON
                    debugOutput = steam.rawDebug
                } else {
                    embedJSON = ""
                    debugOutput = ""
                }

                var statusParts: [String] = [
                    "\(source.rawValue): \(statusLabel(result))"
                ]

                if saveAfterFetch {
                    try await checker.save(item: item, for: effectiveCacheKey)
                    statusParts.append("saved")
                }

                status = statusParts.joined(separator: " | ")
            } catch {
                status = "Fetch failed: \(error.localizedDescription)"
            }
        }
    }

    func sendTestToWebhook() async {
        guard let url = normalizedWebhookURL else {
            status = "Enter a valid webhook URL."
            return
        }

        guard !embedJSON.isEmpty else {
            status = "Fetch an update first (embed JSON is empty)."
            return
        }

        isSendingWebhook = true
        defer { isSendingWebhook = false }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = embedJSON.data(using: .utf8)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = "Webhook send failed: invalid response."
                return
            }

            if (200...299).contains(http.statusCode) {
                status = "Webhook send successful (HTTP \(http.statusCode))."
            } else {
                status = "Webhook send failed (HTTP \(http.statusCode))."
            }
        } catch {
            status = "Webhook send failed: \(error.localizedDescription)"
        }
    }

    var canSendWebhook: Bool {
        normalizedWebhookURL != nil && !embedJSON.isEmpty
    }

    private var normalizedWebhookURL: URL? {
        let trimmed = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            return nil
        }
        return url
    }

    private var webhookScopeID: String? {
        guard let url = normalizedWebhookURL else {
            return nil
        }

        let components = url.path.split(separator: "/").map(String.init)
        if let index = components.firstIndex(of: "webhooks"), components.indices.contains(index + 1) {
            return components[index + 1]
        }

        return url.absoluteString
    }

    private func makeSource() -> any UpdateSource {
        switch source {
        case .nvidia:
            return NVIDIAUpdateSource()
        case .amd:
            return AMDUpdateSource()
        case .intel:
            return IntelUpdateSource()
        case .steam:
            return SteamNewsUpdateSource(appID: steamAppID)
        }
    }

    private func statusLabel(_ result: UpdateChangeResult) -> String {
        switch result {
        case .firstSeen(let id):
            return "firstSeen (\(id))"
        case .changed(let old, let new):
            return "changed (\(old) -> \(new))"
        case .unchanged(let id):
            return "unchanged (\(id))"
        }
    }

    private static func defaultStoreURL() -> URL {
        if let raw = ProcessInfo.processInfo.environment["UPDATE_ENGINE_STORE_PATH"], !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swiftbot")
            .appendingPathComponent("update-engine")
            .appendingPathComponent("identifiers.json")
    }
}

private struct UpdateEngineUITesterView: View {
    @StateObject private var viewModel = UpdateEngineUITesterViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("UpdateEngine UI Tester")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Source", selection: $viewModel.source) {
                    ForEach(TesterSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                if viewModel.source == .steam {
                    TextField("Steam App ID", text: $viewModel.steamAppID)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }

                TextField("Webhook URL (optional)", text: $viewModel.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)

                Toggle("Save", isOn: $viewModel.saveAfterFetch)
                    .toggleStyle(.switch)

                Button {
                    viewModel.fetchLatest()
                } label: {
                    if viewModel.isFetching {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Fetching...")
                        }
                    } else {
                        Text("Fetch Latest")
                    }
                }
                .disabled(viewModel.isFetching)

                Button {
                    Task {
                        await viewModel.sendTestToWebhook()
                    }
                } label: {
                    if viewModel.isSendingWebhook {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Sending...")
                        }
                    } else {
                        Text("Send Test")
                    }
                }
                .disabled(viewModel.isSendingWebhook || viewModel.isFetching || !viewModel.canSendWebhook)
            }

            Text(viewModel.status)
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox("Result") {
                VStack(alignment: .leading, spacing: 6) {
                    row("Source Key", viewModel.sourceKey)
                    row("Cache Key", viewModel.cacheKey)
                    row("Identifier", viewModel.identifier)
                    row("Version", viewModel.version)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Embed JSON") {
                TextEditor(text: .constant(viewModel.embedJSON))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 180)
            }

            GroupBox("Debug") {
                TextEditor(text: .constant(viewModel.debugOutput))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
            }
        }
        .padding(16)
        .frame(minWidth: 920, minHeight: 760)
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label + ":")
                .fontWeight(.medium)
                .frame(width: 90, alignment: .leading)
            Text(value.isEmpty ? "-" : value)
                .textSelection(.enabled)
                .font(.system(.body, design: .monospaced))
        }
    }
}

@main
struct UpdateEngineUITesterApp: App {
    var body: some Scene {
        WindowGroup {
            UpdateEngineUITesterView()
        }
    }
}
