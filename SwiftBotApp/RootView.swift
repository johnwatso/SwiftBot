import AppKit
import Charts
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview

    var body: some View {
        if !app.isOnboardingComplete {
            OnboardingGateView()
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else if app.isRemoteLaunchMode {
            RemoteModeRootView()
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else {
            HSplitView {
                DashboardSidebar(selection: $selection)
                    .frame(minWidth: 230, idealWidth: 250, maxWidth: 280)

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
                    case .commandLog: CommandLogView()
                    case .wikiBridge: WikiBridgeView()
                    case .logs: LogsView()
                    case .aiBots: AIBotsView()
                    case .diagnostics: DiagnosticsView()
                    case .swiftMesh: SwiftMeshView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SwiftBotGlassBackground())
            }
            .padding(.top, -30)
            .ignoresSafeArea(.container, edges: .top)
            .background(SwiftBotGlassBackground())
            .toggleStyle(.switch)
            .overlay(alignment: .topTrailing) {
                if app.isBetaBuild {
                    BetaBadgeView()
                        .padding(.top, 14)
                        .padding(.trailing, 18)
                }
            }
        } // end else isOnboardingComplete
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
        VStack(spacing: 14) {
            VStack(spacing: 10) {
                Group {
                    if let avatarURL = app.botAvatarURL {
                        AsyncImage(url: avatarURL) { phase in
                            switch phase {
                            case .empty:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    ProgressView()
                                        .tint(.white)
                                }
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(Circle())
                            case .failure:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "cpu.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                }
                            @unknown default:
                                ZStack {
                                    Circle()
                                        .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "cpu.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    } else {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 56, height: 56)
                            Image(systemName: "cpu.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                    }
                }

                VStack(spacing: 2) {
                    Text(app.botUsername)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(app.primaryServiceIsOnline ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(app.primaryServiceStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: clusterIcon)
                            .font(.caption2)
                        Text(app.clusterSnapshot.mode.rawValue)
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SidebarSection(title: "Dashboard") {
                        SidebarRow(item: .overview, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "Automation") {
                        SidebarRow(item: .commands, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        if selection == .commands || selection == .commandLog {
                            SidebarRow(
                                item: .commandLog,
                                selection: $selection,
                                selectionHighlightNamespace: selectionHighlightNamespace,
                                isChild: true
                            )
                        }
                        SidebarRow(item: .voice, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace, count: app.activeVoice.count)
                        SidebarRow(item: .patchy, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .wikiBridge, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "System") {
                        SidebarRow(item: .aiBots, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .diagnostics, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                        SidebarRow(item: .logs, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }

                    SidebarSection(title: "Infrastructure") {
                        SidebarRow(item: .swiftMesh, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Group {
                if !isPrimaryServiceRunning {
                    Button {
                        Task { await app.startBot() }
                    } label: {
                        Label(startButtonTitle, systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(GlassActionButtonStyle())
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
        }
        .padding(12)
        .background(Color.clear)
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
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                }
                Image(systemName: item.icon)
                    .frame(width: 16)
                Text(item.rawValue)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20), in: Capsule())
                }
            }
            .padding(.horizontal, isChild ? 24 : 12)
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
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 4) {
                content
            }
        }
    }
}
