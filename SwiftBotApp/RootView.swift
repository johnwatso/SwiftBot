import AppKit
import Charts
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @State private var selection: SidebarItem = .overview
    @State private var showToken = false

    var body: some View {
        if !app.isOnboardingComplete {
            OnboardingGateView()
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
                case .settings: GeneralSettingsView(showToken: $showToken)
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

struct ViewSectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
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

// MARK: - Onboarding gate

private struct OnboardingGateView: View {
    @EnvironmentObject var app: AppModel

    private enum Step {
        // Initial path choice
        case choosePath
        // Standalone bot path
        case entry, validating, confirmed, failed
        // SwiftMesh path
        case meshSetup, meshTesting, meshConfirmed, meshFailed
    }

    @State private var step: Step = .choosePath
    @State private var tokenInput: String = ""
    @State private var showToken: Bool = false
    @State private var inviteURL: String? = nil
    @State private var inviteConfirmed: Bool = false
    @State private var isLoadingInviteURL: Bool = false
    @State private var inviteLoadFailed: Bool = false
    @State private var movesForward: Bool = true

    var body: some View {
        ZStack {
            SwiftBotGlassBackground()
            OnboardingAnimatedSymbolBackground()
                .allowsHitTesting(false)

            VStack(spacing: 32) {
                // Icon + title (always visible)
                VStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .accessibilityHidden(true)
                    Text("Welcome to SwiftBot")
                        .font(.largeTitle.weight(.bold))
                    Text(stepSubtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Step content
                ZStack {
                    switch step {
                    case .choosePath:
                        choosePathView
                            .id("choosePath")
                    case .entry, .validating, .confirmed, .failed:
                        standaloneFlow
                            .id("standaloneFlow")
                    case .meshSetup, .meshTesting, .meshConfirmed, .meshFailed:
                        meshFlow
                            .id("meshFlow")
                    }
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: movesForward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: movesForward ? .leading : .trailing).combined(with: .opacity)
                    )
                )
                .animation(.smooth(duration: 0.26), value: step)
            }
            .padding(48)
        }
        .ignoresSafeArea()
        .onAppear { tokenInput = app.settings.token }
        .onChange(of: app.workerConnectionTestInProgress) { _, inProgress in
            guard step == .meshTesting, !inProgress else { return }
            step = app.workerConnectionTestIsSuccess ? .meshConfirmed : .meshFailed
        }
        .onChange(of: step) { oldStep, newStep in
            movesForward = stepOrder(newStep) >= stepOrder(oldStep)
        }
    }

    // MARK: - Subtitle

    private var stepSubtitle: String {
        switch step {
        case .choosePath:       return "How would you like to set up SwiftBot?"
        case .entry, .failed:  return "Enter your Discord bot token to get started."
        case .validating:      return "Validating your token…"
        case .confirmed:       return "Your bot is connected and ready."
        case .meshSetup:       return "Enter your SwiftMesh node details."
        case .meshTesting:     return "Testing connection to the SwiftMesh leader…"
        case .meshConfirmed:   return "SwiftMesh connection successful."
        case .meshFailed:      return "Could not reach the SwiftMesh leader."
        }
    }

    // MARK: - Path choice

    private var choosePathView: some View {
        VStack(spacing: 16) {
            Button { step = .entry } label: {
                VStack(spacing: 6) {
                    Image(systemName: "server.rack").font(.title2)
                    Text("Set Up Standalone Bot").font(.headline)
                    Text("Connect a single Discord bot with a token.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
                .padding(20)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button {
                app.settings.clusterMode = .leader
                step = .meshSetup
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.title2)
                    Text("Set Up SwiftMesh Node").font(.headline)
                    Text("Join or create a multi-node SwiftMesh cluster.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
                .padding(20)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
    }

    // MARK: - Standalone flow

    @ViewBuilder
    private var standaloneFlow: some View {
        VStack(spacing: 16) {
            // Token field
            HStack {
                Group {
                    if showToken {
                        TextField("Bot token", text: $tokenInput)
                    } else {
                        SecureField("Bot token", text: $tokenInput)
                    }
                }
                .onboardingTextFieldStyle()
                .font(.system(.body, design: .monospaced))
                .disabled(step == .validating || step == .confirmed)

                Button {
                    showToken.toggle()
                } label: {
                    Image(systemName: showToken ? "eye.slash" : "eye").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showToken ? "Hide token" : "Show token")
            }
            .frame(maxWidth: 560)

            // Error
            if step == .failed, let result = app.lastTokenValidationResult {
                Text(result.errorMessage)
                    .font(.callout).foregroundStyle(.red)
                    .multilineTextAlignment(.center).frame(maxWidth: 560)
            }

            // Actions
            switch step {
            case .entry, .failed:
                HStack(spacing: 12) {
                    Button { step = .choosePath } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered).controlSize(.large)

                    Button {
                        app.settings.token = tokenInput
                        step = .validating
                        Task {
                            let ok = await app.validateAndOnboard()
                            step = ok ? .confirmed : .failed
                        }
                    } label: {
                        Label("Validate Token", systemImage: "checkmark.shield.fill")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(GlassActionButtonStyle()).controlSize(.large)
                    .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

            case .validating:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Validating…").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Validating token, please wait")

            case .confirmed:
                VStack(spacing: 16) {
                    if let result = app.lastTokenValidationResult {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green).accessibilityHidden(true)
                            Text("Connected as **\(result.username ?? "Bot")**")
                        }
                        .font(.body)
                    }

                    // Invite link states
                    if isLoadingInviteURL {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Generating invite link…").font(.callout).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Generating invite link, please wait")
                    } else if inviteLoadFailed {
                        Text("Could not generate an invite link. Your bot's client ID may not be available yet — you can invite the bot manually from the Discord Developer Portal.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 560)
                    }

                    if let url = inviteURL {
                        VStack(spacing: 8) {
                            Text("Invite your bot to a server:")
                                .font(.callout).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                } label: {
                                    Label("Copy Invite Link", systemImage: "doc.on.doc")
                                }
                                .onboardingGlassButton()
                                .accessibilityHint("Copies the bot invite link to your clipboard")

                                Button {
                                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                                } label: {
                                    Label("Open Invite", systemImage: "arrow.up.right.square")
                                }
                                .onboardingGlassButton()
                                .accessibilityHint("Opens the Discord bot authorization page in your browser")
                            }
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                        Toggle(isOn: $inviteConfirmed) {
                            Text("I have invited SwiftBot already").font(.callout)
                        }
                        .toggleStyle(.switch)
                        .frame(maxWidth: 560, alignment: .center)
                    }

                    Button { app.completeOnboarding() } label: {
                        Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
                            .frame(minWidth: 200)
                    }
                    .onboardingGlassButton()
                    .disabled(inviteURL != nil && !inviteConfirmed)
                }
                .task {
                    if inviteURL == nil {
                        isLoadingInviteURL = true
                        inviteURL = await app.generateInviteURL()
                        isLoadingInviteURL = false
                        inviteLoadFailed = (inviteURL == nil)
                    }
                }

            default: EmptyView()
            }
        }
    }

    // MARK: - SwiftMesh flow

    @ViewBuilder
    private var meshFlow: some View {
        switch step {
        case .meshSetup:
            meshSetupFields

        case .meshTesting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Testing connection…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Testing SwiftMesh connection, please wait")

        case .meshConfirmed:
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.title2).accessibilityHidden(true)
                    Text(app.workerConnectionTestStatus).font(.body)
                }
                Button {
                    app.saveSettings()
                    app.completeOnboarding()
                } label: {
                    Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
                        .frame(minWidth: 200)
                }
                .buttonStyle(GlassActionButtonStyle()).controlSize(.large)
            }

        case .meshFailed:
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.title2).accessibilityHidden(true)
                    Text(app.workerConnectionTestStatus)
                        .font(.body).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button { step = .meshSetup } label: {
                        Label("Try Again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered).controlSize(.large)

                    Button {
                        app.settings.clusterMode = .standalone
                        app.saveSettings()
                        app.completeOnboarding()
                    } label: {
                        Label("Set Up Later (Limited Mode)", systemImage: "clock.arrow.2.circlepath")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(GlassActionButtonStyle()).controlSize(.large)
                }
                Text("Limited Mode launches SwiftBot without Discord or SwiftMesh. Configure both from Settings after launch.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 560)
            }

        default: EmptyView()
        }
    }

    private var meshSetupFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Role", selection: $app.settings.clusterMode) {
                Text("Leader").tag(ClusterMode.leader)
                Text("Standby").tag(ClusterMode.standby)
            }
            .pickerStyle(.segmented).frame(maxWidth: 560)

            TextField("Node Name", text: $app.settings.clusterNodeName)
                .onboardingTextFieldStyle().frame(maxWidth: 560)

            if app.settings.clusterMode == .standby {
                TextField("Leader Address (host:port)", text: $app.settings.clusterLeaderAddress)
                    .onboardingTextFieldStyle().frame(maxWidth: 560)
            }

            HStack {
                Text("Listen Port").font(.callout)
                Spacer()
                TextField("Port", text: Binding(
                    get: { String(app.settings.clusterListenPort) },
                    set: { if let v = Int($0) { app.settings.clusterListenPort = v } }
                ))
                .onboardingTextFieldStyle().frame(width: 110)
            }
            .frame(maxWidth: 560)

            SecureField("Shared Secret", text: $app.settings.clusterSharedSecret)
                .onboardingTextFieldStyle().frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button { step = .choosePath } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered).controlSize(.large)

                if app.settings.clusterMode == .leader {
                    // Leader nodes don't test against a remote — save and proceed.
                    Button {
                        app.saveSettings()
                        app.completeOnboarding()
                    } label: {
                        Label("Save & Continue", systemImage: "square.and.arrow.down")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(GlassActionButtonStyle()).controlSize(.large)
                } else {
                    // Standby nodes test connectivity to the leader before proceeding.
                    Button {
                        step = .meshTesting
                        app.testWorkerLeaderConnection()
                    } label: {
                        Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(GlassActionButtonStyle()).controlSize(.large)
                    .disabled(app.settings.clusterLeaderAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: 560)
    }

    private func stepOrder(_ step: Step) -> Int {
        switch step {
        case .choosePath: return 0
        case .entry, .failed: return 1
        case .validating: return 2
        case .confirmed: return 3
        case .meshSetup: return 4
        case .meshTesting: return 5
        case .meshConfirmed, .meshFailed: return 6
        }
    }
}

private struct OnboardingAnimatedSymbolBackground: View {
    @State private var animationStart = Date()

    private let symbols = [
        "book.pages.fill",
        "hammer.fill",
        "terminal.fill",
        "waveform.path.ecg",
        "sparkles",
        "point.3.connected.trianglepath.dotted",
        "server.rack",
        "person.3.sequence",
        "gearshape.2.fill",
        "cpu.fill",
        "wrench.and.screwdriver.fill",
        "bolt.horizontal.circle.fill"
    ]

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
                animatedCanvas(size: proxy.size, date: timeline.date)
            }
        }
        .clipped()
        .opacity(0.78)
    }

    @ViewBuilder
    private func animatedCanvas(size: CGSize, date: Date) -> some View {
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let diagonal = hypot(width, height)
        let elapsed = date.timeIntervalSince(animationStart)

        Canvas { context, _ in
            let trackWidth = diagonal * 2.2
            let trackHeight = diagonal * 1.6
            let rowStep: CGFloat = 108
            let rows = Int(trackHeight / rowStep) + 3
            let iconSize: CGFloat = 40
            let spacing: CGFloat = 50
            let step = iconSize + spacing
            let cols = Int(trackWidth / step) + 12

            context.opacity = 0.10
            context.translateBy(x: width / 2, y: height / 2)
            context.rotate(by: .radians(-.pi / 4))

            var resolvedSymbols: [String: GraphicsContext.ResolvedSymbol] = [:]
            for symbol in symbols {
                if let resolved = context.resolveSymbol(id: symbol) {
                    resolvedSymbols[symbol] = resolved
                }
            }

            for row in 0..<rows {
                let direction: CGFloat = row.isMultiple(of: 2) ? 1 : -1
                let speed: CGFloat = 8 + CGFloat(deterministicInt(row, seed: 19, modulus: 6))
                let y = -trackHeight / 2 + CGFloat(row) * rowStep
                let rowOffset = deterministicInt(row, seed: 31, modulus: symbols.count)
                let strideChoices = [5, 7, 11]
                let stride = strideChoices[deterministicInt(row, seed: 47, modulus: strideChoices.count)]
                let sequencePeriod = symbols.count / greatestCommonDivisor(stride, symbols.count)
                let cycleWidth = CGFloat(sequencePeriod) * step
                var offset = (CGFloat(elapsed) * speed * direction).truncatingRemainder(dividingBy: cycleWidth)
                if offset < 0 { offset += cycleWidth }
                for col in -6...cols {
                    let x = -trackWidth / 2 + CGFloat(col) * step + offset
                    let symbolIndex = positiveModulo(rowOffset + (col * stride), symbols.count)
                    let symbolID = symbols[symbolIndex]
                    if let resolved = resolvedSymbols[symbolID] {
                        context.draw(resolved, at: CGPoint(x: x, y: y), anchor: .center)
                    }
                }
            }
        } symbols: {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.42))
                    .tag(symbol)
            }
        }
    }

    private func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let m = max(modulus, 1)
        let r = value % m
        return r >= 0 ? r : r + m
    }

    private func deterministicInt(_ row: Int, seed: Int, modulus: Int) -> Int {
        let m = max(modulus, 1)
        let mixed = (row &* 73) ^ (seed &* 131) ^ (row &* seed &* 17)
        let r = mixed % m
        return r >= 0 ? r : r + m
    }

    private func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return max(x, 1)
    }
}

