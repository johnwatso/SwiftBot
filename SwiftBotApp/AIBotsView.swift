import SwiftUI

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel
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

                    statusCard
                    MemoryOverviewView(viewModel: app.memoryViewModel)
                    repliesCard
                    systemPromptCard
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
            await app.refreshAIStatus()
        }
        .onAppear {
            baselineSettings = currentSettingsSnapshot
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text("AI")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(app.appleIntelligenceOnline ? .green : .gray)
                        .frame(width: 7, height: 7)
                    Text(app.appleIntelligenceOnline
                         ? "Apple Intelligence ready"
                         : "Apple Intelligence unavailable")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var statusCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "apple.intelligence")
                        .font(.title3)
                    Text("Apple Intelligence")
                        .font(.headline)
                    Spacer()
                    Text(app.appleIntelligenceOnline ? "Online" : "Offline")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(app.appleIntelligenceOnline ? .green : .secondary)
                }
                Text("All on-device reply, summary, and announcer generation runs through the system FoundationModels framework. Requires macOS 26+ on a supported Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private var repliesCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Reply to DMs", isOn: $app.settings.localAIDMReplyEnabled)
                Toggle("Reply when mentioned in server channels", isOn: $app.settings.behavior.useAIInGuildChannels)
                Toggle("Allow DMs from any user", isOn: $app.settings.behavior.allowDMs)
            }
            .padding(.vertical, 4)
        }
    }

    private var systemPromptCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("System Prompt")
                    .font(.headline)
                Text("Shapes the bot's tone for replies. Apple Intelligence uses this as the conversation instructions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $app.settings.localAISystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
            }
            .padding(.vertical, 4)
        }
    }
}

enum AIBotsDashboardSummary {
    @MainActor
    static func metrics(app: AppModel) -> [DashboardMetricDescriptor] {
        [
            primaryMetric(app: app, id: "aiBots"),
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
        DashboardMetricDescriptor(
            id: id,
            title: "AI",
            value: app.appleIntelligenceOnline ? "Online" : "Offline",
            subtitle: app.settings.localAIDMReplyEnabled ? "DM replies on" : "DM replies off",
            symbol: "apple.intelligence",
            detail: "Guild AI \(app.settings.behavior.useAIInGuildChannels ? "On" : "Off")",
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
            detail: "System-native AI",
            color: app.appleIntelligenceOnline ? .green : .secondary,
            appleIntelligenceGlowEnabled: true
        )
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
