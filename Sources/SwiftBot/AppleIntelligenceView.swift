import SwiftUI

struct AppleIntelligenceView: View {
    @EnvironmentObject var app: AppModel

    private var selectedPersonality: AppleIntelligencePersonality {
        AppleIntelligencePersonality.matching(prompt: app.settings.localAISystemPrompt)
    }

    private var replyScopeValue: String {
        if app.settings.localAIDMReplyEnabled && app.settings.behavior.useAIInGuildChannels {
            return app.settings.behavior.allowDMs ? "Mentions + DMs" : "Mentions + trusted DMs"
        }
        if app.settings.localAIDMReplyEnabled { return "DMs Enabled" }
        if app.settings.behavior.useAIInGuildChannels { return "Mentions Only" }
        return "Paused"
    }

    private var currentSettingsSnapshot: AppPreferencesSnapshot {
        app.createPreferencesSnapshot()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)

            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. Apple Intelligence settings sync from Primary.")
                    .padding(.horizontal, 16)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryCards
                    personalitySection
                    replyRulesSection
                    MemoryOverviewView(viewModel: app.memoryViewModel)
                    capabilitiesSection
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
            }
            .fadingEdges(top: 16, bottom: 20)
        }
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await app.refreshAIStatus()
        }
        .onChange(of: currentSettingsSnapshot) { _, _ in
            guard !app.isFailoverManagedNode else { return }
            app.saveSettings()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            ViewSectionHeader(title: "Apple Intelligence", symbol: "apple.intelligence")
            Label(app.appleIntelligenceOnline ? "Online" : "Offline",
                  systemImage: app.appleIntelligenceOnline ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(app.appleIntelligenceOnline ? .green : .secondary)
            if app.settings.localAIDMReplyEnabled || app.settings.behavior.useAIInGuildChannels {
                Label(replyScopeValue, systemImage: "bubble.left.and.text.bubble.right.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            Spacer()
        }
    }

    private var summaryCards: some View {
        LazyVGrid(columns: DashboardMetricGrid.columns, spacing: DashboardMetricGrid.spacing) {
            DashboardMetricCard(
                title: "Apple Intelligence",
                value: app.appleIntelligenceOnline ? "Online" : "Offline",
                subtitle: app.appleIntelligenceOnline ? "System model ready" : "Unavailable on this Mac",
                symbol: "apple.intelligence",
                color: app.appleIntelligenceOnline ? .green : .secondary,
                appleIntelligenceGlowEnabled: true
            )
            DashboardMetricCard(
                title: "Conversation Memory",
                value: "\(app.memoryViewModel.totalMessages)",
                subtitle: app.memoryViewModel.summaries.isEmpty
                    ? "No conversations yet"
                    : "\(app.memoryViewModel.summaries.count) conversations",
                symbol: "brain.head.profile",
                color: .indigo
            )
            DashboardMetricCard(
                title: "Reply Scope",
                value: replyScopeValue,
                subtitle: app.settings.behavior.allowDMs ? "Open direct messages" : "DMs limited by setting",
                symbol: "text.bubble.fill",
                color: app.settings.localAIDMReplyEnabled || app.settings.behavior.useAIInGuildChannels ? .blue : .secondary
            )
            DashboardMetricCard(
                title: "Personality",
                value: selectedPersonality.title,
                subtitle: selectedPersonality.summaryValue,
                symbol: selectedPersonality.symbol,
                color: selectedPersonality.tint
            )
        }
    }

    private var personalitySection: some View {
        AutomationsSection(title: "Personality", symbol: "person.crop.circle.badge.checkmark") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(AppleIntelligencePersonality.allCases) { personality in
                    personalityTile(personality)
                }
            }
        }
    }

    private func personalityTile(_ personality: AppleIntelligencePersonality) -> some View {
        let isSelected = selectedPersonality == personality
        return Button {
            app.settings.localAISystemPrompt = personality.prompt
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: personality.symbol)
                        .font(.title3.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(personality.tint)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(personality.tint.opacity(0.14)))
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }

                Text(personality.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(personality.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                Text(personality.preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
            }
            .padding(12)
            .frame(minHeight: 166, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? personality.tint.opacity(0.08) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(white: 1.0, opacity: 0.06), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? personality.tint.opacity(0.45) : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var replyRulesSection: some View {
        AutomationsSection(title: "Reply Rules", symbol: "line.3.horizontal.decrease.circle") {
            VStack(spacing: 6) {
                ruleRow(
                    title: "Reply when mentioned",
                    subtitle: "Answer direct mentions in server text channels.",
                    symbol: "at",
                    tint: .blue,
                    isEnabled: app.settings.behavior.useAIInGuildChannels,
                    binding: $app.settings.behavior.useAIInGuildChannels
                )
                ruleRow(
                    title: "Reply to DMs",
                    subtitle: "Use Apple Intelligence for direct message conversations.",
                    symbol: "envelope.fill",
                    tint: .teal,
                    isEnabled: app.settings.localAIDMReplyEnabled,
                    binding: $app.settings.localAIDMReplyEnabled
                )
                ruleRow(
                    title: "Allow DMs from anyone",
                    subtitle: "Accept direct messages beyond known server context.",
                    symbol: "person.2.wave.2.fill",
                    tint: .purple,
                    isEnabled: app.settings.behavior.allowDMs,
                    binding: $app.settings.behavior.allowDMs
                )
                protectedRuleRow(
                    title: "Ignore bot accounts",
                    subtitle: "Always skips bot-authored messages to avoid reply loops.",
                    symbol: "shield.lefthalf.filled",
                    tint: .green
                )
            }
        }
    }

    private var capabilitiesSection: some View {
        let repliesActive = app.settings.localAIDMReplyEnabled || app.settings.behavior.useAIInGuildChannels
        let summariesActive = app.settings.patchy.sourceTargets.contains { $0.isEnabled && $0.summarizeWithAppleIntelligence }
        let moderationActive = app.automationStore.rules.contains { $0.category == .moderation && $0.enabled }
        let threadActive = app.memoryViewModel.totalMessages > 0

        let repliesStatus: CapabilityStatus = repliesActive ? .active : (app.appleIntelligenceOnline ? .ready : .off)
        let summariesStatus: CapabilityStatus = summariesActive ? .active : (app.appleIntelligenceOnline ? .ready : .off)
        let moderationStatus: CapabilityStatus = moderationActive ? .active : (app.appleIntelligenceOnline ? .ready : .off)
        let threadStatus: CapabilityStatus = threadActive ? .active : (app.appleIntelligenceOnline ? .ready : .off)

        return AutomationsSection(title: "Capabilities", symbol: "square.grid.2x2") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 10)], spacing: 10) {
                capabilityCard(
                    title: "Replies",
                    description: "Answers DMs and mentions using the selected personality.",
                    symbol: "bubble.left.and.text.bubble.right.fill",
                    tint: .blue,
                    status: repliesStatus
                )
                capabilityCard(
                    title: "Summaries",
                    description: "Creates concise on-device summaries for long updates.",
                    symbol: "doc.text.magnifyingglass",
                    tint: .indigo,
                    status: summariesStatus
                )
                capabilityCard(
                    title: "Moderation Assist",
                    description: "Supports moderation rules that use generated context.",
                    symbol: "shield.checkered",
                    tint: .red,
                    status: moderationStatus
                )
                capabilityCard(
                    title: "Thread Catch-up",
                    description: "Uses remembered context to make replies less repetitive.",
                    symbol: "text.line.first.and.arrowtriangle.forward",
                    tint: .green,
                    status: threadStatus
                )
            }
        }
    }

    private func ruleRow(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        isEnabled: Bool,
        binding: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: binding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func protectedRuleRow(title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("Always On")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.green.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private enum CapabilityStatus {
        case active
        case ready
        case off

        var label: String {
            switch self {
            case .active: return "Active"
            case .ready: return "Ready"
            case .off: return "Off"
            }
        }

        var color: Color {
            switch self {
            case .active: return .green
            case .ready: return .blue
            case .off: return .secondary
            }
        }

        var symbol: String {
            switch self {
            case .active: return "checkmark.circle.fill"
            case .ready: return "circle.dashed"
            case .off: return "pause.circle.fill"
            }
        }
    }

    private func capabilityCard(
        title: String,
        description: String,
        symbol: String,
        tint: Color,
        status: CapabilityStatus
    ) -> some View {
        let isAvailable = status != .off
        let iconColor = isAvailable ? tint : .secondary
        let badgeColor = status.color

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
                .frame(width: 30, height: 30)
                .background(Circle().fill(iconColor.opacity(0.14)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .frame(minHeight: 104, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            Image(systemName: status.symbol)
                .font(.caption.weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(badgeColor)
                .padding(8)
                .accessibilityLabel(Text(status.label))
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(white: 1.0, opacity: 0.05), lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

enum AppleIntelligenceDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        [
            primaryMetric(app: app, id: "appleIntelligence"),
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
    static func primaryMetric(app: AppModel, id: String = "appleIntelligence") -> DashboardMetricDescriptor {
        DashboardMetricDescriptor(
            id: id,
            title: "Apple Intelligence",
            value: app.appleIntelligenceOnline ? "Online" : "Offline",
            subtitle: app.settings.localAIDMReplyEnabled ? "DM replies on" : "DM replies off",
            symbol: "apple.intelligence",
            detail: "Guild replies \(app.settings.behavior.useAIInGuildChannels ? "On" : "Off")",
            color: .purple,
            appleIntelligenceGlowEnabled: true
        )
    }

    @MainActor
    static func appleIntelligenceMetric(app: AppModel, id: String = "apple-intelligence") -> DashboardMetricDescriptor {
        DashboardMetricDescriptor(
            id: id,
            title: "Apple Intelligence",
            value: app.appleIntelligenceOnline ? "Online" : "Offline",
            subtitle: "Primary engine",
            symbol: "apple.intelligence",
            detail: "System-native",
            color: app.appleIntelligenceOnline ? .green : .secondary,
            appleIntelligenceGlowEnabled: true
        )
    }
}

enum AppleIntelligencePersonality: String, CaseIterable, Identifiable {
    case friendlyCasual
    case community
    case technicalSupport
    case professional

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friendlyCasual: return "Friendly Casual"
        case .community: return "Community"
        case .technicalSupport: return "Technical Support"
        case .professional: return "Professional"
        }
    }

    var summaryValue: String {
        switch self {
        case .friendlyCasual: return "Short and warm"
        case .community: return "Server-aware"
        case .technicalSupport: return "Structured help"
        case .professional: return "Clear and calm"
        }
    }

    var symbol: String {
        switch self {
        case .friendlyCasual: return "face.smiling.fill"
        case .community: return "person.3.fill"
        case .technicalSupport: return "lifepreserver.fill"
        case .professional: return "briefcase.fill"
        }
    }

    var tint: Color {
        switch self {
        case .friendlyCasual: return .green
        case .community: return .blue
        case .technicalSupport: return .indigo
        case .professional: return .teal
        }
    }

    var description: String {
        switch self {
        case .friendlyCasual:
            return "Short conversational replies for community servers."
        case .community:
            return "Warm replies that notice server context and recent conversation."
        case .technicalSupport:
            return "Structured and informative replies for support-focused channels."
        case .professional:
            return "Polished, concise responses for official or staff-led spaces."
        }
    }

    var preview: String {
        switch self {
        case .friendlyCasual:
            return "Yep, I can help with that. Try this first..."
        case .community:
            return "Looks like the group is deciding on a plan. Here is the short version."
        case .technicalSupport:
            return "First, check the token. Then confirm the channel permission."
        case .professional:
            return "The request is queued. I will report back when it completes."
        }
    }

    var prompt: String {
        switch self {
        case .friendlyCasual:
            return "You are a friendly, casual Discord bot. Keep replies short and conversational, " +
                "usually 1 to 3 sentences. Use contractions naturally. Do not restate what the user said. " +
                "Match the energy of the conversation without being chaotic."
        case .community:
            return "You are a helpful community Discord bot. Keep replies warm, concise, and aware of " +
                "the server conversation. Encourage useful next steps, avoid overexplaining, and make " +
                "the channel feel welcoming."
        case .technicalSupport:
            return "You are a technical support Discord bot. Give clear, structured answers with " +
                "practical steps. Be concise, ask for missing details only when needed, and prefer " +
                "accurate troubleshooting over casual chatter."
        case .professional:
            return "You are a professional Discord assistant. Keep replies calm, polished, concise, " +
                "and neutral. Use plain language, avoid slang, and focus on useful outcomes."
        }
    }

    static func matching(prompt: String) -> AppleIntelligencePersonality {
        if let exact = allCases.first(where: { $0.prompt == prompt }) {
            return exact
        }
        let lowercased = prompt.lowercased()
        if lowercased.contains("technical support") || lowercased.contains("troubleshooting") {
            return .technicalSupport
        }
        if lowercased.contains("professional") || lowercased.contains("polished") {
            return .professional
        }
        if lowercased.contains("announcement") || lowercased.contains("announcer") || lowercased.contains("spoken") {
            return .professional
        }
        if lowercased.contains("community") || lowercased.contains("welcoming") {
            return .community
        }
        return .friendlyCasual
    }
}

struct MemoryOverviewView: View {
    @ObservedObject var viewModel: MemoryViewModel
    @State private var showClearAllConfirm = false
    @State private var scopeToClear: MemoryScope?

    var body: some View {
        SwiftMeshSection(title: "Conversation Memory", symbol: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    memoryChip("\(viewModel.totalMessages) messages", symbol: "text.bubble.fill")
                    memoryChip("\(viewModel.summaries.count) conversations", symbol: "number")
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
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Memory is ready", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Recent channels and direct messages will appear here after Apple Intelligence replies.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                    )
                } else {
                    ForEach(viewModel.summaries.prefix(10)) { summary in
                        HStack(spacing: 12) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                               .font(.caption.weight(.semibold))
                               .symbolRenderingMode(.hierarchical)
                               .foregroundStyle(.indigo)
                               .frame(width: 18)
                            Text(viewModel.displayName(for: summary))
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            memoryChip("\(summary.messageCount)", symbol: "text.bubble")
                            Button("Clear") { scopeToClear = summary.scope }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
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

    private func memoryChip(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.04), in: Capsule())
    }
}