private extension View {
    func onboardingTextFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
    }

    func onboardingGlassButton() -> some View {
        self
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.10), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.24), lineWidth: 1)
            )
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
                        SidebarRow(item: .settings, selection: $selection, selectionHighlightNamespace: selectionHighlightNamespace)
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
                        app.stopBot()
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

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case patchy = "Patchy"
    case voice = "Actions"
    case commands = "Commands"
    case commandLog = "Command Log"
    case wikiBridge = "WikiBridge"
    case logs = "Logs"
    case settings = "Settings"
    case aiBots = "AI Bots"
    case diagnostics = "Diagnostics"
    case swiftMesh = "SwiftMesh"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2.fill"
        case .patchy: return "hammer.fill"
        case .voice: return "point.3.filled.connected.trianglepath.dotted"
        case .commands: return "terminal.fill"
        case .commandLog: return "list.bullet.clipboard.fill"
        case .wikiBridge: return "book.pages.fill"
        case .logs: return "list.bullet.clipboard.fill"
        case .settings: return "gearshape.2.fill"
        case .aiBots: return "sparkles.rectangle.stack.fill"
        case .diagnostics: return "waveform.path.ecg"
        case .swiftMesh: return "point.3.connected.trianglepath.dotted"
        }
    }
}

struct OverviewView: View {
    @EnvironmentObject var app: AppModel
    var onOpenSwiftMesh: (() -> Void)?

    private struct VoiceChannelGroup: Identifiable {
        let id: String
        let title: String
        let members: [VoiceMemberPresence]
    }

    private var recentVoice: [VoiceEventLogEntry] {
        Array(app.voiceLog.prefix(5))
    }

    private var recentCommands: [CommandLogEntry] {
        Array(app.commandLog.prefix(5))
    }

    private var workerJobCount: Int {
        app.commandLog.filter { $0.executionRoute == "Worker" || $0.executionRoute == "Remote" }.count
    }

    private var aiProviderSummary: String {
        app.settings.preferredAIProvider.rawValue
    }

    private var enabledWikiSourceCount: Int {
        app.settings.wikiBot.sources.filter(\.enabled).count
    }

    private var enabledWikiCommandCount: Int {
        app.settings.wikiBot.sources
            .filter(\.enabled)
            .reduce(into: 0) { count, source in
                count += source.commands.filter(\.enabled).count
            }
    }

    private var patchyTargetCount: Int {
        app.settings.patchy.sourceTargets.count
    }

    private var patchyEnabledTargetCount: Int {
        app.settings.patchy.sourceTargets.filter(\.isEnabled).count
    }

    private var actionRuleCount: Int {
        app.ruleStore.rules.count
    }

    private var enabledActionRuleCount: Int {
        app.ruleStore.rules.filter(\.isEnabled).count
    }

    private var helpSummary: String {
        "\(app.settings.help.mode.rawValue) · \(app.settings.help.tone.rawValue)"
    }

