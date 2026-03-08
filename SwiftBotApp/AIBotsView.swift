import SwiftUI

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel
    @State private var baselineSettings = AIBotsSettingsSnapshot()

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != baselineSettings
    }

    private var currentSettingsSnapshot: AIBotsSettingsSnapshot {
        AIBotsSettingsSnapshot(
            localAIDMReplyEnabled: app.settings.localAIDMReplyEnabled,
            useAIInGuildChannels: app.settings.behavior.useAIInGuildChannels,
            allowDMs: app.settings.behavior.allowDMs,
            preferredAIProvider: app.settings.preferredAIProvider,
            ollamaBaseURL: app.settings.ollamaBaseURL,
            ollamaModel: app.settings.localAIModel,
            ollamaEnabled: app.settings.ollamaEnabled,
            openAIEnabled: app.settings.openAIEnabled,
            openAIAPIKey: app.settings.openAIAPIKey,
            openAIModel: app.settings.openAIModel,
            openAIImageGenerationEnabled: app.settings.openAIImageGenerationEnabled,
            openAIImageModel: app.settings.openAIImageModel,
            openAIImageMonthlyLimitPerUser: app.settings.openAIImageMonthlyLimitPerUser,
            localAISystemPrompt: app.settings.localAISystemPrompt
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewSectionHeader(title: "AI Bots", symbol: "sparkles.rectangle.stack.fill")

                overviewCard
                MemoryOverviewView(viewModel: app.memoryViewModel)
                configurationCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges {
                StickySaveButton(label: "Save AI Settings", systemImage: "square.and.arrow.down.fill") {
                    app.saveSettings()
                    baselineSettings = currentSettingsSnapshot
                }
                .padding(.trailing, 22)
                .padding(.bottom, 18)
            }
        }
        .task {
            normalizePreferredProviderIfNeeded()
            await app.refreshAIStatus()
            syncProviderSelectionFromPreference()
        }
        .onChange(of: app.settings.preferredAIProvider) { _, _ in
            syncProviderSelectionFromPreference()
            Task { await app.refreshAIStatus() }
            if app.settings.preferredAIProvider == .ollama, app.settings.ollamaEnabled {
                app.detectOllamaModel()
            }
        }
        .onChange(of: app.settings.ollamaBaseURL) { _, _ in
            Task { await app.refreshAIStatus() }
        }
        .onChange(of: app.settings.openAIAPIKey) { _, _ in
            Task { await app.refreshAIStatus() }
        }
        .onChange(of: app.settings.openAIEnabled) { _, _ in
            normalizePreferredProviderIfNeeded()
            Task { await app.refreshAIStatus() }
        }
        .onChange(of: app.settings.ollamaEnabled) { _, _ in
            normalizePreferredProviderIfNeeded()
            Task { await app.refreshAIStatus() }
        }
        .onAppear {
            normalizePreferredProviderIfNeeded()
            baselineSettings = currentSettingsSnapshot
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            diagnosticsStyleSectionHeader(title: "AI Engines", symbol: "sparkles")

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    providerIcon(imageName: "AIAppleLogo", fallbackSystemImage: "apple.intelligence")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Apple Intelligence")
                            .font(.headline.weight(.semibold))
                        Text("System-native engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusStack(status: app.appleIntelligenceOnline ? .online : .offline, isPrimary: app.settings.preferredAIProvider == .apple)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Apple Intelligence Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    providerToggleRow(
                        "Enable Apple Intelligence",
                        isOn: Binding(
                            get: { true },
                            set: { _ in }
                        )
                    )
                    .disabled(true)

                    Text("Apple Intelligence uses on-device system capabilities and does not require API keys.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                .padding(.leading, 64)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    providerIcon(imageName: "AIOllamaLogo", fallbackSystemImage: "server.rack")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Ollama")
                            .font(.headline)
                        Text("Local AI engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusStack(status: ollamaStatus, isPrimary: app.settings.preferredAIProvider == .ollama)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Ollama Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    providerToggleRow("Enable Ollama", isOn: $app.settings.ollamaEnabled)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Ollama Host (localhost)", text: $app.settings.ollamaBaseURL)
                        TextField("Model", text: $app.settings.localAIModel)

                        HStack {
                            Spacer()
                            Button {
                                app.detectOllamaModel()
                            } label: {
                                Label("Auto Detect Model", systemImage: "wand.and.stars")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 12)
                    .opacity(app.settings.ollamaEnabled ? 1.0 : 0.5)
                    .disabled(!app.settings.ollamaEnabled)
                }
                .padding(.top, 6)
                .padding(.leading, 64)
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    providerIcon(imageName: "AIOpenAILogo", fallbackSystemImage: "brain.head.profile")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("OpenAI (ChatGPT)")
                            .font(.headline)
                        Text("Cloud AI engine")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusStack(status: openAIStatus, isPrimary: app.settings.preferredAIProvider == .openAI)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("OpenAI Settings")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    providerToggleRow("Enable OpenAI", isOn: $app.settings.openAIEnabled)

                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("OpenAI API Key", text: $app.settings.openAIAPIKey)
                        TextField("OpenAI Chat Model", text: $app.settings.openAIModel)
                        Toggle("Enable OpenAI Image Generation", isOn: $app.settings.openAIImageGenerationEnabled)
                        TextField("OpenAI Image Model", text: $app.settings.openAIImageModel)
                            .disabled(!app.settings.openAIImageGenerationEnabled)
                        TextField(
                            "Monthly Image Limit Per User",
                            text: Binding(
                                get: { String(app.settings.openAIImageMonthlyLimitPerUser) },
                                set: { raw in
                                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if let parsed = Int(trimmed) {
                                        app.settings.openAIImageMonthlyLimitPerUser = max(0, parsed)
                                    }
                                }
                            )
                        )
                        .disabled(!app.settings.openAIImageGenerationEnabled)
                    }
                    .padding(.leading, 12)
                    .opacity(app.settings.openAIEnabled ? 1.0 : 0.5)
                    .disabled(!app.settings.openAIEnabled)
                }
                .padding(.top, 6)
                .padding(.leading, 64)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            diagnosticsStyleSectionHeader(title: "Configuration", symbol: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 14) {
                diagnosticsStyleSectionHeader(title: "General", symbol: "switch.2")
                settingsToggleRow("Enable AI Replies", isOn: $app.settings.localAIDMReplyEnabled)
                settingsToggleRow("Use AI in Guild Text Channels", isOn: $app.settings.behavior.useAIInGuildChannels)
                settingsToggleRow("Allow Direct Messages", isOn: $app.settings.behavior.allowDMs)
                settingsPickerRow("Primary AI Engine", selection: preferredAIProviderBinding)
            }

            VStack(alignment: .leading, spacing: 8) {
                diagnosticsStyleSectionHeader(title: "System Prompt", symbol: "text.bubble")
                TextField("System Prompt", text: $app.settings.localAISystemPrompt)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    @ViewBuilder
    private func providerIcon(imageName: String, fallbackSystemImage: String) -> some View {
        AIIconContainer {
            if let image = NSImage(named: NSImage.Name(imageName)) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(9)
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(10)
            }
        }
    }

    private var ollamaStatus: AIEngineStatus {
        statusForEngine(isEnabled: app.settings.ollamaEnabled, isOnline: app.ollamaOnline)
    }

    private var openAIStatus: AIEngineStatus {
        statusForEngine(isEnabled: app.settings.openAIEnabled, isOnline: app.openAIOnline)
    }

    private var enabledPrimaryProviders: [AIProviderPreference] {
        var providers: [AIProviderPreference] = [.apple]
        if app.settings.ollamaEnabled {
            providers.append(.ollama)
        }
        if app.settings.openAIEnabled {
            providers.append(.openAI)
        }
        return providers
    }

    private var preferredAIProviderBinding: Binding<AIProviderPreference> {
        Binding(
            get: {
                let available = enabledPrimaryProviders
                if available.contains(app.settings.preferredAIProvider) {
                    return app.settings.preferredAIProvider
                }
                return available.first ?? .apple
            },
            set: { app.settings.preferredAIProvider = $0 }
        )
    }

    private func statusRow(status: AIEngineStatus) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
            Text(status.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusStack(status: AIEngineStatus, isPrimary: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            statusRow(status: status)
            Text(isPrimary ? "Primary" : "Fallback")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPrimary ? Color.accentColor : Color.white).opacity(0.14), in: Capsule())
                .foregroundStyle(isPrimary ? Color.accentColor : Color.secondary)
        }
    }

    private func statusForEngine(isEnabled: Bool, isOnline: Bool) -> AIEngineStatus {
        guard isEnabled else { return .inactive }
        return isOnline ? .online : .offline
    }

    private func normalizePreferredProviderIfNeeded() {
        let available = enabledPrimaryProviders
        guard !available.contains(app.settings.preferredAIProvider), let fallback = available.first else { return }
        app.settings.preferredAIProvider = fallback
        syncProviderSelectionFromPreference()
    }

    private func providerDisplayName(_ provider: AIProviderPreference) -> String {
        switch provider {
        case .apple:
            return "Apple Intelligence"
        case .ollama:
            return "Ollama"
        case .openAI:
            return "OpenAI"
        }
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func settingsPickerRow(_ title: String, selection: Binding<AIProviderPreference>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            Picker("", selection: selection) {
                ForEach(enabledPrimaryProviders) { provider in
                    Text(providerDisplayName(provider)).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private func providerToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.subheadline)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func syncProviderSelectionFromPreference() {
        let mapped: AIProvider
        switch app.settings.preferredAIProvider {
        case .apple:
            mapped = .appleIntelligence
        case .ollama:
            mapped = .ollama
        case .openAI:
            mapped = .openAI
        }
        if app.settings.localAIProvider != mapped {
            app.settings.localAIProvider = mapped
        }
    }

    @ViewBuilder
    private func diagnosticsStyleSectionHeader(title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline.weight(.semibold))
        }
    }
}

