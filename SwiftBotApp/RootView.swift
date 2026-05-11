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
        HStack(spacing: 0) {
            DashboardSidebar(selection: $selection)
                .frame(width: 280)

            Group {
                switch selection {
                case .overview:
                    OverviewView(onOpenSwiftMesh: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = .swiftMesh
                        }
                    })
                case .patchy: PatchyView()
                case .voice: VoiceView()
                case .commands: CommandsView()
                case .activity: ActivityLogView()
                case .wikiBridge: WikiBridgeView()
                case .aiBots: AIBotsView()
                case .analytics: AnalyticsView()
                case .swiftMesh: SwiftMeshView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(SwiftBotGlassBackground())
        .overlay(alignment: .topTrailing) {
            if app.isBetaBuild {
                BetaBadgeView()
                    .padding(.top, 14)
                    .padding(.trailing, 18)
            }
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

            VStack(spacing: 12) {
                DashboardSidebarHeader(
                    avatarURL: app.botAvatarURL,
                    botUsername: app.resolvedBotUsername,
                    statusText: app.primaryServiceStatusText,
                    isOnline: app.primaryServiceIsOnline,
                    clusterMode: app.clusterSnapshot.mode.rawValue,
                    clusterIcon: clusterIcon
                )
                .padding(.horizontal, 10)
                .padding(.top, 44)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        SidebarSection(title: "Dashboard") {
                            SidebarRow(
                                item: .overview,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                        }

                        SidebarSection(title: "Automation") {
                            SidebarRow(
                                item: .commands,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                            SidebarRow(
                                item: .voice,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace,
                                count: app.activeVoice.count
                            )
                            SidebarRow(
                                item: .patchy,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                            SidebarRow(
                                item: .wikiBridge,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                        }

                        SidebarSection(title: "System") {
                            SidebarRow(
                                item: .aiBots,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                            SidebarRow(
                                item: .analytics,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                            SidebarRow(
                                item: .activity,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                        }

                        SidebarSection(title: "Infrastructure") {
                            SidebarRow(
                                item: .swiftMesh,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
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
                .controlSize(.regular)
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
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
        controlActiveState == .active ? .ultraThinMaterial : .bar
    }

    private var strokeOpacity: Double {
        controlActiveState == .active ? 0.16 : 0.10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlightMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 4) {
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
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
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }

    private func placeholder(progress: Bool = false) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.blue, .indigo],
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
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct SwiftBotSidebarMaterialBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: colorScheme == .dark ? .black : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.38 : 0.44)

            SwiftBotVisualEffectMaterialView(material: .sidebar)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Color(nsColor: colorScheme == .dark ? .controlBackgroundColor : .windowBackgroundColor)
                .opacity(colorScheme == .dark ? 0.18 : 0.24)
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