    private var groupedActiveVoice: [VoiceChannelGroup] {
        let grouped = Dictionary(grouping: app.activeVoice) { member in
            "\(member.guildId):\(member.channelId)"
        }

        return grouped.map { key, members in
            let first = members.first
            let serverName = first.map { app.connectedServers[$0.guildId] ?? $0.guildId } ?? "Unknown Server"
            let channelName = first?.channelName ?? "Voice Channel"
            let orderedMembers = members.sorted { lhs, rhs in
                lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            return VoiceChannelGroup(
                id: key,
                title: "\(channelName) · \(serverName)",
                members: orderedMembers
            )
        }
        .sorted { lhs, rhs in
            if lhs.members.count != rhs.members.count {
                return lhs.members.count > rhs.members.count
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ViewSectionHeader(title: "Overview", symbol: "speedometer")

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 185), spacing: 10)
                ], spacing: 12) {
                    if app.settings.clusterMode == .worker {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.primaryServiceStatusText,
                            subtitle: app.clusterSnapshot.serverStatusText,
                            symbol: "bolt.horizontal.circle.fill",
                            detail: "Auto Start \(app.settings.autoStart ? "On" : "Off")",
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Mesh Mode",
                            value: app.settings.clusterMode.displayName,
                            subtitle: app.settings.clusterNodeName,
                            symbol: "point.3.connected.trianglepath.dotted",
                            detail: "Primary \(app.settings.clusterLeaderAddress.isEmpty ? "Not set" : "Configured")",
                            color: .purple
                        )
                        DashboardMetricCard(
                            title: "Listen Port",
                            value: "\(app.clusterSnapshot.listenPort)",
                            subtitle: "worker HTTP service",
                            symbol: "antenna.radiowaves.left.and.right",
                            detail: "Node \(app.settings.clusterNodeName.isEmpty ? "Unnamed" : app.settings.clusterNodeName)",
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "WikiBridge",
                            value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                            subtitle: "\(enabledWikiSourceCount) sources",
                            symbol: "book.pages.fill",
                            detail: "\(enabledWikiCommandCount) commands",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Patchy",
                            value: app.settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                            subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                            symbol: "hammer.fill",
                            detail: "Jobs \(workerJobCount)",
                            color: .red
                        )
                        DashboardMetricCard(
                            title: "Actions",
                            value: "\(enabledActionRuleCount) active",
                            subtitle: "\(actionRuleCount) total rules",
                            symbol: "point.3.filled.connected.trianglepath.dotted",
                            detail: helpSummary,
                            color: .red
                        )
                    } else {
                        DashboardMetricCard(
                            title: "Status",
                            value: app.status.rawValue.capitalized,
                            subtitle: app.uptime?.text ?? "--",
                            symbol: "bolt.horizontal.circle.fill",
                            detail: "Auto Start \(app.settings.autoStart ? "On" : "Off")",
                            color: .green
                        )
                        DashboardMetricCard(
                            title: "Servers",
                            value: "\(app.connectedServers.count)",
                            subtitle: "servers connected",
                            symbol: "server.rack",
                            detail: app.settings.clusterMode == .standalone ? "Standalone" : app.settings.clusterMode.displayName,
                            color: .blue
                        )
                        DashboardMetricCard(
                            title: "In Voice",
                            value: "\(app.activeVoice.count)",
                            subtitle: "users right now",
                            symbol: "person.3.sequence.fill",
                            detail: "Route \(app.clusterSnapshot.lastJobRoute.rawValue.capitalized)",
                            color: .orange
                        )
                        DashboardMetricCard(
                            title: "Commands Run",
                            value: "\(app.stats.commandsRun)",
                            subtitle: "this session",
                            symbol: "terminal.fill",
                            detail: "Recent commands activity",
                            color: .red
                        )
                        DashboardMetricCard(
                            title: "WikiBridge",
                            value: app.settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                            subtitle: "\(enabledWikiSourceCount) sources",
                            symbol: "book.pages.fill",
                            detail: "\(enabledWikiCommandCount) commands",
                            color: .mint
                        )
                        DashboardMetricCard(
                            title: "Patchy",
                            value: app.settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                            subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets",
                            symbol: "hammer.fill",
                            detail: "Help \(helpSummary)",
                            color: .purple
                        )
                        DashboardMetricCard(
                            title: "Actions",
                            value: "\(enabledActionRuleCount) active",
                            subtitle: "\(actionRuleCount) total rules",
                            symbol: "point.3.filled.connected.trianglepath.dotted",
                            detail: "Errors \(app.stats.errors)",
                            color: .indigo
                        )
                        DashboardMetricCard(
                            title: "AI Bots",
                            value: aiProviderSummary,
                            subtitle: app.settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled",
                            symbol: "sparkles",
                            detail: "Guild AI \(app.settings.behavior.useAIInGuildChannels ? "On" : "Off")",
                            color: .purple
                        )
                    }
                }

                if app.settings.clusterMode != .standalone {
                    OverviewClusterSummaryCard(
                        nodes: app.clusterNodes,
                        onOpenSwiftMesh: onOpenSwiftMesh
                    )
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: "Recent Voice Events", actionTitle: "View") {
                        if recentVoice.isEmpty {
                            PlaceholderPanelLine(text: "No voice events yet")
                        } else {
                            ForEach(recentVoice) { entry in
                                PanelLine(
                                    title: entry.description,
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: .green
                                )
                            }
                        }
                    }

                    DashboardPanel(title: "Recent Commands", actionTitle: "View") {
                        if recentCommands.isEmpty {
                            PlaceholderPanelLine(text: "No commands yet")
                        } else {
                            ForEach(recentCommands) { entry in
                                PanelLine(
                                    title: "\(entry.user) @ \(entry.server) • \(entry.command)",
                                    subtitle: entry.time.formatted(date: .omitted, time: .standard),
                                    tone: entry.ok ? .accentColor : .red
                                )
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    DashboardPanel(title: app.settings.clusterMode == .worker ? "Worker Activity" : "Currently In Voice") {
                        if app.settings.clusterMode == .worker {
                            InfoRow(label: "Server", value: app.clusterSnapshot.serverStatusText)
                            InfoRow(label: "Last Job", value: app.clusterSnapshot.lastJobSummary)
                            InfoRow(label: "Last Node", value: app.clusterSnapshot.lastJobNode)
                            InfoRow(label: "Diagnostics", value: app.clusterSnapshot.diagnostics)
                        } else if app.activeVoice.isEmpty {
                            PlaceholderPanelLine(text: "No one is in voice right now")
                        } else {
                            ForEach(groupedActiveVoice) { group in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(group.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(group.members) { member in
                                            VoicePresenceMemberRow(
                                                member: member,
                                                avatarURL: app.avatarURL(forUserId: member.userId, guildId: member.guildId) ?? app.fallbackAvatarURL(forUserId: member.userId)
                                            )
                                        }
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                            }
                        }
                    }

                    DashboardPanel(title: "Bot Info") {
                        InfoRow(label: "Uptime", value: app.settings.clusterMode == .worker ? "--" : (app.uptime?.text ?? "--"))
                        InfoRow(label: "Errors", value: "\(app.stats.errors)")
                        InfoRow(label: "State", value: app.settings.clusterMode == .worker ? app.primaryServiceStatusText : app.status.rawValue.capitalized)
                        if app.settings.clusterMode != .standalone {
                            InfoRow(label: "Cluster", value: app.clusterSnapshot.mode.rawValue)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
            .background(SwiftBotGlassBackground().opacity(0.55))
        }
    }
}

struct OverviewClusterSummaryCard: View {
    @EnvironmentObject var app: AppModel
    let nodes: [ClusterNodeStatus]
    var onOpenSwiftMesh: (() -> Void)?

    private var leaderNode: ClusterNodeStatus? {
        nodes.first(where: { $0.role == .leader }) ?? nodes.first
    }

    private var connectedNodeCount: Int {
        nodes.filter { $0.status != .disconnected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cluster")
                .font(.headline)

            Text("\(connectedNodeCount) nodes connected")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let leaderNode {
                HStack {
                    Text("Primary")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(leaderNode.hostname) (\(leaderNode.role.displayName))")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
            } else {
                PlaceholderPanelLine(text: "No cluster nodes available")
            }

            Button("View in SwiftMesh") {
                onOpenSwiftMesh?()
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 14, x: 0, y: 8)
        .task(id: app.settings.clusterMode) {
            guard app.settings.clusterMode != .standalone else { return }
            await app.pollClusterStatus()
        }
    }
}

enum TriggerType: String, CaseIterable, Identifiable, Codable {
    case userJoinedVoice = "User Joins Voice"
    case userLeftVoice = "User Leaves Voice"
    case userMovedVoice = "User Moves Voice"
    case messageContains = "Message Contains"
    case memberJoined = "Member Joined"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .userJoinedVoice: return "person.crop.circle.badge.plus"
        case .userLeftVoice: return "person.crop.circle.badge.xmark"
        case .userMovedVoice: return "arrow.left.arrow.right.circle"
        case .messageContains: return "text.bubble"
        case .memberJoined: return "person.badge.plus"
        }
    }

    var defaultMessage: String {
        switch self {
        case .userJoinedVoice: return "🔊 <@{userId}> connected to <#{channelId}>"
        case .userLeftVoice: return "🔌 <@{userId}> disconnected from <#{channelId}> (Online for {duration})"
        case .userMovedVoice: return "🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>"
        case .messageContains: return "nm you?"
        case .memberJoined: return "👋 Welcome to {server}, {username}! You're member #{memberCount}."
        }
    }

    var defaultRuleName: String {
        switch self {
        case .userJoinedVoice: return "Join Action"
        case .userLeftVoice: return "Leave Action"
        case .userMovedVoice: return "Move Action"
        case .messageContains: return "Message Reply"
        case .memberJoined: return "Member Join Welcome"
        }
    }

    static var allDefaultMessages: Set<String> {
        var messages = Set(allCases.map(\.defaultMessage))
        // Include legacy defaults so trigger changes still auto-populate
        messages.insert("🔊 <@{userId}> connected to <#{channelId}>")
        messages.insert("🔌 <@{userId}> disconnected from <#{channelId}>")
        messages.insert("🔀 <@{userId}> moved from <#{fromChannelId}> to <#{toChannelId}>")
        return messages
    }
}

enum ConditionType: String, CaseIterable, Identifiable, Codable {
    case server = "Server Is"
    case voiceChannel = "Voice Channel Is"
    case usernameContains = "Username Contains"
    case minimumDuration = "Duration In Channel"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .server: return "building.2"
        case .voiceChannel: return "waveform"
        case .usernameContains: return "text.magnifyingglass"
        case .minimumDuration: return "timer"
        }
    }
}

enum ActionType: String, CaseIterable, Identifiable, Codable {
    case sendMessage = "Send Message"
    case addLogEntry = "Add Log Entry"
    case setStatus = "Set Bot Status"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .sendMessage: return "paperplane.fill"
        case .addLogEntry: return "list.bullet.clipboard"
        case .setStatus: return "dot.radiowaves.left.and.right"
        }
    }
}

struct Condition: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ConditionType
    var value: String = ""
    var secondaryValue: String = ""
    var enabled: Bool = true
}

struct RuleAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: ActionType = .sendMessage
    var serverId: String = ""
    var channelId: String = ""
    var mentionUser: Bool = true
    var message: String = "🔊 <@{userId}> connected to <#{channelId}>"
    var statusText: String = "Voice notifier active"
}

typealias Action = RuleAction

struct Rule: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "New Action"
    var trigger: TriggerType = .userJoinedVoice
    var conditions: [Condition] = []
    var actions: [RuleAction] = [RuleAction()]
    var isEnabled: Bool = true

    var triggerServerId: String = ""
    var triggerVoiceChannelId: String = ""
    var triggerMessageContains: String = "up to?"
    var replyToDMs: Bool = false

    var includeStageChannels: Bool = true

    var triggerSummary: String {
        switch trigger {
        case .userJoinedVoice: return "When someone joins voice"
        case .userLeftVoice: return "When someone leaves voice"
        case .userMovedVoice: return "When someone moves voice"
        case .messageContains:
            return triggerMessageContains.isEmpty ? "When message contains text" : "When message contains \"\(triggerMessageContains)\""
        case .memberJoined: return "When a member joins the server"
        }
    }
}

