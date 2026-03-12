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
        // Remote control path
        case remoteSetup, remoteTesting, remoteConfirmed, remoteFailed
    }

    @State private var step: Step = .choosePath
    @State private var tokenInput: String = ""
    @State private var showToken: Bool = false
    @State private var inviteURL: String? = nil
    @State private var inviteConfirmed: Bool = false
    @State private var isLoadingInviteURL: Bool = false
    @State private var inviteLoadFailed: Bool = false
    @State private var movesForward: Bool = true
    @State private var remoteAddressInput: String = ""
    @State private var remoteAccessTokenInput: String = ""
    @State private var showRemoteToken: Bool = false
    @StateObject private var remoteTester = RemoteControlService()

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
                    case .remoteSetup, .remoteTesting, .remoteConfirmed, .remoteFailed:
                        remoteFlow
                            .id("remoteFlow")
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
        .onAppear {
            tokenInput = app.settings.token
            remoteAddressInput = app.settings.remoteMode.primaryNodeAddress
            remoteAccessTokenInput = app.settings.remoteMode.accessToken
            remoteTester.updateConfiguration(app.settings.remoteMode)
        }
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
        case .remoteSetup:     return "Connect to a primary SwiftBot node over HTTPS."
        case .remoteTesting:   return "Testing the remote control connection…"
        case .remoteConfirmed: return "Remote control connection successful."
        case .remoteFailed:    return "SwiftBot could not authenticate with that primary node."
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
                app.settings.launchMode = .swiftMeshClusterNode
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

            Button {
                app.settings.launchMode = .remoteControl
                step = .remoteSetup
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.title2)
                    Text("Set Up Remote Control").font(.headline)
                    Text("Manage a primary SwiftBot node without running Discord locally.")
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
                        app.settings.launchMode = .standaloneBot
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

    // MARK: - Remote flow

    @ViewBuilder
    private var remoteFlow: some View {
        switch step {
        case .remoteSetup:
            remoteSetupFields
        case .remoteTesting:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Testing connection…").foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Testing remote connection, please wait")
        case .remoteConfirmed:
            VStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.title2)
                        .accessibilityHidden(true)
                    Text("Connected to \(remoteTester.status?.botUsername ?? "SwiftBot")")
                        .font(.body)
                }

                if let latency = remoteTester.lastLatencyMs {
                    Text("Round-trip latency \(latency.formatted(.number.precision(.fractionLength(0)))) ms")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button {
                    app.completeRemoteModeOnboarding(
                        primaryNodeAddress: remoteAddressInput,
                        accessToken: remoteAccessTokenInput
                    )
                } label: {
                    Label("Open Remote Dashboard", systemImage: "arrow.right.circle.fill")
                        .frame(minWidth: 220)
                }
                .onboardingGlassButton()
            }
        case .remoteFailed:
            VStack(spacing: 16) {
                if let error = remoteTester.lastError, !error.isEmpty {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }

                HStack(spacing: 12) {
                    Button { step = .remoteSetup } label: {
                        Label("Try Again", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button { step = .choosePath } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
            }
        default:
            EmptyView()
        }
    }

    private var remoteSetupFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("https://mybot.example.com", text: $remoteAddressInput)
                .onboardingTextFieldStyle()
                .frame(maxWidth: 560)

            HStack(spacing: 10) {
                Group {
                    if showRemoteToken {
                        TextField("Access Token", text: $remoteAccessTokenInput)
                    } else {
                        SecureField("Access Token", text: $remoteAccessTokenInput)
                    }
                }
                .onboardingTextFieldStyle()
                .font(.system(.body, design: .monospaced))

                Button {
                    showRemoteToken.toggle()
                } label: {
                    Image(systemName: showRemoteToken ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showRemoteToken ? "Hide access token" : "Show access token")
            }
            .frame(maxWidth: 560)

            if let error = remoteTester.lastError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(step == .remoteConfirmed ? Color.secondary : Color.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button { step = .choosePath } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    let config = RemoteModeSettings(
                        primaryNodeAddress: remoteAddressInput,
                        accessToken: remoteAccessTokenInput
                    )
                    remoteTester.updateConfiguration(config)
                    step = .remoteTesting

                    Task {
                        let ok = await remoteTester.testConnection()
                        step = ok ? .remoteConfirmed : .remoteFailed
                    }
                } label: {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minWidth: 220)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                .disabled(remoteAddressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || remoteAccessTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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
        case .remoteSetup: return 7
        case .remoteTesting: return 8
        case .remoteConfirmed, .remoteFailed: return 9
        }
    }
}

