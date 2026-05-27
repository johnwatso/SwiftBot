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
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = .swiftMesh
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
        case .swiftMesh: SwiftMeshView()
        case .sweep: SweepView()
        }
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
    @Namespace private var selectionHighlightNamespace

    var body: some View {
        ZStack {
            SwiftBotSidebarMaterialBackground()

            VStack(spacing: 0) {
                List {
                    Section {
                        DashboardSidebarHeader(
                            avatarURL: app.botAvatarURL,
                            botUsername: app.resolvedBotUsername,
                            statusText: app.primaryServiceStatusText,
                            isOnline: app.primaryServiceIsOnline,
                            clusterMode: app.clusterSnapshot.mode.rawValue,
                            clusterIcon: clusterIcon
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                    }

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
                        sidebarListRow(.swiftMesh)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .padding(.top, 34)
                .fadingEdges(top: 16, bottom: 20)

                Group {
                    if !isPrimaryServiceRunning {
                        Button {
                            Task { await app.startBot() }
                        } label: {
                            Label(startButtonTitle, systemImage: "play.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await app.stopBot() }
                        } label: {
                            Label(stopButtonTitle, systemImage: "stop.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
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

    private var clusterIcon: String {
        switch app.settings.clusterMode {
        case .standalone: return "desktopcomputer"
        case .leader: return "point.3.connected.trianglepath.dotted"
        case .worker: return "cpu"
        case .standby: return "arrow.triangle.2.circlepath"
        }
    }

    private var startButtonTitle: String {
        app.settings.clusterMode == .worker ? "Start Worker" : "Start Bot"
    }

    private var stopButtonTitle: String {
        app.settings.clusterMode == .worker ? "Stop Worker" : "Stop Bot"
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

    private var highlightMaterial: Material {
        controlActiveState == .active ? .thinMaterial : .ultraThinMaterial
    }

    private var strokeOpacity: Double {
        controlActiveState == .active ? 0.08 : 0.04
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(highlightMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.primary.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: .black.opacity(controlActiveState == .active ? 0.06 : 0), radius: 4, y: 2)
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
    let botUsername: String
    let statusText: String
    let isOnline: Bool
    let clusterMode: String
    let clusterIcon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 12) {
                SidebarAvatarView(avatarURL: avatarURL)

                VStack(alignment: .leading, spacing: 3) {
                    Text(botUsername)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    HStack(spacing: 5) {
                        Circle()
                            .fill(isOnline ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text("SwiftBot")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                SidebarInfoRow(
                    systemImage: "power.circle.fill",
                    title: "Status",
                    value: statusText,
                    tint: isOnline ? .green : .secondary
                )
                SidebarInfoRow(
                    systemImage: clusterIcon,
                    title: "Mode",
                    value: clusterMode,
                    tint: .secondary
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        )
    }
}

private struct SidebarAvatarView: View {
    let avatarURL: URL?

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
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
        .frame(width: 40, height: 40)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func placeholder(progress: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
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
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

private struct SidebarInfoRow: View {
    let systemImage: String
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