struct VoiceView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VoiceWorkspaceView(ruleStore: app.ruleStore)
            .environmentObject(app)
    }
}

struct VoiceWorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var ruleStore: RuleStore
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(spacing: 0) {
        HSplitView {
            RuleListView(
                rules: rulesBinding,
                selectedRuleID: appSelectionBinding,
                onAddNew: {
                    let sid = serverIds.first ?? ""
                    let cid = app.availableTextChannelsByServer[sid]?.first?.id ?? ""
                    ruleStore.addNewRule(serverId: sid, channelId: cid)
                },
                onDeleteRuleID: { ruleID in
                    ruleStore.deleteRule(id: ruleID, undoManager: undoManager)
                }
            )
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            Group {
                if let selectedRuleBinding {
                    RuleEditorView(rule: selectedRuleBinding)
                        .id(ruleStore.selectedRuleID)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Select an Action Rule")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.clear)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.white.opacity(0.04))
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: ruleStore.rules) {
            if let selected = ruleStore.selectedRuleID,
               !ruleStore.rules.contains(where: { $0.id == selected }) {
                ruleStore.selectedRuleID = nil
            }
            ruleStore.scheduleAutoSave()
        }
        } // end VStack
    }

    private var rulesBinding: Binding<[Rule]> {
        Binding(
            get: { ruleStore.rules },
            set: { ruleStore.rules = $0 }
        )
    }

    private var appSelectionBinding: Binding<UUID?> {
        Binding(
            get: { ruleStore.selectedRuleID },
            set: { ruleStore.selectedRuleID = $0 }
        )
    }

    private var selectedRuleBinding: Binding<Rule>? {
        guard let selectedRuleID = ruleStore.selectedRuleID else {
            return nil
        }

        return Binding(
            get: {
                guard let currentSelectedID = ruleStore.selectedRuleID,
                      let index = ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                    return Rule(id: selectedRuleID)
                }
                return ruleStore.rules[index]
            },
            set: { updatedRule in
                guard let currentSelectedID = ruleStore.selectedRuleID,
                      let index = ruleStore.rules.firstIndex(where: { $0.id == currentSelectedID }) else {
                    return
                }
                ruleStore.rules[index] = updatedRule
            }
        )
    }

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }
}

struct RuleEditorView: View {
    @Binding var rule: Rule
    @EnvironmentObject var app: AppModel

    private var serverIds: [String] {
        app.connectedServers.keys.sorted {
            (app.connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(app.connectedServers[$1] ?? $1) == .orderedAscending
        }
    }

    private func serverName(for serverId: String) -> String {
        app.connectedServers[serverId] ?? "Server \(serverId.suffix(4))"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                RulePaneHeader(
                    title: "Block Library",
                    subtitle: "Reusable building blocks for this rule flow.",
                    systemImage: "square.stack.3d.up.fill"
                )

                ScrollView {
                    RuleBuilderLibraryView(
                        serverIds: serverIds,
                        onAddCondition: addCondition(_:),
                        onAddAction: addAction(_:),
                        focusTrigger: { applyTriggerDefaults(for: rule.trigger) }
                    )
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
            }
            .frame(minWidth: 250, idealWidth: 270, maxWidth: 300)
            .background(rulePaneBackground)

            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1)

            VStack(spacing: 0) {
                RulePaneHeader(
                    title: rule.name.isEmpty ? "Action Rule" : rule.name,
                    subtitle: rule.triggerSummary,
                    systemImage: "point.3.filled.connected.trianglepath.dotted"
                )

                TextField("Rule Name", text: $rule.name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.white.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.20), lineWidth: 1)
                    )
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                .background(rulePaneBackground)

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        RuleCanvasSection(title: "Trigger Block", systemImage: "bolt.fill", accent: .yellow) {
                            TriggerSectionView(
                                triggerType: $rule.trigger,
                                triggerServerId: $rule.triggerServerId,
                                triggerVoiceChannelId: $rule.triggerVoiceChannelId,
                                triggerMessageContains: $rule.triggerMessageContains,
                                replyToDMs: $rule.replyToDMs,
                                includeStageChannels: $rule.includeStageChannels,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                voiceChannels: app.availableVoiceChannelsByServer[rule.triggerServerId] ?? []
                            )
                        }

                        RuleFlowArrow()

                        RuleCanvasSection(title: "Filter Blocks", systemImage: "line.3.horizontal.decrease.circle", accent: .cyan) {
                            ConditionsSectionView(
                                conditions: $rule.conditions,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                voiceChannels: app.availableVoiceChannelsByServer[rule.triggerServerId] ?? []
                            )
                        }

                        RuleFlowArrow()

                        RuleCanvasSection(title: "Action Blocks", systemImage: "paperplane.fill", accent: .mint) {
                            ActionsSectionView(
                                actions: $rule.actions,
                                serverIds: serverIds,
                                serverName: serverName(for:),
                                textChannelsByServer: app.availableTextChannelsByServer
                            )
                        }
                    }
                    .frame(maxWidth: 880, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
            .background(rulePaneBackground)
        }
        .navigationTitle("")
        .onAppear {
            initializeRuleDefaultsIfNeeded()
        }
        .onChange(of: rule) {
            app.ruleStore.scheduleAutoSave()
        }
        .onChange(of: rule.trigger) { _, newTrigger in
            applyTriggerDefaults(for: newTrigger)
        }
    }

    private func addCondition(_ type: ConditionType) {
        rule.conditions.append(Condition(type: type))
        app.ruleStore.scheduleAutoSave()
    }

    private func addAction(_ type: ActionType) {
        var action = RuleAction()
        action.type = type
        action.serverId = serverIds.first ?? ""
        action.channelId = app.availableTextChannelsByServer[action.serverId]?.first?.id ?? ""
        action.message = rule.trigger.defaultMessage

        switch type {
        case .sendMessage:
            break
        case .addLogEntry:
            action.message = "Rule fired for {username}"
        case .setStatus:
            action.statusText = "Handling \(rule.trigger.rawValue.lowercased())"
        }

        rule.actions.append(action)
        app.ruleStore.scheduleAutoSave()
    }

    private func initializeRuleDefaultsIfNeeded() {
        var didChange = false

        if rule.triggerServerId.isEmpty {
            rule.triggerServerId = serverIds.first ?? ""
            didChange = true
        }

        if rule.actions.isEmpty {
            var action = RuleAction()
            action.serverId = serverIds.first ?? ""
            let channels = app.availableTextChannelsByServer[action.serverId] ?? []
            action.channelId = channels.first?.id ?? ""
            action.message = rule.trigger.defaultMessage
            rule.actions = [action]
            didChange = true
        } else {
            if rule.actions[0].serverId.isEmpty, let first = serverIds.first {
                rule.actions[0].serverId = first
                didChange = true
            }
            if rule.actions[0].channelId.isEmpty {
                let channels = app.availableTextChannelsByServer[rule.actions[0].serverId] ?? []
                if let first = channels.first {
                    rule.actions[0].channelId = first.id
                    didChange = true
                }
            }
        }

        if didChange {
            app.ruleStore.scheduleAutoSave()
        }
    }

    private func applyTriggerDefaults(for newTrigger: TriggerType) {
        let defaults = TriggerType.allDefaultMessages
        var didChange = false

        if !rule.actions.isEmpty,
           rule.actions[0].type == .sendMessage,
           defaults.contains(rule.actions[0].message) {
            rule.actions[0].message = newTrigger.defaultMessage
            didChange = true
        }

        let defaultNames = Set(TriggerType.allCases.map(\.defaultRuleName) + ["New Action", "Join Action"])
        if defaultNames.contains(rule.name) {
            rule.name = newTrigger.defaultRuleName
            didChange = true
        }

        if newTrigger == .messageContains,
           rule.triggerMessageContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rule.triggerMessageContains = "up to?"
            didChange = true
        }

        if didChange {
            app.ruleStore.scheduleAutoSave()
        }
    }

    private var rulePaneBackground: some View {
        Rectangle()
            .fill(.white.opacity(0.04))
    }
}

struct RuleBuilderLibraryView: View {
    let serverIds: [String]
    let onAddCondition: (ConditionType) -> Void
    let onAddAction: (ActionType) -> Void
    let focusTrigger: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RuleLibrarySection(title: "Start") {
                RuleLibraryButton(
                    title: "Trigger Block",
                    subtitle: "Choose the event that starts this rule",
                    systemImage: "bolt.fill",
                    accent: .yellow,
                    action: focusTrigger
                )
            }

            RuleLibrarySection(title: "Filters") {
                ForEach(ConditionType.allCases) { type in
                    RuleLibraryButton(
                        title: type.rawValue,
                        subtitle: "Add a reusable filter block",
                        systemImage: type.symbol,
                        accent: .cyan,
                        action: { onAddCondition(type) }
                    )
                }
            }

            RuleLibrarySection(title: "Actions") {
                ForEach(ActionType.allCases) { type in
                    RuleLibraryButton(
                        title: type.rawValue,
                        subtitle: "Insert this output block into the flow",
                        systemImage: type.symbol,
                        accent: .mint,
                        action: { onAddAction(type) }
                    )
                }
            }

            if serverIds.isEmpty {
                Text("Connect the bot to Discord to unlock server and channel pickers in action blocks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, 4)
    }
}

struct RulePaneHeader: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 46, alignment: .bottomLeading)
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(height: 1)
        }
    }
}

struct RuleLibrarySection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
        }
    }
}

