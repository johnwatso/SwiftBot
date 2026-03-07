import AppKit
import SwiftUI

// MARK: - Onboarding gate

struct OnboardingGateView: View {
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
