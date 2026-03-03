import AppKit
import SwiftUI

// MARK: - Graphics Vendor Enum

enum GraphicsVendor: String, CaseIterable {
    case nvidia = "NVIDIA"
    case amd = "AMD"
    case intelArc = "Intel Arc"
    case steam = "Steam Game"
}

// MARK: - Main View

struct UpdateEngineView: View {
    @StateObject private var viewModel = UpdateEngineViewModel()
    @State private var showDebug = false
    @State private var selectedVendor: GraphicsVendor = .nvidia
    @State private var webhookURL: String = ""
    @State private var webhookStatus: String = ""
    @State private var isSendingWebhook = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Discord Webhook URL
                VStack(alignment: .leading, spacing: 6) {
                    Text("Discord Webhook URL")
                        .font(.headline)
                    TextField("https://discord.com/api/webhooks/...", text: $webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(.horizontal)
                
                Divider()
                    .padding(.horizontal)
                
                // Vendor Selector
                HStack {
                    Text("Graphics Vendor:")
                        .font(.headline)
                    
                    Picker("Vendor", selection: $selectedVendor) {
                        ForEach(GraphicsVendor.allCases, id: \.self) { vendor in
                            Text(vendor.rawValue).tag(vendor)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                .padding(.horizontal)
                
                // Fetch Section
                GroupBox(selectedVendor.rawValue) {
                    VStack(alignment: .leading, spacing: 10) {
                        // Steam AppID input when Steam is selected
                        if selectedVendor == .steam {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Steam AppID")
                                    .font(.subheadline)
                                TextField("e.g. 570 for Dota 2", text: $viewModel.steamAppID)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(maxWidth: 300)
                            }
                        }

                        HStack(spacing: 12) {
                            Button("Fetch Latest") {
                                Task {
                                    await viewModel.fetchDriver(for: selectedVendor)
                                }
                            }
                            .disabled(viewModel.isFetching)

                            if viewModel.isFetching {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Spacer()

                            Button("Copy Embed JSON") {
                                viewModel.copyEmbedJSON()
                            }
                            .disabled(viewModel.currentDriver.embedJSON.isEmpty)
                        }

                        // Discord Embed Preview
                        if !viewModel.currentDriver.embedJSON.isEmpty {
                            GroupBox("Discord Preview") {
                                DiscordEmbedPreview(embedJSON: viewModel.currentDriver.embedJSON)
                            }
                            .padding(.vertical, 4)
                            
                            // Send Test to Discord Button
                            VStack(alignment: .leading, spacing: 8) {
                                Button {
                                    Task {
                                        await sendTestToDiscord()
                                    }
                                } label: {
                                    HStack {
                                        if isSendingWebhook {
                                            ProgressView()
                                                .controlSize(.small)
                                                .padding(.trailing, 4)
                                        }
                                        Text("Send Test to Discord")
                                    }
                                }
                                .disabled(webhookURL.isEmpty || viewModel.currentDriver.embedJSON.isEmpty || isSendingWebhook)
                                
                                if !webhookStatus.isEmpty {
                                    Text(webhookStatus)
                                        .font(.caption)
                                        .foregroundStyle(webhookStatus.contains("successfully") ? .green : .red)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        TextEditor(text: .constant(viewModel.outputText))
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .padding(4)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3))
                            )

                        if !viewModel.statusMessage.isEmpty {
                            HStack(spacing: 6) {
                                if viewModel.currentDriver.isNewVersion {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(.green)
                                    Text(viewModel.statusMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else if !viewModel.currentDriver.cacheKey.isEmpty {
                                    Image(systemName: "checkmark.circle")
                                        .foregroundStyle(.secondary)
                                    Text(viewModel.statusMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text(viewModel.statusMessage)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }

                DisclosureGroup("Debug", isExpanded: $showDebug) {
                    TextEditor(text: .constant(viewModel.debugOutput))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 260)
                        .padding(4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.gray.opacity(0.3))
                        )
                }
            }
            .padding(16)
        }
    }
    
    // MARK: - Send Test to Discord
    
    private func sendTestToDiscord() async {
        // Reset status
        webhookStatus = ""
        isSendingWebhook = true
        
        defer {
            isSendingWebhook = false
        }
        
        // Validate webhook URL
        guard !webhookURL.isEmpty else {
            webhookStatus = "Error: Webhook URL is empty"
            return
        }
        
        guard let url = URL(string: webhookURL) else {
            webhookStatus = "Error: Invalid webhook URL format"
            return
        }
        
        // Validate embed JSON
        guard !viewModel.currentDriver.embedJSON.isEmpty else {
            webhookStatus = "Error: No embed JSON to send"
            return
        }
        
        // Check if version is new (optional warning)
        if !viewModel.currentDriver.isNewVersion && !viewModel.currentDriver.cacheKey.isEmpty {
            webhookStatus = "⚠️ Warning: No version change detected, sending anyway..."
        }
        
        // Prepare request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = viewModel.currentDriver.embedJSON.data(using: .utf8)
        
        // Send request
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                webhookStatus = "Error: Invalid server response"
                return
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                webhookStatus = "✓ Test sent successfully"
                
                // Save version to cache after successful send
                if !viewModel.currentDriver.cacheKey.isEmpty {
                    try? await viewModel.markVersionAsSent()
                }
            } else {
                webhookStatus = "Error: HTTP \(httpResponse.statusCode)"
            }
        } catch {
            webhookStatus = "Error: \(error.localizedDescription)"
        }
    }
}

// MARK: - View Model

@MainActor
final class UpdateEngineViewModel: ObservableObject {
    @Published private(set) var currentDriver = DriverSectionState()
    @Published private(set) var isFetching = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published var steamAppID: String = ""

    private let nvidiaService = NVIDIAService()
    private let amdService = AMDService()
    private let steamService = SteamService()
    private let updateChecker: UpdateChecker
    
    // Optional guild context for per-guild caching (SwiftBot integration)
    private let guildContext: String?
    
    init(updateChecker: UpdateChecker? = nil, guildContext: String? = nil) {
        // Use provided update checker or create default one
        if let checker = updateChecker {
            self.updateChecker = checker
        } else {
            // Default to in-memory store for testing
            // In production SwiftBot, this would be initialized with JSONVersionStore
            self.updateChecker = UpdateChecker(store: InMemoryVersionStore())
        }
        self.guildContext = guildContext
    }

    var outputText: String {
        """
        Version: \(currentDriver.version)
        Release Date: \(currentDriver.releaseDate)
        Release URL: \(currentDriver.releaseURL)
        Generated Discord Embed JSON:
        \(currentDriver.embedJSON)
        """
    }

    var debugOutput: String {
        currentDriver.rawDebug
    }

    func fetchDriver(for vendor: GraphicsVendor) async {
        isFetching = true
        errorMessage = nil
        statusMessage = "Fetching \(vendor.rawValue) driver data..."

        defer {
            isFetching = false
        }

        var updateSource: DriverUpdateSource

        do {
            switch vendor {
            case .nvidia:
                let driverInfo = try await nvidiaService.fetchLatestDriver()
                updateSource = .nvidia(driverInfo)
                updateState(with: driverInfo, vendor: vendor)

            case .amd:
                let driverInfo = try await amdService.fetchLatestDriver()
                updateSource = .amd(driverInfo)
                updateState(with: driverInfo, vendor: vendor)

            case .intelArc:
                let driverInfo = createMockIntelArcDriver()
                updateSource = .intel(driverInfo)
                updateState(with: driverInfo, vendor: vendor)

            case .steam:
                let newsInfo = try await steamService.fetchLatestNews(for: steamAppID)
                updateState(with: newsInfo)
                // Wrap Steam as UpdateSource-compatible using vendor/channel semantics
                let baseKey = CacheKeyBuilder.build(vendor: "steam", channel: steamAppID)
                let steamWrapper = DriverUpdateSource(
                    vendor: "Steam",
                    channel: steamAppID,
                    version: newsInfo.newsItem.dateFormatted,
                    releaseNotes: ReleaseNotes(
                        title: newsInfo.newsItem.title,
                        author: "Steam",
                        url: newsInfo.newsItem.url,
                        version: newsInfo.newsItem.dateFormatted,
                        date: newsInfo.newsItem.dateFormatted,
                        sections: [ReleaseSection(title: "Patch Notes", bullets: [Bullet(text: newsInfo.newsItem.title)])],
                        thumbnailURL: "",
                        color: 0x1B2838
                    ),
                    embedJSON: newsInfo.embedJSON,
                    rawDebug: newsInfo.rawDebug
                )
                updateSource = steamWrapper
            }

            // Build full cache key (with optional guild context)
            let fullCacheKey: String
            if let guildID = guildContext {
                fullCacheKey = CacheKeyBuilder.buildGuildScoped(
                    guildID: guildID,
                    baseKey: updateSource.cacheKey
                )
            } else {
                fullCacheKey = updateSource.cacheKey
            }
            
            // Check version change using full cache key
            let versionResult = updateChecker.check(
                version: updateSource.version,
                for: fullCacheKey
            )
            
            switch versionResult {
            case .firstCheck:
                statusMessage = "\(vendor.rawValue) v\(currentDriver.version) - First check (no cached version)"
            case .changed(let old, let new):
                statusMessage = "\(vendor.rawValue) version changed: \(old ?? "unknown") → \(new)"
            case .unchanged:
                statusMessage = "\(vendor.rawValue) v\(currentDriver.version) - No version change detected"
            }
            
            currentDriver.isNewVersion = versionResult.isNewVersion
            currentDriver.cacheKey = fullCacheKey
            
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }
    
    private func updateState(with result: NVIDIAService.DriverInfo, vendor: GraphicsVendor) {
        currentDriver = DriverSectionState(
            version: result.releaseNotes.version,
            releaseDate: result.releaseNotes.date,
            releaseURL: result.releaseNotes.url,
            description: result.releaseNotes.sections.map { $0.title }.joined(separator: ", "),
            embedJSON: result.embedJSON,
            rawDebug: result.rawDebug
        )
    }
    
    private func updateState(with result: AMDService.DriverInfo, vendor: GraphicsVendor) {
        currentDriver = DriverSectionState(
            version: result.releaseNotes.version,
            releaseDate: result.releaseNotes.date,
            releaseURL: result.releaseNotes.url,
            description: result.releaseNotes.sections.map { $0.title }.joined(separator: ", "),
            embedJSON: result.embedJSON,
            rawDebug: result.rawDebug
        )
    }
    
    private func updateState(with result: SteamService.NewsInfo) {
        currentDriver = DriverSectionState(
            version: result.newsItem.dateFormatted,
            releaseDate: result.newsItem.dateFormatted,
            releaseURL: result.newsItem.url,
            description: result.newsItem.title,
            embedJSON: result.embedJSON,
            rawDebug: result.rawDebug
        )
    }
    
    private func createMockIntelArcDriver() -> NVIDIAService.DriverInfo {
        // Mock Intel Arc driver for testing
        let formatter = EmbedFormatter()
        let releaseNotes = ReleaseNotes(
            title: "Intel Arc Graphics Driver 101.5445",
            author: "Intel Arc Graphics",
            url: "https://www.intel.com/content/www/us/en/support/products/graphics.html",
            version: "101.5445",
            date: "March 3, 2026",
            sections: [
                ReleaseSection(
                    title: "Highlights",
                    bullets: [
                        Bullet(text: "Support for latest DirectX 12 Ultimate features"),
                        Bullet(text: "Improved XeSS performance"),
                        Bullet(text: "Bug fixes and stability improvements")
                    ]
                )
            ],
            thumbnailURL: "https://cdn.patchbot.io/games/145/intel-gpu-drivers_sm.png",
            color: 0x0071C5 // Intel blue
        )
        
        let embedJSON = formatter.format(releaseNotes: releaseNotes)
        
        return NVIDIAService.DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: embedJSON,
            rawDebug: "Mock Intel Arc driver data (not fetched from real API)"
        )
    }

    func copyEmbedJSON() {
        copyToPasteboard(currentDriver.embedJSON)
        statusMessage = "Copied embed JSON."
    }
    
    func markVersionAsSent() async throws {
        guard !currentDriver.cacheKey.isEmpty, currentDriver.version != "—" else {
            return
        }
        
        try updateChecker.save(version: currentDriver.version, for: currentDriver.cacheKey)
    }

    private func copyToPasteboard(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct DriverSectionState {
    var version: String = "—"
    var releaseDate: String = "—"
    var releaseURL: String = "—"
    var description: String = ""
    var embedJSON: String = ""
    var rawDebug: String = ""
    var isNewVersion: Bool = false
    var cacheKey: String = ""
}
