import SwiftUI
import AppKit

struct MeshPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var showWorkerOffloadWarning = false
    @State private var showDiagnostics = false
    /// Disclosure for the rare case of a Primary on a different port than
    /// this node (two SwiftBots on the same machine, NAT port-forward, etc).
    /// Initialised from the saved values so a returning user with diverged
    /// ports sees the section already revealed.
    @State private var useSeparateLeaderPort: Bool = false
    @State private var isAdvancedPortsExpanded: Bool = false
    @State private var isCopyingJoinCode = false
    @State private var justCopiedJoinCode = false
    @State private var isApplyingJoinCode = false
    @State private var joinCodeFeedback: JoinCodeFeedback?
    @State private var showRotateSecretConfirm = false

    private struct JoinCodeFeedback: Equatable {
        let ok: Bool
        let message: String
    }

    private static let defaultListenPort = 38787

    private var leaderPortBinding: Binding<String> {
        Binding(
            get: { "\(app.settings.clusterLeaderPort)" },
            set: { newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(5))
                if let port = Int(filtered), (1...65535).contains(port) {
                    app.settings.clusterLeaderPort = port
                } else if filtered.isEmpty {
                    app.settings.clusterLeaderPort = Self.defaultListenPort
                }
            }
        )
    }

    private var listenPortBinding: Binding<String> {
        Binding(
            get: { "\(app.settings.clusterListenPort)" },
            set: { newValue in
                let filtered = String(newValue.filter(\.isNumber).prefix(5))
                let resolved: Int
                if let port = Int(filtered), (1...65535).contains(port) {
                    resolved = port
                } else if filtered.isEmpty {
                    resolved = Self.defaultListenPort
                } else {
                    return
                }
                app.settings.clusterListenPort = resolved
                // Mirror the leader port unless the user has explicitly opted
                // into a split (Advanced disclosure). 95% of users want both
                // ports equal.
                if !useSeparateLeaderPort {
                    app.settings.clusterLeaderPort = resolved
                }
            }
        )
    }

    private var hasInvalidPort: Bool {
        !(1...65535).contains(app.settings.clusterListenPort)
    }

    private var hasInvalidLeaderPort: Bool {
        app.settings.clusterMode == .standby && !(1...65535).contains(app.settings.clusterLeaderPort)
    }

    private var canEditOffloadPolicy: Bool {
        app.settings.clusterMode == .leader
    }

    private var shouldShowConfigurationDetails: Bool {
        // Any clustered role needs the node name / shared secret / port fields.
        // Standalone is the only mode with no cluster configuration to show.
        // (Previously excluded .leader, which also hid the Primary-only Join
        // Code and Auto-Reclaim sections, since those are gated on
        // `.leader && shouldShowConfigurationDetails`.)
        app.settings.clusterMode != .standalone
    }

    private var workerOffloadBinding: Binding<Bool> {
        Binding(
            get: { app.settings.clusterWorkerOffloadEnabled },
            set: { newValue in
                guard newValue != app.settings.clusterWorkerOffloadEnabled else { return }
                if newValue {
                    showWorkerOffloadWarning = true
                } else {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        app.settings.clusterWorkerOffloadEnabled = false
                        app.settings.clusterOffloadAIReplies = false
                        app.settings.clusterOffloadWikiLookups = false
                    }
                }
            }
        )
    }

    var body: some View {
        SettingsForm {
            // MARK: - Configuration

            Section {
                Picker("Role", selection: $app.settings.clusterMode) {
                    ForEach(ClusterMode.selectableCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                if shouldShowConfigurationDetails {
                    LabeledContent("Node Name") {
                        TextField("Node Name", text: $app.settings.clusterNodeName, prompt: Text("SwiftBot Node"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }

                    if app.settings.clusterMode == .standby {
                        LabeledContent("Primary Host") {
                            TextField("Primary Host", text: $app.settings.clusterLeaderAddress, prompt: Text("192.168.1.100"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 220)
                        }
                    }

                    LabeledContent("Shared Secret") {
                        SecretSettingsControl(
                            secret: $app.settings.clusterSharedSecret,
                            title: "SwiftMesh Shared Secret",
                            message: "Use the same secret on every node in your mesh. It is stored in your macOS Keychain.",
                            replacementWarning: "Replacing the secret invalidates existing Join Codes. Connected nodes must use the new secret to reconnect.",
                            allowsGeneration: true,
                            // A Primary creates the secret with its first Join Code.
                            isRequired: app.settings.clusterMode != .leader,
                            emptyLabel: app.settings.clusterMode == .leader ? "Created with Join Code" : "Not configured",
                            onSave: { app.saveSettings() }
                        )
                    }

                    if app.settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label {
                            Text(app.settings.clusterMode == .leader
                                 ? "Mesh requests are blocked until a shared secret is configured. Generate a Join Code below or add a shared secret."
                                 : "Mesh requests are blocked until a shared secret is configured. Paste the Primary’s Join Code below or add the same shared secret as the Primary.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                        }
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    // Port overrides, collapsed by default: the Join Code
                    // fills these in, so they only matter for multi-instance,
                    // NAT port-forward, or split inbound/outbound setups.
                    ConsoleDisclosureRow(
                        title: "Advanced Ports",
                        subtitle: "Only for multiple instances or NAT setups.",
                        isExpanded: $isAdvancedPortsExpanded
                    )
                    if isAdvancedPortsExpanded {
                        advancedPortRows
                    }
                }
            } header: {
                Label("Configuration", systemImage: "network")
            } footer: {
                Text(app.settings.clusterMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Join via Join Code (Standby only)
            // Mirrors the onboarding paste-and-verify flow so a returning
            // operator on a failover/standby node can re-pair with the
            // Primary without manually retyping host, port, and secret.

            if app.settings.clusterMode == .standby {
                Section {
                    ConsoleSettingRow(
                        title: "Join Code",
                        symbol: "doc.on.clipboard",
                        subtitle: joinCodeFeedback == nil ? "Paste the Join Code copied on the Primary to fill in its host, port, and secret." : nil,
                        status: joinCodeFeedback.map { ($0.message, $0.ok ? ServiceHealth.healthy : .error) }
                    ) {
                        Button {
                            Task { await pasteAndVerifyJoinCode() }
                        } label: {
                            if isApplyingJoinCode {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Paste & Verify")
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(isApplyingJoinCode)
                    }
                } header: {
                    Label("Join Code", systemImage: "doc.on.clipboard")
                }
            }

            // MARK: - Join Code (Leader only)

            if app.settings.clusterMode == .leader && shouldShowConfigurationDetails {
                Section {
                    ConsoleSettingRow(
                        title: "Join Code",
                        symbol: "doc.on.clipboard",
                        subtitle: "Pair Fail Over and Worker nodes without typing hosts, ports, or secrets."
                    ) {
                        Button(isCopyingJoinCode ? "Generating…" : justCopiedJoinCode ? "Copied" : "Copy Join Code") {
                            copyJoinCode()
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .disabled(isCopyingJoinCode)
                    }

                    ConsoleSettingRow(
                        title: "Rotate Shared Secret",
                        symbol: "arrow.triangle.2.circlepath",
                        subtitle: "Existing Join Codes stop working; connected nodes must re-pair."
                    ) {
                        Button("Rotate…", role: .destructive) { rotateSharedSecret() }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .disabled(isCopyingJoinCode)
                    }
                } header: {
                    Label("Pairing", systemImage: "doc.on.clipboard")
                }
            }

            // MARK: - Auto-Reclaim (Leader only)

            if app.settings.clusterMode == .leader && shouldShowConfigurationDetails {
                Section {
                    Toggle(
                        "Reclaim Primary automatically after failover",
                        isOn: $app.settings.clusterAutomaticHandbackEnabled
                    )

                    if app.settings.clusterAutomaticHandbackEnabled {
                        Stepper(
                            value: $app.settings.clusterAutoReclaimAfterHours,
                            in: 0...72,
                            step: 1
                        ) {
                            Text(app.settings.clusterAutoReclaimAfterHours == 0
                                 ? "After 60 seconds of stable health and catchup"
                                 : "After \(app.settings.clusterAutoReclaimAfterHours) hours of stable health and catchup")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Label("Auto-Reclaim", systemImage: "arrow.uturn.up.circle")
                } footer: {
                    Text("""
                    Return this Mac to Primary after stable health and catchup. Leave off to keep the current owner. \
                    Manual promotion also checks state and ownership.
                    """)
                }
            }

            if shouldShowConfigurationDetails {
                MeshRecoveryPreferencesSection()
            }

            // MARK: - Worker Offload

            if shouldShowConfigurationDetails {
                Section {
                    Toggle("Enable Worker Offload", isOn: workerOffloadBinding)

                    if app.settings.clusterWorkerOffloadEnabled {
                        Toggle("Offload AI replies to workers when Primary", isOn: $app.settings.clusterOffloadAIReplies)
                        Toggle("Offload Wiki lookups to workers when Primary", isOn: $app.settings.clusterOffloadWikiLookups)
                    }
                } header: {
                    Label("Worker Offload", systemImage: "point.3.connected.trianglepath.dotted")
                } footer: {
                    Text("Let Worker nodes handle some work for the Primary.")
                }
                .disabled(!canEditOffloadPolicy)
                .opacity(canEditOffloadPolicy ? 1 : 0.62)
                .animation(.easeInOut(duration: 0.2), value: app.settings.clusterWorkerOffloadEnabled)
                .alert("Enable Worker Offload?", isPresented: $showWorkerOffloadWarning) {
                    Button("Cancel", role: .cancel) {}
                    Button("Enable Worker Offload") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            app.settings.clusterWorkerOffloadEnabled = true
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                } message: {
                    Text(
                        """
                        Paired standby nodes can compute AI replies, Wiki lookups, and playlist imports for the active Primary. Only the active Primary sends the result to Discord.

                        Tasks use saved job IDs and deadlines. Workers fetch tasks through an outbound connection, so no inbound port forwarding is required.
                        """
                    )
                }
            }

            // MARK: - Cluster Status (Standby only)

            if app.settings.clusterMode == .standby {
                Section {
                    if app.workerConnectionTestInProgress {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Testing connection…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: app.workerConnectionTestIsSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(app.workerConnectionTestIsSuccess ? .green : .secondary)
                                .font(.title3)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.workerConnectionTestIsSuccess ? "Connected to Leader" : "Not Connected")
                                    .font(.subheadline.weight(.medium))

                                if app.workerConnectionTestIsSuccess,
                                   let nodeName = app.workerConnectionTestOutcome?.nodeName,
                                   !nodeName.isEmpty {
                                    Text(nodeName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                let host = app.settings.clusterLeaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !host.isEmpty {
                                    Text("\(host):\(app.settings.clusterLeaderPort)")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }

                                if app.workerConnectionTestIsSuccess,
                                   let rawMs = app.workerConnectionTestOutcome?.latencyMs {
                                    let ms = Int(rawMs)
                                    HStack(spacing: 4) {
                                        Text("Latency: \(ms) ms")
                                        Text("·")
                                        Text(latencyLabel(ms))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(latencyColor(ms))
                                }

                                if let checkedAt = app.lastClusterStatusRefreshAt {
                                    Text("Last checked: \(checkedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        // Diagnostics disclosure
                        if !app.workerConnectionTestStatus.isEmpty,
                           app.workerConnectionTestStatus != "Not tested" {
                            DisclosureGroup(isExpanded: $showDiagnostics) {
                                Text(app.workerConnectionTestStatus)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .padding(.top, 4)
                            } label: {
                                Text("Connection Details")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .animation(.easeInOut(duration: 0.2), value: showDiagnostics)
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Test Connection") {
                            app.testWorkerLeaderConnection(
                                leaderAddress: app.settings.clusterLeaderAddress,
                                leaderPort: app.settings.clusterLeaderPort
                            )
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.workerConnectionTestInProgress)

                        Button("Check Status") {
                            app.refreshClusterStatus()
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.workerConnectionTestInProgress)
                    }
                } header: {
                    Label("Cluster Status", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            // Reveal advanced ports when saved values diverge from defaults
            // or each other — i.e. the user has clearly customised them.
            useSeparateLeaderPort = app.settings.clusterLeaderPort != app.settings.clusterListenPort
            isAdvancedPortsExpanded = useSeparateLeaderPort
                || app.settings.clusterListenPort != Self.defaultListenPort
        }
        .confirmationDialog(
            "Rotate SwiftMesh shared secret?",
            isPresented: $showRotateSecretConfirm,
            titleVisibility: .visible
        ) {
            Button("Rotate Secret", role: .destructive) {
                app.rotateSwiftMeshSharedSecret()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any Join Codes already shared will stop working and connected workers will need to re-pair using a new code.")
        }
    }

    @ViewBuilder
    private var advancedPortRows: some View {
        LabeledContent("Mesh Port") {
            VStack(alignment: .trailing, spacing: 4) {
                TextField("38787", text: listenPortBinding)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
                if hasInvalidPort {
                    Text("Port must be between 1 and 65535.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }

        Toggle(isOn: $useSeparateLeaderPort) {
            Text("Use a different outbound port")
            Text("When the Primary listens on another port, such as two instances on one Mac or a NAT port-forward.")
        }
        .onChange(of: useSeparateLeaderPort) { _, isOn in
            if !isOn {
                app.settings.clusterLeaderPort = app.settings.clusterListenPort
            }
        }

        if useSeparateLeaderPort {
            LabeledContent("Leader Port") {
                VStack(alignment: .trailing, spacing: 4) {
                    TextField("38787", text: leaderPortBinding)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 120)
                    if hasInvalidLeaderPort {
                        Text("Leader Port must be between 1 and 65535.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func copyJoinCode() {
        isCopyingJoinCode = true
        Task {
            if let code = await app.generateSwiftMeshJoinCode() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                app.logs.append("[SwiftMesh] Join code copied to clipboard!")
                justCopiedJoinCode = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                justCopiedJoinCode = false
            }
            isCopyingJoinCode = false
        }
    }

    private func rotateSharedSecret() {
        showRotateSecretConfirm = true
    }

    @MainActor
    private func pasteAndVerifyJoinCode() async {
        guard !isApplyingJoinCode else { return }
        joinCodeFeedback = nil

        let raw = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            joinCodeFeedback = JoinCodeFeedback(ok: false, message: "Clipboard is empty. Copy the SwiftMesh Join Code from the Primary node first.")
            return
        }
        guard raw.contains("swiftmesh://join") || raw.count > 50 else {
            joinCodeFeedback = JoinCodeFeedback(ok: false, message: "That doesn't look like a SwiftMesh Join Code.")
            return
        }

        isApplyingJoinCode = true
        defer { isApplyingJoinCode = false }

        do {
            let decoded = try app.decodeSwiftMeshJoinCode(raw)
            let applied = await app.applySwiftMeshJoinCode(raw)
            guard applied.ok else {
                joinCodeFeedback = JoinCodeFeedback(ok: false, message: applied.message)
                return
            }
            let reachable = await app.testWorkerJoinCodeConnection(
                addresses: decoded.leaderAddresses,
                port: decoded.leaderPort
            )
            joinCodeFeedback = JoinCodeFeedback(
                ok: reachable,
                message: reachable
                    ? "Join Code accepted and connection verified."
                    : "Settings saved, but the Primary node didn't respond. Check that it's running and reachable."
            )
        } catch {
            joinCodeFeedback = JoinCodeFeedback(ok: false, message: error.localizedDescription)
        }
    }

    private func latencyLabel(_ ms: Int) -> String {
        switch ms {
        case ..<20: return "Excellent"
        case 20..<80: return "Good"
        case 80..<200: return "Slow"
        default: return "Poor"
        }
    }

    private func latencyColor(_ ms: Int) -> Color {
        switch ms {
        case ..<20: return .green
        case 20..<80: return .secondary
        case 80..<200: return .orange
        default: return .red
        }
    }
}
