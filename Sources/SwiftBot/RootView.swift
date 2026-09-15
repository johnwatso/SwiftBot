import AppKit
import Charts
import SwiftUI

/// Unified root view that works with both local and remote providers.
/// The provider-based shell allows the same UI components to be used
/// regardless of whether the bot is running locally or remotely.
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview

    var body: some View {
        currentRootView
            .sheet(item: $app.pendingSwiftMeshJoin) { pending in
                SwiftMeshJoinConfirmationSheet(pending: pending)
                    .environmentObject(app)
            }
    }

    @ViewBuilder
    private var currentRootView: some View {
        if !app.isOnboardingComplete {
            OnboardingRootView()
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else if shouldShowRemoteDashboard {
            RemoteModeRootView()
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else if let provider = app.provider {
            UnifiedRootView(selection: $selection)
                .environmentObject(provider)
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else {
            fallbackView
        }
    }

    @ViewBuilder
    private var fallbackView: some View {
        ProgressView("Loading dashboard...")
            .frame(minWidth: 1200, minHeight: 760)
            .toggleStyle(.switch)
    }

    private var shouldShowRemoteDashboard: Bool {
        app.isRemoteLaunchMode || (app.canOpenRemoteDashboardFromLocalApp && app.viewMode == .remote)
    }
}

// MARK: - Unified Shell

/// Unified shell that uses BotDataProvider for both local and remote modes.
/// This view receives the provider via environment and renders the appropriate UI.
struct UnifiedRootView: View {
    @Binding var selection: SidebarItem
    @EnvironmentObject var provider: AnyBotDataProvider
    @EnvironmentObject var app: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Detail content runs up into the titlebar. With the sidebar showing, the
    /// traffic lights sit over the sidebar; once it collapses they (and the
    /// system's sidebar reveal button) would land on the page header, so the
    /// content drops below them.
    private static let collapsedSidebarTopInset: CGFloat = 36

    private var isSidebarCollapsed: Bool {
        columnVisibility == .detailOnly
    }

    var body: some View {
        // The system split view owns the sidebar's Liquid Glass material,
        // row metrics (which follow the user's Sidebar icon size setting),
        // selection highlight, keyboard navigation, and column resizing.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            DashboardSidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            detailView
                .padding(.top, isSidebarCollapsed ? Self.collapsedSidebarTopInset : 0)
                .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .top)
                .background(SwiftBotGlassBackground())
                .dashboardMetricGlowLayer()
        }
        // The window has no toolbar and the View menu omits the sidebar
        // commands, matching the remote dashboard's split view.
        .toolbar(removing: .sidebarToggle)
        .overlay(alignment: .topTrailing) {
            if app.isBetaBuild {
                BetaBadgeView()
                    .padding(.top, 14)
                    .padding(.trailing, 18)
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .overview:
            OverviewView(onOpenSwiftMesh: {
                if !shouldHideSwiftMesh {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = .swiftMesh
                    }
                }
            })
        case .patchy: PatchyView()
        case .welcomeFlow: WelcomeFlowView()
        case .automations: AutomationsView()
        case .moderation: ModerationView()
        case .commands: CommandsView()
        case .activity: ActivityLogView()
        case .wikiBridge: WikiBridgeView()
        case .appleIntelligence: AppleIntelligenceView()
        case .voice: VoiceView()
        case .recordings: RecordingsView()
        case .analytics: AnalyticsView()
        case .rewind: RewindView()
        case .swiftMesh:
            if shouldHideSwiftMesh {
                OverviewView(onOpenSwiftMesh: {})
            } else {
                SwiftMeshView()
            }
        case .sweep: SweepView()
        case .gameTracker: GameTrackerView()
        }
    }

    private var shouldHideSwiftMesh: Bool {
        app.settings.clusterMode == .standalone
    }
}

private struct BetaBadgeView: View {
    var body: some View {
        Text("BETA")
            .font(.caption2.weight(.heavy))
            .tracking(0.8)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.orange, Color.red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            )
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
            .accessibilityLabel("Beta build")
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem

