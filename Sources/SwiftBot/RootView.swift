import AppKit
import Charts
import SwiftUI

/// The window's root: onboarding until set up, then the dashboard.
struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview

    var body: some View {
        productionRoot
    }

    private var productionRoot: some View {
        currentRootView
            // Other parts of the app (deep links, menus) ask for a page here
            // rather than reaching into this view's selection.
            .onChange(of: app.requestedSidebarItem, initial: true) { _, item in
                guard let item else { return }
                selection = item
                app.requestedSidebarItem = nil
            }
    }

    @ViewBuilder
    private var currentRootView: some View {
        if !app.isOnboardingComplete {
            OnboardingRootView()
                .frame(minWidth: 1200, minHeight: 760)
                .toggleStyle(.switch)
        } else if app.hasLoadedSettings {
            UnifiedRootView(selection: $selection)
                .frame(minWidth: 1040, minHeight: 700)
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
}

// MARK: - Unified Shell

/// The dashboard shell: sidebar and the selected page.
struct UnifiedRootView: View {
    @Binding var selection: SidebarItem
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
                // Fixed width, as in SwiftMiner: the sidebar is chrome, not content.
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
        } detail: {
            // Bound every destination to the actual detail viewport. A page's
            // ideal content height must not resize or shift the split view and
            // its sidebar when navigation replaces the current destination.
            GeometryReader { geometry in
                detailView
                    // The sidebar animates its selection; the page itself
                    // swaps instantly rather than cross-fading two pages.
                    .animation(nil, value: selection)
                    .padding(.top, isSidebarCollapsed ? Self.collapsedSidebarTopInset : 0)
                    .animation(.easeInOut(duration: 0.2), value: isSidebarCollapsed)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .background(SwiftBotGlassBackground())
                    .dashboardMetricGlowLayer()
                    .clipped()
            }
            .ignoresSafeArea(.container, edges: .top)
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
            ConsoleOverviewView(onNavigate: select)
        case .discord: DiscordPage()
        case .webInterface: WebInterfacePage()
        case .integrations: IntegrationsPage()
        case .swiftMesh: SwiftMeshPage()
        case .activity: ActivityLogView()
        case .recordings: RecordingsPage()
        }
    }

    private func select(_ item: SidebarItem) {
        withAnimation(.easeInOut(duration: 0.2)) {
            selection = item
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

    @Namespace private var selectionNamespace
    @FocusState private var isFocused: Bool
    @State private var rowFrames: [SidebarItem: CGRect] = [:]

    private static let dragCoordinateSpace = "sidebarSelectorDrag"

    /// Rows in display order, for keyboard and drag selection.
    private var visibleItems: [SidebarItem] {
        SidebarItem.sidebarSections.flatMap(\.items)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SidebarItem.sidebarSections) { section in
                    let items = section.items
                    if !items.isEmpty {
                        if let title = section.title {
                            // Readable group labels, with room above each group
                            // so spacing rather than dividers separates them.
                            Text(title)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.top, 14)
                                .padding(.bottom, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(items) { item in
                            row(for: item)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .coordinateSpace(name: Self.dragCoordinateSpace)
            .onPreferenceChange(SidebarRowFramesKey.self) { rowFrames = $0 }
            .gesture(selectionDragGesture)
        }
        .background { SidebarMaterialBackground() }
        .scrollEdgeEffectStyle(.soft, for: .all)
        // Hand-drawn rows lose List's arrow-key navigation; restore it.
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(by: -1) }
        .onKeyPress(.downArrow) { moveSelection(by: 1) }
        .task { isFocused = true }
    }

    private func row(for item: SidebarItem) -> some View {
        SidebarNavigationRow(
            title: item.rawValue,
            systemImage: item.icon,
            isSelected: selection == item,
            selectionNamespace: selectionNamespace,
            badgeCount: badgeCount(for: item),
            brandAsset: item == .discord ? "DiscordLogo" : nil
        ) {
            select(item)
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SidebarRowFramesKey.self,
                    value: [item: geo.frame(in: .named(Self.dragCoordinateSpace))]
                )
            }
        )
    }

    private func select(_ item: SidebarItem) {
        guard selection != item else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selection = item
        }
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let items = visibleItems
        guard let index = items.firstIndex(of: selection) else { return .ignored }
        let target = index + offset
        guard items.indices.contains(target) else { return .handled }
        select(items[target])
        return .handled
    }

    /// Dragging across the rows moves the selection with the pointer.
    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                guard let target = visibleItems.first(where: { rowFrames[$0]?.contains(value.location) ?? false }) else {
                    return
                }
                select(target)
            }
    }

    /// A zero badge is not drawn.
    private func badgeCount(for item: SidebarItem) -> Int {
        item == .recordings ? app.recentMediaCount24h : 0
    }
}
