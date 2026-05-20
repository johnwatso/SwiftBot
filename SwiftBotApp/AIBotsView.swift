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
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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

                metricTileRow
                overviewCard
                MemoryOverviewView(viewModel: app.memoryViewModel)
                configurationCard
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
            }
        }
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            // Only probe Ollama if it's enabled
            if app.settings.ollamaEnabled {
                app.detectOllamaModel()
            }
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI Bots")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(headerStatusColor)
                        .frame(width: 7, height: 7)
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            AIProviderBadge(provider: app.settings.preferredAIProvider)
        }
    }

    private var headerSubtitle: String {
        let enabledCount = enabledPrimaryProviders.count
        let onlineCount = [
            app.appleIntelligenceOnline,
            app.settings.ollamaEnabled && app.ollamaOnline,
            app.settings.openAIEnabled && app.openAIOnline
        ].filter { $0 }.count
        let providerName = providerDisplayName(preferredAIProviderBinding.wrappedValue)
        return "\(onlineCount)/\(enabledCount) engines online · Primary \(providerName)"
    }

    private var headerStatusColor: Color {
        switch statusForEngine(
            isEnabled: enabledPrimaryProviders.contains(app.settings.preferredAIProvider),
            isOnline: isPreferredProviderOnline
        ) {
        case .online:
            return .green
        case .offline:
            return .red
        case .inactive:
            return .secondary
        }
    }

    private var metricTileRow: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            ForEach(AIBotsDashboardSummary.metrics(app: app)) { metric in
                DashboardMetricCard(metric: metric)
            }
        }
    }

    private var overviewCard: some View {
        SwiftMeshSection(title: "AI Engines", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                EngineSectionView(
                    title: "Apple Intelligence",
                    subtitle: "System-native engine",
                    disclosureTitle: "Apple Intelligence Settings",
                    status: app.appleIntelligenceOnline ? .online : .offline,
                    isPrimary: app.settings.preferredAIProvider == .apple,
                    isExpanded: $showAppleSettings,
                    showsHeaderDivider: true,
                    showsLiquidGlow: false,
                    glowEnabled: false
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
                                        .background(Color.primary.opacity(0.035), in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
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
        }
    }

    private var configurationCard: some View {
        SwiftMeshSection(title: "Configuration", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                aiSubsectionHeader(title: "General", symbol: "switch.2")
                settingsToggleRow("Enable AI Replies", isOn: $app.settings.localAIDMReplyEnabled)
                settingsToggleRow("Use AI in Guild Text Channels", isOn: $app.settings.behavior.useAIInGuildChannels)
                settingsToggleRow("Allow Direct Messages", isOn: $app.settings.behavior.allowDMs)
                settingsPickerRow("Primary AI Engine", selection: preferredAIProviderBinding)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 8) {
                aiSubsectionHeader(title: "System Prompt", symbol: "text.bubble")
                TextField("System Prompt", text: $app.settings.localAISystemPrompt)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
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

    private var enabledOnlineEngineCount: Int {
        [
            app.appleIntelligenceOnline,
            app.settings.ollamaEnabled && app.ollamaOnline,
            app.settings.openAIEnabled && app.openAIOnline
        ].filter { $0 }.count
    }

    private var isPreferredProviderOnline: Bool {
        switch preferredAIProviderBinding.wrappedValue {
        case .apple:
            return app.appleIntelligenceOnline
        case .ollama:
            return app.ollamaOnline
        case .openAI:
            return app.openAIOnline
        }
    }

    private var preferredProviderSubtitle: String {
        let status = statusForEngine(
            isEnabled: enabledPrimaryProviders.contains(preferredAIProviderBinding.wrappedValue),
            isOnline: isPreferredProviderOnline
        )
        return status.label
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

    private func providerShortName(_ provider: AIProviderPreference) -> String {
        switch provider {
        case .apple:
            return "Apple"
        case .ollama:
            return "Ollama"
        case .openAI:
            return "OpenAI"
        }
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.caption)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func settingsPickerRow(_ title: String, selection: Binding<AIProviderPreference>) -> some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.caption)
            Spacer()
            Picker("", selection: selection) {
                ForEach(enabledPrimaryProviders) { provider in
                    Text(providerDisplayName(provider)).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
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
    private func aiSubsectionHeader(title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}

enum AIBotsDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        [
            primaryMetric(app: app, id: "aiBots"),
            DashboardMetricDescriptor(
                id: "ai-engines",
                title: "Engines",
                value: "\(enabledPrimaryProviders(app: app).count)",
                subtitle: "\(enabledOnlineEngineCount(app: app)) online",
                symbol: "cpu",
                color: .blue
            ),
            DashboardMetricDescriptor(
                id: "ai-replies",
                title: "Replies",
                value: app.settings.localAIDMReplyEnabled ? "On" : "Off",
                subtitle: app.settings.behavior.useAIInGuildChannels ? "DMs and guild channels" : "Direct messages only",
                symbol: "bubble.left.and.text.bubble.right.fill",
                color: app.settings.localAIDMReplyEnabled ? .green : .gray
            ),
            DashboardMetricDescriptor(
                id: "ai-memory",
                title: "Memory",
                value: "\(app.memoryViewModel.totalMessages)",
                subtitle: "\(app.memoryViewModel.summaries.count) conversations",
                symbol: "brain.head.profile",
                color: .indigo
            )
        ]
    }

    @MainActor
    static func primaryMetric(app: AppModel, id: String = "aiBots") -> DashboardMetricDescriptor {
        let provider = resolvedPreferredProvider(app: app)
        let isOnline = isProviderOnline(provider, app: app)
        let status = statusLabel(isEnabled: enabledPrimaryProviders(app: app).contains(provider), isOnline: isOnline)
        return DashboardMetricDescriptor(
            id: id,
            title: "AI Bots",
            value: providerShortName(provider),
            subtitle: status,
            symbol: "sparkles",
            detail: "Guild AI \(app.settings.behavior.useAIInGuildChannels ? "On" : "Off")",
            color: .purple,
            appleIntelligenceGlowEnabled: provider == .apple
        )
    }

    @MainActor
    static func appleIntelligenceMetric(app: AppModel, id: String = "apple-intelligence") -> DashboardMetricDescriptor {
        DashboardMetricDescriptor(
            id: id,
            title: "Apple Intelligence",
            value: app.appleIntelligenceOnline ? "Online" : "Offline",
            subtitle: app.settings.preferredAIProvider == .apple ? "Primary engine" : "Available engine",
            symbol: "sparkles",
            detail: "System-native AI",
            color: app.appleIntelligenceOnline ? .green : .secondary,
            appleIntelligenceGlowEnabled: true
        )
    }

    @MainActor
    private static func enabledOnlineEngineCount(app: AppModel) -> Int {
        [
            app.appleIntelligenceOnline,
            app.settings.ollamaEnabled && app.ollamaOnline,
            app.settings.openAIEnabled && app.openAIOnline
        ].filter { $0 }.count
    }

    @MainActor
    private static func enabledPrimaryProviders(app: AppModel) -> [AIProviderPreference] {
        var providers: [AIProviderPreference] = [.apple]
        if app.settings.ollamaEnabled {
            providers.append(.ollama)
        }
        if app.settings.openAIEnabled {
            providers.append(.openAI)
        }
        return providers
    }

    @MainActor
    private static func resolvedPreferredProvider(app: AppModel) -> AIProviderPreference {
        let available = enabledPrimaryProviders(app: app)
        if available.contains(app.settings.preferredAIProvider) {
            return app.settings.preferredAIProvider
        }
        return available.first ?? .apple
    }

    @MainActor
    private static func isProviderOnline(_ provider: AIProviderPreference, app: AppModel) -> Bool {
        switch provider {
        case .apple:
            return app.appleIntelligenceOnline
        case .ollama:
            return app.ollamaOnline
        case .openAI:
            return app.openAIOnline
        }
    }

    private static func statusLabel(isEnabled: Bool, isOnline: Bool) -> String {
        guard isEnabled else { return "Inactive" }
        return isOnline ? "Online" : "Offline"
    }

    private static func providerShortName(_ provider: AIProviderPreference) -> String {
        switch provider {
        case .apple:
            return "Apple"
        case .ollama:
            return "Ollama"
        case .openAI:
            return "OpenAI"
        }
    }
}

private struct AIProviderBadge: View {
    let provider: AIProviderPreference

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.4)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color))
    }

    private var label: String {
        switch provider {
        case .apple:
            return "Apple"
        case .ollama:
            return "Ollama"
        case .openAI:
            return "OpenAI"
        }
    }

    private var symbol: String {
        switch provider {
        case .apple:
            return "apple.intelligence"
        case .ollama:
            return "server.rack"
        case .openAI:
            return "brain.head.profile"
        }
    }

    private var color: Color {
        switch provider {
        case .apple:
            return .accentColor
        case .ollama:
            return .blue
        case .openAI:
            return .green
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
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(status == .inactive ? 0.015 : 0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
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
    @State private var scopeToClear: MemoryScope?

    var body: some View {
        SwiftMeshSection(title: "Conversation Memory", symbol: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("\(viewModel.totalMessages) messages")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
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
                    PlaceholderPanelLine(text: "No channel memory yet. Messages will appear here as conversations are processed.")
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
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                    }
                }
            }
        }
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
                .fill(Color.primary.opacity(0.035))
            content
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
