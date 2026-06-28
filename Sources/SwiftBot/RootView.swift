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

    var body: some View {
        ZStack(alignment: .leading) {
            detailView
                .padding(.leading, 292)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            DashboardSidebar(selection: $selection)
                .frame(width: 280)
                .zIndex(1)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SwiftBotGlassBackground())
        .dashboardMetricGlowLayer()
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
        case .swiftMesh:
            if shouldHideSwiftMesh {
                OverviewView(onOpenSwiftMesh: {})
            } else {
                SwiftMeshView()
            }
        case .sweep: SweepView()
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

private struct SidebarHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DashboardSidebar: View {
    @EnvironmentObject var app: AppModel
    @Binding var selection: SidebarItem
    @Namespace private var selectionHighlightNamespace
    @State private var headerHeight: CGFloat = 120

    var body: some View {
        ZStack {
            SwiftBotSidebarMaterialBackground()

            VStack(spacing: 0) {
                ZStack(alignment: .top) {
                List {
                    Section("Dashboard") {
                        sidebarListRow(.overview)
                    }

                    Section("Workflows") {
                        sidebarListRow(.commands)
                        sidebarListRow(.welcomeFlow)
                        sidebarListRow(.automations)
                        sidebarListRow(.moderation)
                    }

                    Section("Services") {
                        sidebarListRow(.patchy)
                        sidebarListRow(.sweep)
                        sidebarListRow(.wikiBridge)
                        sidebarListRow(.voice)
                        sidebarListRow(.recordings, count: app.recentMediaCount24h)
                    }

                    Section("System") {
                        sidebarListRow(.appleIntelligence)
                        sidebarListRow(.analytics)
                        sidebarListRow(.activity)
                        if !shouldHideSwiftMesh {
                            sidebarListRow(.swiftMesh)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .padding(.top, headerHeight)
                .fadingEdges(top: 0, bottom: 20)

                    DashboardSidebarHeader(
                        avatarURL: app.botAvatarURL,
                        statusText: app.primaryServiceStatusText,
                        isOnline: app.primaryServiceIsOnline,
                        clusterMode: sidebarModeLabel,
                        clusterIcon: clusterIcon
                    )
                    .padding(.top, 44)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .top) {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.7),
                                        .init(color: .clear, location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .allowsHitTesting(false)
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: SidebarHeaderHeightKey.self, value: proxy.size.height)
                        }
                    )
                    .onPreferenceChange(SidebarHeaderHeightKey.self) { headerHeight = $0 }
                }

                Group {
                    if !isPrimaryServiceRunning {
                        Button {
                            Task { await app.startBot() }
                        } label: {
                            Label(startButtonTitle, systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .help(startStopHelpText)
                    } else {
                        Button {
                            Task { await app.stopBot() }
                        } label: {
                            Label(stopButtonTitle, systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .help(startStopHelpText)
                    }
                }
                .controlSize(.large)
                .buttonBorderShape(.capsule)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(SidebarGlassEdgeOverlay(cornerRadius: 18))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
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
    private func sidebarListRow(_ item: SidebarItem, count: Int? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18, alignment: .center)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(item.rawValue)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.system(size: 14, weight: selection == item ? .semibold : .regular))
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selection == item {
                SidebarSelectionHighlight()
                    .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.16)) {
                selection = item
            }
        }
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .listRowBackground(Color.clear)
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

struct SidebarRow: View {
    let item: SidebarItem
    @Binding var selection: SidebarItem
    let selectionHighlightNamespace: Namespace.ID
    var count: Int?
    var isChild: Bool = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selection = item
            }
        } label: {
            HStack(spacing: 10) {
                if isChild {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                Image(systemName: item.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(item.rawValue)
                    .font(.system(size: 14, weight: selection == item ? .semibold : .medium))
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, isChild ? 22 : 12)
            .padding(.vertical, 9)
            .background {
                if selection == item {
                    SidebarSelectionHighlight()
                        .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tag(item)
    }
}

private struct SidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(controlActiveState == .active ? 0.08 : 0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(controlActiveState == .active ? 0.045 : 0.025), lineWidth: 1)
            )
    }
}

private struct SidebarGlassEdgeOverlay: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        shape
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.26 : 0.55),
                        Color.white.opacity(colorScheme == .dark ? 0.11 : 0.28),
                        Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            .overlay(
                shape
                    .inset(by: 1)
                    .strokeBorder(.white.opacity(colorScheme == .dark ? 0.045 : 0.16), lineWidth: 1)
            )
            .overlay(
                shape
                    .strokeBorder(.black.opacity(colorScheme == .dark ? 0.18 : 0.05), lineWidth: 0.5)
                    .blendMode(.multiply)
            )
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 2) {
                content
            }
        }
    }
}

private struct DashboardSidebarHeader: View {
    let avatarURL: URL?
    let statusText: String
    let isOnline: Bool
    let clusterMode: String
    let clusterIcon: String

    @Environment(\.colorScheme) private var colorScheme

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
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
    }
}

private struct SidebarAvatarView: View {
    let avatarURL: URL?
    let isOnline: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let avatarURL {
                AsyncImage(url: avatarURL) { phase in
                    switch phase {
                    case .empty:
                        placeholder(progress: true)
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .frame(width: 56, height: 56)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.30), lineWidth: 1)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
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

private struct SwiftBotSidebarMaterialBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SwiftBotVisualEffectMaterialView(material: .sidebar, blendingMode: .behindWindow)

            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.20 : 0.28)

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.07 : 0.15),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack {
                Spacer()
                Rectangle()
                    .fill(.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
                    .frame(width: 1)
            }
        }
    }
}

private struct SwiftBotVisualEffectMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
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