    /// The user's Sidebar icon size setting, which the rows follow — but never
    /// below Medium: this is SwiftBot's primary navigation, not a dense source list.
    @Environment(\.sidebarRowSize) private var systemRowSize
    @FocusState private var isListFocused: Bool
    @State private var isConfirmingStop = false

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.sidebarSections) { section in
                if let title = section.title {
                    Section {
                        rows(for: section)
                    } header: {
                        // Readable group labels, with room above each group so
                        // spacing rather than dividers separates them.
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                            .padding(.bottom, 2)
                    }
                } else {
                    Section { rows(for: section) }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, systemRowSize == .small ? .medium : systemRowSize)
        // Taking focus on appear opens on the accent selection highlight
        // (`defaultFocus` leaves a sidebar list unfocused). Once focus moves
        // into a page the system dims the highlight, and the selected row's
        // accent glyph keeps it the anchor.
        .focused($isListFocused)
        .task { isListFocused = true }
        // A bar rather than a plain inset: only a safe-area bar registers with
        // the scroll edge effect, so rows fade out beneath the header instead
        // of drawing sharply behind it.
        .safeAreaBar(edge: .top, spacing: 0) {
            DashboardSidebarHeader(
                name: app.resolvedBotUsername,
                avatarURL: app.botAvatarURL,
                statusText: presence.text,
                statusTint: presence.tint,
                startTitle: isPrimaryServiceRunning ? nil : startButtonTitle,
                startHelp: startStopHelpText,
                onStart: { Task { await app.startBot() } },
                actions: { botActions }
            )
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .confirmationDialog("Stop \(app.resolvedBotUsername)?", isPresented: $isConfirmingStop) {
            Button(stopButtonTitle, role: .destructive) {
                Task { await app.stopBot() }
            }
        } message: {
            Text(stopConfirmationMessage)
        }
        .onAppear {
            if shouldHideSwiftMesh && selection == .swiftMesh {
                selection = .overview
            }
        }
        .onChange(of: app.settings.clusterMode) { _, newValue in
            if newValue == .standalone && selection == .swiftMesh {
                selection = .overview
            }
        }
    }

    private func rows(for section: SidebarItemGroup) -> some View {
        ForEach(section.items.filter(isVisible)) { item in
            let isSelected = selection == item
            Label(item.rawValue, systemImage: item.icon)
                .symbolVariant(isSelected ? .fill : .none)
                .badge(badgeCount(for: item))
                // Monochrome glyphs sit behind their titles; the selected
                // row's glyph takes the accent.
                .listItemTint(isSelected ? .fixed(.accentColor) : .monochrome)
                .tag(item)
        }
    }

    /// Shared by the header's menu and its context menu.
    @ViewBuilder
    private var botActions: some View {
        Section(sidebarModeLabel) {
            if isPrimaryServiceRunning {
                Button("\(stopButtonTitle)…", systemImage: "stop.fill", role: .destructive) {
                    isConfirmingStop = true
                }
            } else {
                Button(startButtonTitle, systemImage: "play.fill") {
                    Task { await app.startBot() }
                }
            }
        }

        Section {
            SettingsLink {
                Label("Settings…", systemImage: "gear")
            }
        }
    }

    /// SwiftMesh is the one row that hides itself — a standalone bot has no
    /// cluster to show.
    private func isVisible(_ item: SidebarItem) -> Bool {
        item != .swiftMesh || !shouldHideSwiftMesh
    }

    /// A zero badge is not drawn.
    private func badgeCount(for item: SidebarItem) -> Int {
        item == .recordings ? app.recentMediaCount24h : 0
    }

    private var isPrimaryServiceRunning: Bool {
        app.settings.clusterMode == .worker ? app.isWorkerServiceRunning : app.status != .stopped
    }

    /// A bot mid-connection reads as connecting rather than flipping straight
    /// from Offline to Online.
    private var presence: (text: String, tint: Color) {
        if app.runtimeClusterMode != .worker {
            switch app.status {
            case .connecting: return ("Connecting…", .orange)
            case .reconnecting: return ("Reconnecting…", .orange)
            case .running, .stopped: break
            }
        }
        return (app.primaryServiceStatusText, app.primaryServiceIsOnline ? .green : .secondary)
    }

    /// Node role for the actions menu, surfacing in-flight transitions
    /// (Promoting…, Demoting…, Isolated, Recovering) instead of the
    /// steady-state role during the transition window.
    private var sidebarModeLabel: String {
        let runtime = app.clusterSnapshot.runtimeState
        if runtime != .idle {
            return runtime.displayName
        }
        return app.clusterSnapshot.mode.rawValue
    }

    private var shouldHideSwiftMesh: Bool {
        app.settings.clusterMode == .standalone
    }

    private var startButtonTitle: String {
        switch app.settings.clusterMode {
        case .worker: return "Start Worker"
        case .standby: return "Start Failover Watch"
        default: return "Start Bot"
        }
    }

    private var stopButtonTitle: String {
        switch app.settings.clusterMode {
        case .worker: return "Stop Worker"
        case .standby: return "Stop Failover Watch"
        default: return "Stop Bot"
        }
    }

    private var stopConfirmationMessage: String {
        switch app.settings.clusterMode {
        case .standby:
            return "This Mac stops watching the Primary and won’t take over if the Primary goes down."
        case .worker:
            return "This Mac leaves the cluster and stops running jobs offloaded by the Primary."
        default:
            return "The bot disconnects from Discord and leaves any voice channels. Commands, automations, and monitors stay paused until you start it again."
        }
    }

    private var startStopHelpText: String {
        switch app.settings.clusterMode {
        case .standby:
            return "Connects to Discord in passive mode and watches the Primary. The bot does not send messages until this node is promoted to Primary."
        case .worker:
            return "Joins the cluster as a Worker. Runs offloaded jobs dispatched by the Primary."
        default:
            return "Starts the SwiftBot Discord gateway connection."
        }
    }
}

