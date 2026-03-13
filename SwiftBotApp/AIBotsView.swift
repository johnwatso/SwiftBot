import SwiftUI

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showAppleSettings = false
    @State private var showOllamaSettings = false
    @State private var showOpenAISettings = false
    @State private var baselineSettings = AppPreferencesSnapshot()

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != baselineSettings
    }

    private var currentSettingsSnapshot: AppPreferencesSnapshot {
        app.createPreferencesSnapshot()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewSectionHeader(title: "AI Bots", symbol: "sparkles.rectangle.stack.fill")
                if app.isFailoverManagedNode {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.orange)
                        Text("Read-only on Failover nodes. AI settings sync from Primary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 2)
                }

                overviewCard
                MemoryOverviewView(viewModel: app.memoryViewModel)
                configurationCard
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges && !app.isFailoverManagedNode {
                StickySaveButton(label: "Save AI Settings", systemImage: "square.and.arrow.down.fill") {
                    app.saveSettings()
                    withAnimation {
                        baselineSettings = currentSettingsSnapshot
                    }
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

            EngineSectionView(
                title: "Apple Intelligence",
                subtitle: "System-native engine",
                disclosureTitle: "Apple Intelligence Settings",
                status: app.appleIntelligenceOnline ? .online : .offline,
                isPrimary: app.settings.preferredAIProvider == .apple,
                isExpanded: $showAppleSettings,
                showsHeaderDivider: true,
                showsLiquidGlow: true,
                glowEnabled: true
            ) {
                providerIcon(imageName: "AIAppleLogo", fallbackSystemImage: "apple.intelligence")
            } settings: {
                VStack(alignment: .leading, spacing: 10) {
                    settingsToggleRow(
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
                .padding(.leading, 12)
            }

            Divider()

            EngineSectionView(
                title: "Ollama",
                subtitle: "Local AI engine",
                disclosureTitle: "Ollama Settings",
                status: ollamaStatus,
                isPrimary: app.settings.preferredAIProvider == .ollama,
                isExpanded: $showOllamaSettings
            ) {
                providerIcon(imageName: "AIOllamaLogo", fallbackSystemImage: "server.rack")
            } settings: {
                VStack(alignment: .leading, spacing: 10) {
                    settingsToggleRow("Enable Ollama", isOn: ollamaEnabledBinding)

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
            }

            Divider()

            EngineSectionView(
                title: "OpenAI (ChatGPT)",
                subtitle: "Cloud AI engine",
                disclosureTitle: "OpenAI Settings",
                status: openAIStatus,
                isPrimary: app.settings.preferredAIProvider == .openAI,
                isExpanded: $showOpenAISettings
            ) {
                providerIcon(imageName: "AIOpenAILogo", fallbackSystemImage: "brain.head.profile")
            } settings: {
                VStack(alignment: .leading, spacing: 10) {
                    settingsToggleRow("Enable OpenAI", isOn: openAIEnabledBinding)

                    VStack(alignment: .leading, spacing: 10) {
                        SecureField("OpenAI API Key", text: $app.settings.openAIAPIKey)
                        TextField("OpenAI Chat Model", text: $app.settings.openAIModel)
                        settingsToggleRow("Enable OpenAI Image Generation", isOn: openAIImageGenerationBinding)
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
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var ollamaEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.settings.ollamaEnabled },
            set: { newValue in
                guard newValue != app.settings.ollamaEnabled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.ollamaEnabled = newValue
                }
            }
        )
    }

    private var openAIEnabledBinding: Binding<Bool> {
        Binding(
            get: { app.settings.openAIEnabled },
            set: { newValue in
                guard newValue != app.settings.openAIEnabled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.openAIEnabled = newValue
                }
            }
        )
    }

    private var openAIImageGenerationBinding: Binding<Bool> {
        Binding(
            get: { app.settings.openAIImageGenerationEnabled },
            set: { newValue in
                guard newValue != app.settings.openAIImageGenerationEnabled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.openAIImageGenerationEnabled = newValue
                }
            }
        )
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

private struct EngineSectionView<Icon: View, Content: View>: View {
    let title: String
    let subtitle: String
    let disclosureTitle: String
    let status: AIEngineStatus
    let isPrimary: Bool
    @Binding var isExpanded: Bool
    var showsHeaderDivider = false
    var showsLiquidGlow = false
    var glowEnabled = false
    let icon: Icon
    let settingsContent: Content
    @State private var isHovering = false
    @State private var glowOpacity = 0.0

    init(
        title: String,
        subtitle: String,
        disclosureTitle: String,
        status: AIEngineStatus,
        isPrimary: Bool,
        isExpanded: Binding<Bool>,
        showsHeaderDivider: Bool = false,
        showsLiquidGlow: Bool = false,
        glowEnabled: Bool = false,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder settings: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.disclosureTitle = disclosureTitle
        self.status = status
        self.isPrimary = isPrimary
        self._isExpanded = isExpanded
        self.showsHeaderDivider = showsHeaderDivider
        self.showsLiquidGlow = showsLiquidGlow
        self.glowEnabled = glowEnabled
        self.icon = icon()
        self.settingsContent = settings()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                EngineStatusStackView(status: status, isPrimary: isPrimary)
            }

            if showsHeaderDivider {
                Divider()
            }

            DisclosureGroup(disclosureTitle, isExpanded: $isExpanded) {
                settingsContent
            }
            .padding(.leading, 52)
        }
        .overlay {
            if showsLiquidGlow {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(liquidGlowGradient)
                        .blur(radius: 35)
                        .opacity(glowOpacity)
                        .padding(-8)

                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(liquidGlowGradient, lineWidth: 1)
                        .opacity(glowOpacity * 0.55)
                }
                .blendMode(.screen)
                .compositingGroup()
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            updateGlowOpacity(animated: false)
        }
        .onHover { hovering in
            guard showsLiquidGlow else { return }
            isHovering = hovering
            updateGlowOpacity()
        }
        .onChange(of: glowEnabled) { _, _ in
            updateGlowOpacity()
        }
    }

    private var liquidGlowGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.blue.opacity(0.18),
                Color.purple.opacity(0.15),
                Color.orange.opacity(0.18)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func updateGlowOpacity(animated: Bool = true) {
        let targetOpacity: Double
        if showsLiquidGlow && glowEnabled {
            targetOpacity = isHovering ? 0.95 : 0.62
        } else {
            targetOpacity = 0
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.22)) {
                glowOpacity = targetOpacity
            }
        } else {
            glowOpacity = targetOpacity
        }
    }
}

private struct EngineStatusStackView: View {
    let status: AIEngineStatus
    let isPrimary: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Text(isPrimary ? "Primary" : "Fallback")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPrimary ? Color.accentColor : Color.white).opacity(0.14), in: Capsule())
                .foregroundStyle(isPrimary ? Color.accentColor : Color.secondary)
        }
    }
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