struct RuleLibraryButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.headline)
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(accent)
            }
            .padding(12)
            .glassCard(cornerRadius: 18, tint: .white.opacity(0.05), stroke: .white.opacity(0.14))
        }
        .buttonStyle(.plain)
    }
}

struct RuleCanvasSection<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.10), stroke: .white.opacity(0.18))
    }
}

struct RuleFlowArrow: View {
    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: 44, height: 2)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: 44, height: 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 2)
    }
}

struct RuleGroupSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.18))
    }
}

struct TriggerSectionView: View {
    @Binding var triggerType: TriggerType
    @Binding var triggerServerId: String
    @Binding var triggerVoiceChannelId: String
    @Binding var triggerMessageContains: String
    @Binding var replyToDMs: Bool
    @Binding var includeStageChannels: Bool

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Event", selection: $triggerType) {
                ForEach(TriggerType.allCases) { trigger in
                    Label(trigger.rawValue, systemImage: trigger.symbol).tag(trigger)
                }
            }

            Picker("Server", selection: $triggerServerId) {
                ForEach(serverIds, id: \.self) { serverId in
                    Text(serverName(serverId)).tag(serverId)
                }
            }

            if triggerType != .messageContains, triggerType != .memberJoined, !voiceChannels.isEmpty {
                Picker("Voice Channel", selection: $triggerVoiceChannelId) {
                    Text("Any Channel").tag("")
                    ForEach(voiceChannels) { channel in
                        Text(channel.name).tag(channel.id)
                    }
                }
            }

            if triggerType == .messageContains {
                TextField("Message contains…", text: $triggerMessageContains)
                Toggle("Reply to DMs", isOn: $replyToDMs)
            }

            if triggerType == .userJoinedVoice || triggerType == .userMovedVoice {
                Toggle("Include Stage Channels", isOn: $includeStageChannels)
            }
        }
    }
}

struct ConditionsSectionView: View {
    @Binding var conditions: [Condition]

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if conditions.isEmpty {
                Text("No conditions configured. Rules will run for all matching events.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach($conditions) { $condition in
                    ConditionRowView(
                        condition: $condition,
                        serverIds: serverIds,
                        serverName: serverName,
                        voiceChannels: voiceChannels,
                        onDelete: {
                            conditions.removeAll { $0.id == condition.id }
                        }
                    )
                }
            }

            Menu {
                ForEach(ConditionType.allCases) { type in
                    Button {
                        conditions.append(Condition(type: type))
                    } label: {
                        Label(type.rawValue, systemImage: type.symbol)
                    }
                }
            } label: {
                Label("Add Condition", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
        }
    }
}

struct ConditionRowView: View {
    @Binding var condition: Condition

    let serverIds: [String]
    let serverName: (String) -> String
    let voiceChannels: [GuildVoiceChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Condition", selection: $condition.type) {
                    ForEach(ConditionType.allCases) { type in
                        Label(type.rawValue, systemImage: type.symbol).tag(type)
                    }
                }
                Toggle("Enabled", isOn: $condition.enabled)
                    .toggleStyle(.switch)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            conditionEditor
        }
        .padding(10)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.08), stroke: .white.opacity(0.16))
    }

    @ViewBuilder
    private var conditionEditor: some View {
        switch condition.type {
        case .server:
            Picker("Server", selection: $condition.value) {
                ForEach(serverIds, id: \.self) { serverId in
                    Text(serverName(serverId)).tag(serverId)
                }
            }
        case .voiceChannel:
            Picker("Voice Channel", selection: $condition.value) {
                Text("Any Channel").tag("")
                ForEach(voiceChannels) { channel in
                    Text(channel.name).tag(channel.id)
                }
            }
        case .usernameContains:
            TextField("Username contains…", text: $condition.value)
        case .minimumDuration:
            HStack {
                TextField("Minimum", text: $condition.value)
                    .frame(width: 80)
                Text("minutes in channel")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ActionsSectionView: View {
    @Binding var actions: [Action]

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannelsByServer: [String: [GuildTextChannel]]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if actions.isEmpty {
                Button {
                    var action = Action()
                    action.serverId = serverIds.first ?? ""
                    action.channelId = textChannelsByServer[action.serverId]?.first?.id ?? ""
                    actions = [action]
                } label: {
                    Label("Add First Action Block", systemImage: "plus")
                }
            } else {
                ForEach($actions) { $action in
                    ActionSectionView(
                        action: $action,
                        serverIds: serverIds,
                        serverName: serverName,
                        textChannels: textChannelsByServer[action.serverId] ?? [],
                        onDelete: {
                            actions.removeAll { $0.id == action.id }
                        }
                    )
                }
            }
        }
    }
}

struct ActionSectionView: View {
    @Binding var action: Action

    let serverIds: [String]
    let serverName: (String) -> String
    let textChannels: [GuildTextChannel]
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Action", selection: $action.type) {
                    ForEach(ActionType.allCases) { actionType in
                        Label(actionType.rawValue, systemImage: actionType.symbol).tag(actionType)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            switch action.type {
            case .sendMessage:
                if serverIds.isEmpty {
                    Text("No connected servers available yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Server", selection: $action.serverId) {
                        ForEach(serverIds, id: \.self) { serverId in
                            Text(serverName(serverId)).tag(serverId)
                        }
                    }
                }

                if textChannels.isEmpty {
                    Text("No text channels discovered for this server.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Text Channel", selection: $action.channelId) {
                        ForEach(textChannels) { channel in
                            Text("#\(channel.name)").tag(channel.id)
                        }
                    }
                }

                Toggle("Mention user in message", isOn: $action.mentionUser)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Message")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $action.message)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
                        )
                }
            case .addLogEntry:
                TextField("Log message", text: $action.message)
            case .setStatus:
                TextField("Status text", text: $action.statusText)
            }

            Text("Use placeholders in messages: {userId}, {username}, {channelId}, {channelName}, {guildName}, {duration}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.16))
        .onAppear {
            if action.serverId.isEmpty {
                action.serverId = serverIds.first ?? ""
            }
            if action.channelId.isEmpty {
                action.channelId = textChannels.first?.id ?? ""
            }
        }
        .onChange(of: action.serverId) {
            action.channelId = textChannels.first?.id ?? ""
        }
    }
}