private struct AIBotsSettingsSnapshot: Equatable {
    var localAIDMReplyEnabled = false
    var useAIInGuildChannels = true
    var allowDMs = false
    var preferredAIProvider: AIProviderPreference = .apple
    var ollamaBaseURL = ""
    var ollamaModel = ""
    var ollamaEnabled = true
    var openAIEnabled = true
    var openAIAPIKey = ""
    var openAIModel = ""
    var openAIImageGenerationEnabled = true
    var openAIImageModel = ""
    var openAIImageMonthlyLimitPerUser = 5
    var localAISystemPrompt = ""
}

private enum AIEngineStatus {
    case online
    case offline
    case inactive

    var label: String {
        switch self {
        case .online:
            return "Online"
        case .offline:
            return "Offline"
        case .inactive:
            return "Inactive"
        }
    }

    var color: Color {
        switch self {
        case .online:
            return .green
        case .offline:
            return .red
        case .inactive:
            return .secondary
        }
    }
}

struct MemoryOverviewView: View {
    @ObservedObject var viewModel: MemoryViewModel
    @State private var showClearAllConfirm = false
    @State private var scopeToClear: MemoryScope? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Conversation Memory")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(viewModel.totalMessages) messages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button("Clear All") { showClearAllConfirm = true }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.summaries.isEmpty)
                    .alert("Clear All Memory?", isPresented: $showClearAllConfirm) {
                        Button("Clear All", role: .destructive) { viewModel.clearAll() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All conversation memory will be permanently deleted.")
                    }
            }

            if viewModel.summaries.isEmpty {
                Text("No channel memory yet. Messages will appear here as conversations are processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.summaries.prefix(10)) { summary in
                    HStack(spacing: 12) {
                        Text(viewModel.displayName(for: summary))
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(summary.messageCount)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Button("Clear") { scopeToClear = summary.scope }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
        .alert("Clear Memory?", isPresented: Binding(
            get: { scopeToClear != nil },
            set: { if !$0 { scopeToClear = nil } }
        )) {
            Button("Clear", role: .destructive) {
                if let scope = scopeToClear { viewModel.clear(scope: scope) }
                scopeToClear = nil
            }
            Button("Cancel", role: .cancel) { scopeToClear = nil }
        } message: {
            Text("Memory for this conversation will be permanently deleted.")
        }
    }
}

struct AIIconContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
            content
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}
