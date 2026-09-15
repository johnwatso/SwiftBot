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
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
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

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarItem.sidebarSections) { section in
                Section(section.title) {
                    ForEach(section.items.filter(isVisible)) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .badge(badgeCount(for: item))
                            // Neutral glyphs rather than the accent tint a
                            // sidebar applies by default, as SwiftBot has always
                            // drawn them.
                            .listItemTint(.fixed(.primary))
                            .tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Bars rather than plain insets: only a safe-area bar registers with
        // the scroll edge effect, so rows fade out beneath the header and the
        // service button instead of drawing sharply behind them.
        .safeAreaBar(edge: .top, spacing: 0) {
            DashboardSidebarHeader(
                avatarURL: app.botAvatarURL,
                statusText: app.primaryServiceStatusText,
                isOnline: app.primaryServiceIsOnline,
                clusterMode: sidebarModeLabel,
                clusterIcon: clusterIcon
            )
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            serviceControl
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
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

    @ViewBuilder
    private var serviceControl: some View {
        Group {
            if !isPrimaryServiceRunning {
                Button {
                    Task { await app.startBot() }
                } label: {
                    Label(startButtonTitle, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    Task { await app.stopBot() }
                } label: {
                    Label(stopButtonTitle, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .help(startStopHelpText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    /// Sidebar mode label that surfaces in-flight transitions (Promoting…,
    /// Demoting…, Isolated, Recovering) instead of the steady-state role
    /// during the transition window. Falls back to the snapshot's mode when
    /// runtime state is idle.
    private var sidebarModeLabel: String {
        let runtime = app.clusterSnapshot.runtimeState
        if runtime != .idle {
            return runtime.displayName
        }
        return app.clusterSnapshot.mode.rawValue
    }

    private var clusterIcon: String {
        switch app.settings.clusterMode {
        case .standalone: return "desktopcomputer"
        case .leader: return "point.3.connected.trianglepath.dotted"
        case .worker: return "cpu"
        case .standby: return "arrow.triangle.2.circlepath"
        }
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

/// The bot's identity card, centred above the navigation rows. It sits in the
/// list's top safe-area bar, so the system scroll edge effect fades rows
/// passing beneath it.
private struct DashboardSidebarHeader: View {
    let avatarURL: URL?
    let statusText: String
    let isOnline: Bool
    let clusterMode: String
    let clusterIcon: String

    var body: some View {
        VStack(spacing: 8) {
            SidebarAvatarView(avatarURL: avatarURL, isOnline: isOnline)

            VStack(spacing: 3) {
                Text("SwiftBot – Dev")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(statusText)
                    Text("•")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Image(systemName: clusterIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(clusterMode)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarAvatarView: View {
    let avatarURL: URL?
    let isOnline: Bool

    @Environment(\.colorScheme) private var colorScheme

    private let size: CGFloat = 56
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(isOnline ? Color.green : Color.secondary)
                .frame(width: 12, height: 12)
                .overlay(Circle().strokeBorder(.background.opacity(0.85), lineWidth: 2))
                .offset(x: 2, y: 2)
                .accessibilityHidden(true)
        }
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
                    .font(.system(size: 23, weight: .semibold))
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