/// The bot's identity: avatar, name and presence, with runtime actions behind a
/// menu and on right-click. Detailed runtime state belongs to the Overview.
private struct DashboardSidebarHeader<Actions: View>: View {
    let name: String
    let avatarURL: URL?
    let statusText: String
    let statusTint: Color
    /// Set while the bot is stopped. Starting is the one thing a stopped bot
    /// needs, so it sits beside the status as well as in the menu.
    let startTitle: String?
    let startHelp: String
    let onStart: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            SidebarAvatarView(avatarURL: avatarURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(statusTint)
                            .frame(width: 7, height: 7)
                        Text(statusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)

                    if let startTitle {
                        Button("Start", action: onStart)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .help(startHelp)
                            .accessibilityLabel(startTitle)
                    }
                }
            }

            Spacer(minLength: 0)

            Menu {
                actions()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Bot Actions")
            .accessibilityLabel("Bot Actions")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
        .contextMenu { actions() }
    }
}

private struct SidebarAvatarView: View {
    let avatarURL: URL?

    @Environment(\.colorScheme) private var colorScheme

    private let size: CGFloat = 44
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty:
                        placeholder(progress: true)
                    case .failure:
                        placeholder()
                    @unknown default:
                        placeholder()
                    }
                }
            } else {
                placeholder()
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.30), lineWidth: 1)
        )
        .accessibilityHidden(true)
    }

    private func placeholder(progress: Bool = false) -> some View {
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [.blue.opacity(0.85), .indigo.opacity(0.85)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )

            if progress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - SwiftMesh Join Confirmation

struct SwiftMeshJoinConfirmationSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let pending: PendingSwiftMeshJoin

    @State private var isApplying = false
    @State private var feedback: String?
    @State private var feedbackIsError = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Join SwiftMesh Cluster?")
                    .font(.title3.weight(.semibold))
            }

            Text("This Mac will be configured as a **Fail Over (Standby)** node and will connect to the Primary using the credentials below. Existing cluster settings will be replaced.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    detailRow("Primary host(s)", pending.bundle.leaderAddresses.joined(separator: ", "))
                    detailRow("Port", String(pending.bundle.leaderPort))
                    detailRow("Shared secret", String(repeating: "•", count: 24))
                }
                .padding(.vertical, 4)
            }

            if let feedback {
                Text(feedback)
                    .font(.callout)
                    .foregroundStyle(feedbackIsError ? .red : .green)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    app.pendingSwiftMeshJoin = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isApplying ? "Joining…" : "Join Cluster") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func apply() {
        isApplying = true
        feedback = nil
        let result = app.applySwiftMeshJoinCode(pending.rawCode)
        if !result.ok {
            feedback = result.message
            feedbackIsError = true
            isApplying = false
            return
        }
        Task {
            let ok = await app.testWorkerJoinCodeConnection(
                addresses: pending.bundle.leaderAddresses,
                port: pending.bundle.leaderPort
            )
            await MainActor.run {
                isApplying = false
                feedback = ok ? "Joined successfully." : "Settings saved, but connection test failed. Review SwiftMesh preferences."
                feedbackIsError = !ok
                if ok {
                    app.pendingSwiftMeshJoin = nil
                    dismiss()
                }
            }
        }
    }
}