struct CommandsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showSettingsUpdatedToast = false
    @State private var settingsToastTask: Task<Void, Never>?

    private struct VisualCommand: Identifiable {
        let id: String
        let name: String
        let usage: String
        let description: String
        let category: String
        let surface: String
        let aliases: [String]
        let adminOnly: Bool
    }

    private var visualPrefixCommands: [VisualCommand] {
        let catalog = app.buildFullHelpCatalog(prefix: app.effectivePrefix())
        return catalog.entries.map { entry in
            VisualCommand(
                id: "prefix-\(entry.name)",
                name: entry.name,
                usage: entry.usage,
                description: entry.description,
                category: entry.category.rawValue,
                surface: "Prefix",
                aliases: entry.aliases,
                adminOnly: entry.isAdminOnly
            )
        }
    }

    private var visualSlashCommands: [VisualCommand] {
        app.allSlashCommandDefinitions().compactMap { raw in
            guard let name = raw["name"] as? String else { return nil }
            let description = (raw["description"] as? String) ?? "No description"
            let options = (raw["options"] as? [[String: Any]]) ?? []
            let usageSuffix = options.compactMap { option in
                guard let optionName = option["name"] as? String else { return nil }
                let required = (option["required"] as? Bool) ?? false
                return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
            }.joined()
            return VisualCommand(
                id: "slash-\(name)",
                name: name,
                usage: "/\(name)\(usageSuffix)",
                description: description,
                category: "Slash",
                surface: "Slash",
                aliases: [],
                adminOnly: name == "debug"
            )
        }
    }

    private func commandEnabledBinding(for command: VisualCommand) -> Binding<Bool> {
        Binding(
            get: { app.isCommandEnabled(name: command.name, surface: command.surface.lowercased()) },
            set: { app.setCommandEnabled(name: command.name, surface: command.surface.lowercased(), enabled: $0) }
        )
    }

    private var allVisualCommands: [VisualCommand] {
        guard app.settings.commandsEnabled else { return [] }

        var commands: [VisualCommand] = []
        if app.settings.prefixCommandsEnabled {
            commands += visualPrefixCommands
        }
        if app.settings.slashCommandsEnabled {
            commands += visualSlashCommands
        }

        return commands.sorted { lhs, rhs in
            if lhs.surface != rhs.surface {
                return lhs.surface < rhs.surface
            }
            if lhs.category != rhs.category {
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func persistCommandSettings(syncSlash: Bool) {
        app.persistSettingsQuietly()
        if syncSlash {
            Task { await app.registerSlashCommandsIfNeeded() }
        }
        settingsToastTask?.cancel()
        withAnimation(.easeOut(duration: 0.16)) {
            showSettingsUpdatedToast = true
        }
        settingsToastTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeIn(duration: 0.2)) {
                    showSettingsUpdatedToast = false
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Commands", symbol: "terminal.fill")
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Command System")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 10) {
                            Text("Enable Commands")
                            Spacer(minLength: 0)
                            Toggle("", isOn: $app.settings.commandsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                        }
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)

                        HStack(spacing: 10) {
                            Text("Enable Prefix Commands")
                            Spacer(minLength: 0)
                            Toggle("", isOn: $app.settings.prefixCommandsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!app.settings.commandsEnabled)
                        }
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)

                        HStack(spacing: 10) {
                            Text("Enable Slash Commands")
                            Spacer(minLength: 0)
                            Toggle("", isOn: $app.settings.slashCommandsEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .disabled(!app.settings.commandsEnabled)
                        }
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    }
                }
                .controlSize(.small)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 10) {
                    Text("Command Catalog")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if allVisualCommands.isEmpty {
                        VStack {
                            Spacer(minLength: 0)
                            VStack(spacing: 6) {
                                Text("No Commands Available")
                                    .font(.headline)
                                Text("Commands will appear here once the bot registers them.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .multilineTextAlignment(.center)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 13) {
                                ForEach(allVisualCommands) { command in
                                    HStack(alignment: .center, spacing: 16) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack(spacing: 8) {
                                                Text(command.name)
                                                    .font(.body.weight(.semibold))
                                                CommandTag(text: command.surface, tint: command.surface == "Slash" ? .orange : .blue)
                                                CommandTag(text: command.category, tint: .secondary)
                                                if command.adminOnly {
                                                    CommandTag(text: "Admin", tint: .red)
                                                }
                                            }

                                            Text(command.usage)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .textSelection(.enabled)

                                            Text(command.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)

                                            if !command.aliases.isEmpty {
                                                Text("Aliases: " + command.aliases.joined(separator: ", "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                        Toggle("Enabled", isOn: commandEnabledBinding(for: command))
                                            .labelsHidden()
                                            .toggleStyle(.switch)
                                            .frame(maxHeight: .infinity, alignment: .center)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, 14)
                                    .padding(.trailing, 22)
                                    .padding(.vertical, 10)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topTrailing) {
            if showSettingsUpdatedToast {
                Text("Settings updated")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.trailing, 18)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: app.settings.commandsEnabled) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
        .onChange(of: app.settings.prefixCommandsEnabled) { _, _ in
            persistCommandSettings(syncSlash: false)
        }
        .onChange(of: app.settings.slashCommandsEnabled) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
        .onChange(of: app.settings.disabledCommandKeys) { _, _ in
            persistCommandSettings(syncSlash: true)
        }
    }
}

private struct CommandTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(.primary)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
    }
}

struct CommandLogView: View {
    @EnvironmentObject var app: AppModel
    @State private var mode: CommandLogMode = .log

    private enum CommandLogMode: String, CaseIterable, Identifiable {
        case log = "Log"
        case insights = "Insights"

        var id: String { rawValue }
    }

    private struct HourlyCommandBin: Identifiable {
        let hourStart: Date
        let count: Int

        var id: Date { hourStart }
    }

    private struct RouteCount: Identifiable {
        let route: String
        let count: Int

        var id: String { route }
    }

    private struct CommandCount: Identifiable {
        let command: String
        let count: Int

        var id: String { command }
    }

    private var commandsToday: Int {
        let calendar = Calendar.current
        return app.commandLog.filter { calendar.isDateInToday($0.time) }.count
    }

    private var errorCount: Int {
        app.commandLog.filter { !$0.ok }.count
    }

    private var errorRatePercent: Int {
        guard !app.commandLog.isEmpty else { return 0 }
        return Int((Double(errorCount) / Double(app.commandLog.count) * 100.0).rounded())
    }

    private var workerOrRemoteCount: Int {
        app.commandLog.filter {
            let route = $0.executionRoute.lowercased()
            return route == "worker" || route == "remote"
        }.count
    }

    private var workerSharePercent: Int {
        guard !app.commandLog.isEmpty else { return 0 }
        return Int((Double(workerOrRemoteCount) / Double(app.commandLog.count) * 100.0).rounded())
    }

    private var hourlySeries: [HourlyCommandBin] {
        let calendar = Calendar.current
        let now = Date()
        guard let currentHour = calendar.dateInterval(of: .hour, for: now)?.start else { return [] }
        let startHour = calendar.date(byAdding: .hour, value: -23, to: currentHour) ?? currentHour
        let entries = app.commandLog.filter { $0.time >= startHour }
        var bins: [Date: Int] = [:]

        for entry in entries {
            guard let bucket = calendar.dateInterval(of: .hour, for: entry.time)?.start else { continue }
            bins[bucket, default: 0] += 1
        }

        return (0..<24).compactMap { offset -> HourlyCommandBin? in
            guard let hour = calendar.date(byAdding: .hour, value: offset, to: startHour) else { return nil }
            return HourlyCommandBin(hourStart: hour, count: bins[hour, default: 0])
        }
    }

    private var routeCounts: [RouteCount] {
        let grouped = Dictionary(grouping: app.commandLog) { entry in
            let trimmed = entry.executionRoute.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Unknown" : trimmed
        }
        return grouped
            .map { RouteCount(route: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.route.localizedCaseInsensitiveCompare(rhs.route) == .orderedAscending
            }
    }

    private var topCommands: [CommandCount] {
        let grouped = Dictionary(grouping: app.commandLog) { entry in
            normalizedCommandName(from: entry.command)
        }

        return grouped
            .map { CommandCount(command: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.command.localizedCaseInsensitiveCompare(rhs.command) == .orderedAscending
            }
            .prefix(8)
            .map { $0 }
    }

    private func normalizedCommandName(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(unknown)" }
        let token = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let cleaned = token
            .trimmingCharacters(in: CharacterSet(charactersIn: "/!"))
            .lowercased()
        return cleaned.isEmpty ? "(unknown)" : cleaned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ViewSectionHeader(title: "Command Log", symbol: "list.bullet.clipboard.fill")
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(CommandLogMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if mode == .log {
                Table(app.commandLog) {
                    TableColumn("Time") { Text($0.time.formatted(date: .omitted, time: .standard)) }
                    TableColumn("User") { Text($0.user) }
                    TableColumn("Server") { Text($0.server) }
                    TableColumn("Command") { Text($0.command) }
                    TableColumn("Channel") { Text($0.channel) }
                    TableColumn("Route") { Text($0.executionRoute) }
                    TableColumn("Executed On") { Text($0.executionNode) }
                    TableColumn("Status") { entry in
                        Text(entry.ok ? "OK" : "ERROR")
                            .foregroundStyle(entry.ok ? .green : .red)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .glassCard(cornerRadius: 20, tint: .white.opacity(0.08), stroke: .white.opacity(0.18))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10)], spacing: 10) {
                            CommandInsightCard(title: "Total Commands", value: "\(app.commandLog.count)", subtitle: "Session")
                            CommandInsightCard(title: "Commands Today", value: "\(commandsToday)", subtitle: "Calendar day")
                            CommandInsightCard(title: "Error Rate", value: "\(errorRatePercent)%", subtitle: "\(errorCount) failed")
                            CommandInsightCard(title: "Worker/Remote", value: "\(workerSharePercent)%", subtitle: "\(workerOrRemoteCount) routed")
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Command Volume (Last 24 Hours)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Chart(hourlySeries) { point in
                                AreaMark(
                                    x: .value("Hour", point.hourStart),
                                    y: .value("Commands", point.count)
                                )
                                .foregroundStyle(.red.opacity(0.18))

                                LineMark(
                                    x: .value("Hour", point.hourStart),
                                    y: .value("Commands", point.count)
                                )
                                .foregroundStyle(.red)
                                .lineStyle(.init(lineWidth: 2, lineCap: .round))
                            }
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                                    AxisGridLine()
                                    AxisTick()
                                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                                }
                            }
                            .frame(height: 190)
                        }
                        .padding(12)
                        .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.16))

                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Execution Routes")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Chart(routeCounts) { item in
                                    BarMark(
                                        x: .value("Route", item.route),
                                        y: .value("Commands", item.count)
                                    )
                                    .foregroundStyle(by: .value("Route", item.route))
                                }
                                .frame(height: 190)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.16))

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Top Commands")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Chart(topCommands) { item in
                                    BarMark(
                                        x: .value("Count", item.count),
                                        y: .value("Command", item.command)
                                    )
                                    .foregroundStyle(.orange)
                                }
                                .frame(height: 190)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .glassCard(cornerRadius: 18, tint: .white.opacity(0.06), stroke: .white.opacity(0.16))
                        }
                    }
                    .padding(.bottom, 8)
                }
                .glassCard(cornerRadius: 20, tint: .white.opacity(0.08), stroke: .white.opacity(0.18))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

private struct CommandInsightCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .glassCard(cornerRadius: 16, tint: .white.opacity(0.06), stroke: .white.opacity(0.14))
    }
}

struct LogsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showClearLogsConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ViewSectionHeader(title: "Logs", symbol: "list.bullet.clipboard.fill")
                Spacer()
                Button("Clear") { showClearLogsConfirm = true }
                    .alert("Clear All Logs?", isPresented: $showClearLogsConfirm) {
                        Button("Clear", role: .destructive) { app.logs.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("All log entries will be permanently removed.")
                    }
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.logs.fullLog(), forType: .string)
                }
                Toggle("Auto-scroll", isOn: $app.logs.autoScroll)
                    .toggleStyle(.switch)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(app.logs.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.contains("❌") ? .red : (line.contains("⚠️") ? .yellow : .green))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .glassCard(cornerRadius: 20, tint: .black.opacity(0.04), stroke: .white.opacity(0.16))
                .onChange(of: app.logs.lines.count) {
                    if app.logs.autoScroll, let last = app.logs.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var updater: AppUpdater
    @Binding var showToken: Bool
    @State private var clusterNodeNameDraft = ""
    @State private var leaderAddressDraft = ""
    @State private var listenPortDraft = ""
    @State private var clusterSharedSecretDraft = ""
    @State private var listenPortError: String? = nil
    @State private var primaryAddressError: String? = nil
    @State private var sharedSecretError: String? = nil
    @State private var showClearKeyConfirmation = false
    @State private var baselineSettings = GeneralSettingsSnapshot()

    private var currentSettingsSnapshot: GeneralSettingsSnapshot {
        GeneralSettingsSnapshot(
            token: app.settings.token,
            autoStart: app.settings.autoStart,
            clusterMode: app.settings.clusterMode,
            clusterNodeName: clusterNodeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            clusterLeaderAddress: leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            clusterListenPort: Int(listenPortDraft) ?? app.settings.clusterListenPort,
            clusterSharedSecret: clusterSharedSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != baselineSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewSectionHeader(title: "Settings", symbol: "gearshape.2.fill")

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsBlock(
                        title: "General",
                        symbol: "slider.horizontal.3",
                        subtitle: "Identity and startup behavior."
                    ) {
                        HStack {
                            Group {
                                if showToken {
                                    TextField("Bot Token", text: $app.settings.token)
                                } else {
                                    SecureField("Bot Token", text: $app.settings.token)
                                }
                            }
                            Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        }

                        HStack {
                            Button(role: .destructive) {
                                showClearKeyConfirmation = true
                            } label: {
                                Label("Clear API Key", systemImage: "key.slash.fill")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(app.settings.token.isEmpty || app.status == .stopped)
                            .confirmationDialog(
                                "Clear API Key?",
                                isPresented: $showClearKeyConfirmation,
                                titleVisibility: .visible
                            ) {
                                Button("Clear Key and Disconnect", role: .destructive) {
                                    Task { await app.clearAPIKey() }
                                }
                                Button("Cancel", role: .cancel) { }
                            } message: {
                                Text("This will disconnect the bot and remove the stored token. You will need to enter a new token to reconnect.")
                            }
                        }

                        Toggle("Auto Start", isOn: $app.settings.autoStart)
                    }
                    
                    settingsBlock(
                        title: "SwiftMesh",
                        symbol: "point.3.connected.trianglepath.dotted",
                        subtitle: "Cluster role and node connectivity."
                    ) {
                    // Worker mode is temporarily hidden pending UX redesign.
                    // The .worker case and all runtime code remain intact for future re-enable.
                    Picker("Mode", selection: $app.settings.clusterMode) {
                        ForEach(ClusterMode.allCases.filter { $0 != .worker }) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    if app.workerModeMigrated {
                        Label("Worker mode is temporarily unavailable. Mode switched to Standalone.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    TextField("Node Name", text: $clusterNodeNameDraft)

                    if app.settings.clusterMode == .worker || app.settings.clusterMode == .standby {
                        TextField("Primary Address", text: $leaderAddressDraft)
                            .help(app.settings.clusterMode == .standby
                                ? "Address of the Primary node to monitor for failover."
                                : "Address of the Primary node to register with.")
                            .onChange(of: leaderAddressDraft) { validatePrimaryAddress() }
                        if let err = primaryAddressError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }

                    if app.settings.clusterMode != .standalone {
                        TextField("Listen Port", text: $listenPortDraft, prompt: Text("38787"))
                            .help(app.settings.clusterMode == .standby
                                ? "Port to listen on after promotion to Primary."
                                : app.settings.clusterMode == .worker
                                    ? "Local port this Worker listens on."
                                    : "Port this node listens on for Workers.")
                            .onChange(of: listenPortDraft) { validateListenPort() }
                        if let err = listenPortError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }

                    if app.settings.clusterMode != .standalone {
                        SecureField("Cluster Shared Secret", text: $clusterSharedSecretDraft)
                            .onChange(of: clusterSharedSecretDraft) { validateSharedSecret() }
                        if let err = sharedSecretError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }

                    Text(app.settings.clusterMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cluster Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Refresh SwiftMesh Status") {
                                app.refreshClusterStatus()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text(app.settings.clusterMode == .worker ? app.clusterSnapshot.serverStatusText : app.clusterSnapshot.workerStatusText)
                        .font(.caption)
                        .foregroundStyle((app.clusterSnapshot.workerState == .connected || app.clusterSnapshot.serverState == .listening) ? .green : .secondary)
                    }

                    settingsBlock(
                        title: "Software Updates",
                        symbol: "arrow.triangle.2.circlepath",
                        subtitle: "Update channel and Sparkle status."
                    ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Update Channel")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            updateChannelOption(.stable)
                            updateChannelOption(.beta)
                        }
                    }

                    if updater.selectedChannel == .beta {
                        Label("Beta channel enabled. Updates will come from the beta appcast feed.", systemImage: "flask.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Button("Check for Updates...") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .disabled(!updater.canCheckForUpdates)

                    if !updater.isConfigured {
                        Text("Set `SUFeedURL` and `SUPublicEDKey` in the app target build settings to enable Sparkle updates.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            .onAppear {
                clusterNodeNameDraft = app.settings.clusterNodeName
                leaderAddressDraft = app.settings.clusterLeaderAddress
                listenPortDraft = "\(app.settings.clusterListenPort)"
                clusterSharedSecretDraft = app.settings.clusterSharedSecret
                validateAll()
                baselineSettings = currentSettingsSnapshot
            }
            .onChange(of: app.settings.clusterMode) { validateAll() }

            if app.settings.clusterMode == .worker {
                GroupBox("Cluster Controls") {
                    HStack {
                        Button("Test Connection") {
                            applyDraftsToSettings()
                            app.testWorkerLeaderConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.workerConnectionTestInProgress || !clusterConfigValid)

                        if app.workerConnectionTestInProgress {
                            ProgressView().controlSize(.small)
                        }
                    }

                    Text(app.workerConnectionTestStatus)
                        .font(.caption)
                        .foregroundStyle(
                            app.workerConnectionTestIsSuccess
                                ? .green
                                : (app.workerConnectionTestStatus == "Not tested" || app.workerConnectionTestInProgress
                                    ? .secondary
                                    : .red)
                        )

                    Divider()

                    HStack {
                        if app.isWorkerServiceRunning {
                            Button("Stop Worker") { app.stopBot() }
                                .buttonStyle(.bordered)
                                .tint(.secondary)
                        } else {
                            Button("Start Worker") {
                                applyDraftsToSettings()
                                Task { await app.startBot() }
                            }
                            .buttonStyle(GlassActionButtonStyle())
                            .disabled(!clusterConfigValid)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 16)
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges {
                StickySaveButton(
                    label: "Save Settings",
                    systemImage: "square.and.arrow.down.fill",
                    disabled: !clusterConfigValid
                ) {
                    validateAll()
                    guard clusterConfigValid else { return }
                    applyDraftsToSettings()
                    app.saveSettings()
                    clusterNodeNameDraft = app.settings.clusterNodeName
                    leaderAddressDraft = app.settings.clusterLeaderAddress
                    listenPortDraft = "\(app.settings.clusterListenPort)"
                    clusterSharedSecretDraft = app.settings.clusterSharedSecret
                    baselineSettings = currentSettingsSnapshot
                }
                .padding(.trailing, 22)
                .padding(.bottom, 18)
            }
        }
    }

    @ViewBuilder
    private func settingsBlock<Content: View>(
        title: String,
        symbol: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func updateChannelOption(_ channel: AppUpdater.UpdateChannel) -> some View {
        let isSelected = updater.selectedChannel == channel
        return Button {
            updater.setUpdateChannel(channel)
        } label: {
            Label(channel.label, systemImage: channel.symbolName)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(isSelected ? .ultraThinMaterial : .regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(isSelected ? 0.26 : 0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Validation

    private var clusterConfigValid: Bool {
        listenPortError == nil && primaryAddressError == nil && sharedSecretError == nil
    }

    private func validateAll() {
        validatePrimaryAddress()
        validateListenPort()
        validateSharedSecret()
    }

    private func validatePrimaryAddress() {
        guard app.settings.clusterMode == .worker || app.settings.clusterMode == .standby else {
            primaryAddressError = nil; return
        }
        primaryAddressError = leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Required for Worker and Fail Over modes."
            : nil
    }

    private func validateListenPort() {
        guard app.settings.clusterMode != .standalone else {
            listenPortError = nil; return
        }
        if let port = Int(listenPortDraft), (1024...65535).contains(port) {
            listenPortError = nil
        } else {
            listenPortError = "Must be a number between 1024 and 65535."
        }
    }

    private func validateSharedSecret() {
        guard app.settings.clusterMode == .worker || app.settings.clusterMode == .standby else {
            sharedSecretError = nil; return
        }
        sharedSecretError = clusterSharedSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Required for Worker and Fail Over modes."
            : nil
    }

    private func applyDraftsToSettings() {
        app.settings.clusterNodeName = clusterNodeNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.settings.clusterLeaderAddress = leaderAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.settings.clusterListenPort = Int(listenPortDraft) ?? 38787
        app.settings.clusterSharedSecret = clusterSharedSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AIBotsView: View {
    @EnvironmentObject var app: AppModel
    @State private var showAppleSettings = false
    @State private var showOllamaSettings = false
    @State private var showOpenAISettings = false
    @State private var baselineSettings = AIBotsSettingsSnapshot()

    private var hasUnsavedChanges: Bool {
        currentSettingsSnapshot != baselineSettings
    }

    private var currentSettingsSnapshot: AIBotsSettingsSnapshot {
        AIBotsSettingsSnapshot(
            localAIDMReplyEnabled: app.settings.localAIDMReplyEnabled,
            useAIInGuildChannels: app.settings.behavior.useAIInGuildChannels,
            allowDMs: app.settings.behavior.allowDMs,
            preferredAIProvider: app.settings.preferredAIProvider,
            ollamaBaseURL: app.settings.ollamaBaseURL,
            ollamaModel: app.settings.localAIModel,
            openAIEnabled: app.settings.openAIEnabled,
            openAIAPIKey: app.settings.openAIAPIKey,
            openAIModel: app.settings.openAIModel,
            openAIImageGenerationEnabled: app.settings.openAIImageGenerationEnabled,
            openAIImageModel: app.settings.openAIImageModel,
            openAIImageMonthlyLimitPerUser: app.settings.openAIImageMonthlyLimitPerUser,
            localAISystemPrompt: app.settings.localAISystemPrompt
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewSectionHeader(title: "AI Bots", symbol: "sparkles.rectangle.stack.fill")

                overviewCard
                MemoryOverviewView(viewModel: app.memoryViewModel)
                configurationCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if hasUnsavedChanges {
                StickySaveButton(label: "Save AI Settings", systemImage: "square.and.arrow.down.fill") {
                    app.saveSettings()
                    baselineSettings = currentSettingsSnapshot
                }
                .padding(.trailing, 22)
                .padding(.bottom, 18)
            }
        }
        .task {
            await app.refreshAIStatus()
            syncProviderSelectionFromPreference()
        }
        .onChange(of: app.settings.preferredAIProvider) { _, _ in
            syncProviderSelectionFromPreference()
            Task { await app.refreshAIStatus() }
            if app.settings.preferredAIProvider == .ollama {
                app.detectOllamaModel()
            }
        }
        .onChange(of: app.settings.ollamaBaseURL) { _, _ in
            Task { await app.refreshAIStatus() }
        }
        .onChange(of: app.settings.openAIAPIKey) { _, _ in
            Task { await app.refreshAIStatus() }
        }
        .onChange(of: app.settings.openAIEnabled) { _, _ in
            Task { await app.refreshAIStatus() }
        }
        .onAppear {
            baselineSettings = currentSettingsSnapshot
        }
    }

    private var overviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            diagnosticsStyleSectionHeader(title: "AI Engines", symbol: "sparkles")

            HStack(alignment: .top, spacing: 12) {
                providerIcon(imageName: "AIAppleLogo", fallbackSystemImage: "apple.intelligence")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Apple Intelligence")
                        .font(.headline.weight(.semibold))
                    Text("System-native engine")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusStack(isOnline: app.appleIntelligenceOnline, isPrimary: app.settings.preferredAIProvider == .apple)
            }
            DisclosureGroup("Apple Intelligence Settings", isExpanded: $showAppleSettings) {
                Text("Apple Intelligence uses on-device system capabilities and does not require API keys.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                providerIcon(imageName: "AIOllamaLogo", fallbackSystemImage: "server.rack")
                VStack(alignment: .leading, spacing: 6) {
                    Text("Ollama")
                        .font(.headline)
                    if let model = app.ollamaDetectedModel, !model.isEmpty {
                        Text("Active model: \(model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let host = app.settings.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !host.isEmpty {
                        Text("Server: \(host)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusStack(isOnline: app.ollamaOnline, isPrimary: app.settings.preferredAIProvider == .ollama)
            }
            DisclosureGroup("Ollama Settings", isExpanded: $showOllamaSettings) {
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
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }

            Divider()

            HStack(alignment: .top, spacing: 12) {
                providerIcon(imageName: "AIOpenAILogo", fallbackSystemImage: "brain.head.profile")
                VStack(alignment: .leading, spacing: 6) {
                    Text("OpenAI (ChatGPT)")
                        .font(.headline)
                    Text("Cloud API provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let model = app.settings.openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !model.isEmpty {
                        Text("Model: \(model)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let imageModel = app.settings.openAIImageModel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !imageModel.isEmpty {
                        Text("Image model: \(imageModel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                statusStack(isOnline: app.openAIOnline, isPrimary: app.settings.preferredAIProvider == .openAI)
            }
            DisclosureGroup("OpenAI Settings", isExpanded: $showOpenAISettings) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Enable OpenAI Provider", isOn: $app.settings.openAIEnabled)

                    SecureField("OpenAI API Key", text: $app.settings.openAIAPIKey)
                        .disabled(!app.settings.openAIEnabled)
                    TextField("OpenAI Chat Model", text: $app.settings.openAIModel)
                        .disabled(!app.settings.openAIEnabled)
                    Toggle("Enable OpenAI Image Generation", isOn: $app.settings.openAIImageGenerationEnabled)
                        .disabled(!app.settings.openAIEnabled)
                    TextField("OpenAI Image Model", text: $app.settings.openAIImageModel)
                        .disabled(!app.settings.openAIEnabled || !app.settings.openAIImageGenerationEnabled)
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
                    .disabled(!app.settings.openAIEnabled || !app.settings.openAIImageGenerationEnabled)
                }
                .padding(.top, 6)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    private var configurationCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            diagnosticsStyleSectionHeader(title: "Configuration", symbol: "slider.horizontal.3")

            VStack(alignment: .leading, spacing: 10) {
                diagnosticsStyleSectionHeader(title: "General", symbol: "switch.2")

                Toggle("Enable AI Replies", isOn: $app.settings.localAIDMReplyEnabled)
                Toggle("Use AI in Guild Text Channels", isOn: $app.settings.behavior.useAIInGuildChannels)
                Toggle("Allow Direct Messages", isOn: $app.settings.behavior.allowDMs)
                Picker("Primary AI Engine", selection: $app.settings.preferredAIProvider) {
                    ForEach(AIProviderPreference.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                diagnosticsStyleSectionHeader(title: "System Prompt", symbol: "text.bubble")
                TextField("System Prompt", text: $app.settings.localAISystemPrompt)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }

    @ViewBuilder
    private func providerIcon(imageName: String, fallbackSystemImage: String) -> some View {
        AIIconContainer {
            if Bundle.main.url(forResource: imageName, withExtension: "png") != nil {
                Image(imageName)
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

    private func statusRow(isOnline: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOnline ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isOnline ? "Online" : "Offline")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusStack(isOnline: Bool, isPrimary: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 8) {
            statusRow(isOnline: isOnline)
            Text(isPrimary ? "Primary" : "Fallback")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((isPrimary ? Color.accentColor : Color.white).opacity(0.14), in: Capsule())
                .foregroundStyle(isPrimary ? Color.accentColor : Color.secondary)
        }
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
    private func diagnosticsStyleSectionHeader(title: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline.weight(.semibold))
        }
    }
}

private struct AIBotsSettingsSnapshot: Equatable {
    var localAIDMReplyEnabled = false
    var useAIInGuildChannels = true
    var allowDMs = false
    var preferredAIProvider: AIProviderPreference = .apple
    var ollamaBaseURL = ""
    var ollamaModel = ""
    var openAIEnabled = true
    var openAIAPIKey = ""
    var openAIModel = ""
    var openAIImageGenerationEnabled = true
    var openAIImageModel = ""
    var openAIImageMonthlyLimitPerUser = 5
    var localAISystemPrompt = ""
}

private struct GeneralSettingsSnapshot: Equatable {
    var token = ""
    var autoStart = false
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterListenPort = 38787
    var clusterSharedSecret = ""
}

struct MemoryOverviewView: View {
    @ObservedObject var viewModel: MemoryViewModel
    @State private var showClearAllConfirm = false
    @State private var scopeToClear: MemoryScope? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text("Conversation Memory")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(viewModel.totalMessages) messages")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                Text("No channel memory yet. Messages will appear here as conversations are processed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 20, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
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
                .fill(.ultraThinMaterial)
            content
        }
        .frame(width: 44, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct StatusPill: View {
    let status: BotStatus

    private var color: Color {
        switch status {
        case .running: return .green
        case .connecting: return .orange
        case .reconnecting: return .yellow
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var detail: String = ""
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 18, tint: color.opacity(0.10), stroke: color.opacity(0.28))
    }
}

struct DashboardPanel<Content: View>: View {
    let title: String
    var actionTitle: String?
    @ViewBuilder let content: Content

    init(title: String, actionTitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.actionTitle = actionTitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let actionTitle {
                    Button(actionTitle) {}
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .glassCard(cornerRadius: 22, tint: .white.opacity(0.10), stroke: .white.opacity(0.20))
    }
}

struct PanelLine: View {
    let title: String
    let subtitle: String
    let tone: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
    }
}

struct VoicePresenceMemberRow: View {
    let member: VoiceMemberPresence
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let avatarURL {
                    AsyncImage(url: avatarURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Image(systemName: "person.crop.circle.fill")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(.secondary)
                                .padding(2)
                        }
                    }
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(2)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())

            Text(member.username)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text("Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }
}

struct PlaceholderPanelLine: View {
    let text: String

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .padding(.vertical, 4)
    }
}

private struct StickySaveButton: View {
    let label: String
    let systemImage: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(GlassActionButtonStyle())
        .disabled(disabled)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }
}

struct SwiftBotGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.11),
                        Color(red: 0.08, green: 0.12, blue: 0.17),
                        Color(red: 0.10, green: 0.09, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 520, height: 520)
                    .blur(radius: 80)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 480, height: 480)
                    .blur(radius: 75)
                    .offset(x: 220, y: 260)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.98, blue: 1.0),
                        Color(red: 0.89, green: 0.95, blue: 0.98),
                        Color(red: 0.96, green: 0.93, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 520, height: 520)
                    .blur(radius: 70)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.18))
                    .frame(width: 420, height: 420)
                    .blur(radius: 55)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 480, height: 480)
                    .blur(radius: 65)
                    .offset(x: 220, y: 260)
            }
        }
        .ignoresSafeArea()
    }
}

struct GlassActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thickMaterial))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.26 : 0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.1), radius: 10, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SwiftBotGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color
    let stroke: Color

    func body(content: Content) -> some View {
        content
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tint: Color = .white.opacity(0.10), stroke: Color = .white.opacity(0.18)) -> some View {
        modifier(SwiftBotGlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func sidebarProfileCard() -> some View {
        glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
    }
}
