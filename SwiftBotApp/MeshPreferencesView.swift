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

                TextField(
                    "Node Name",
                    text: $app.settings.clusterNodeName,
                    prompt: Text("SwiftBot Node")
                )

                if app.settings.clusterMode == .standby {
                    TextField(
                        "Primary Host",
                        text: $app.settings.clusterLeaderAddress,
                        prompt: Text("192.168.1.100")
                    )
                }

                LabeledContent("Shared Secret") {
                    RevealableSecretField(
                        text: $app.settings.clusterSharedSecret,
                        placeholder: "Required for clustered mode",
                        allowRegenerate: true
                    )
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
                    Button {
                        Task { await pasteAndVerifyJoinCode() }
                    } label: {
                        HStack(spacing: 6) {
                            if isApplyingJoinCode {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "doc.on.clipboard")
                            }
                            Text(isApplyingJoinCode ? "Verifying…" : "Paste & Verify Join Code")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isApplyingJoinCode)

                    if let joinCodeFeedback {
                        Text(joinCodeFeedback.message)
                            .font(.caption)
                            .foregroundStyle(joinCodeFeedback.ok ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Label("Join Code", systemImage: "doc.on.clipboard")
                } footer: {
                    Text("Copy the Join Code from the Primary node and paste it here to fill in the host, port, and shared secret automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Advanced — port overrides. Collapsed by default because the
            // Join Code flow pre-fills everything correctly; only needed for
            // multi-instance, NAT port-forward, or split inbound/outbound
            // setups.
            Section {
                DisclosureGroup(isExpanded: $isAdvancedPortsExpanded) {
                    LabeledContent("Mesh Port") {
                        VStack(alignment: .trailing, spacing: 4) {
                            TextField("38787", text: listenPortBinding)
                                .textFieldStyle(.roundedBorder)
                                .labelsHidden()
                                .frame(width: 120)
                            if hasInvalidPort {
                                Text("Port must be between 1 and 65535.")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Toggle("Use a different outbound port", isOn: $useSeparateLeaderPort)
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
                                    .frame(width: 120)
                                if hasInvalidLeaderPort {
                                    Text("Leader Port must be between 1 and 65535.")
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        SettingsSecondaryText("Use when the Primary listens on a different port than this node (two SwiftBot instances on the same machine, or a NAT port-forward).")
                    }
                } label: {
                    Text("Advanced Ports")
                        .font(.subheadline.weight(.medium))
                }
            } footer: {
                Text("The Join Code on the Primary node fills these in automatically — you only need to touch them for multi-instance or NAT setups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // MARK: - Join Code (Leader only)

            if app.settings.clusterMode == .leader {
                Section {
                    Button {
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
                    } label: {
                        if isCopyingJoinCode {
                            Label("Generating Join Code…", systemImage: "arrow.clockwise")
                        } else if justCopiedJoinCode {
                            Label("Join Code Copied!", systemImage: "checkmark.circle.fill")
                        } else {
                            Label("Copy SwiftMesh Join Code", systemImage: "doc.on.clipboard.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCopyingJoinCode)

                    Button(role: .destructive) {
                        rotateSharedSecret()
                    } label: {
                        Label("Rotate Shared Secret", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isCopyingJoinCode)
                } header: {
                    Label("SwiftMesh Join Code", systemImage: "doc.on.clipboard")
                } footer: {
                    Text("Share this Join Code with standby or worker nodes to pair them automatically without typing hosts, ports, or secrets manually. Rotating the shared secret invalidates any Join Codes already in circulation — connected workers will need to re-pair.")
                }
            }

            // MARK: - Auto-Reclaim (Leader only)

            if app.settings.clusterMode == .leader {
                Section {
                    Toggle(
                        "Reclaim Primary automatically after failover",
                        isOn: Binding(
                            get: { app.settings.clusterAutoReclaimAfterHours > 0 },
                            set: { app.settings.clusterAutoReclaimAfterHours = $0 ? max(1, app.settings.clusterAutoReclaimAfterHours == 0 ? 6 : app.settings.clusterAutoReclaimAfterHours) : 0 }
                        )
                    )

                    if app.settings.clusterAutoReclaimAfterHours > 0 {
                        Stepper(
                            value: $app.settings.clusterAutoReclaimAfterHours,
                            in: 1...72,
                            step: 1
                        ) {
                            Text("After \(app.settings.clusterAutoReclaimAfterHours) hour\(app.settings.clusterAutoReclaimAfterHours == 1 ? "" : "s") of uninterrupted standby health")
                                .font(.subheadline)
                        }
                    }
                } header: {
                    Label("Auto-Reclaim (Advanced)", systemImage: "arrow.uturn.up.circle")
                } footer: {
                    Text(
                        "**Off by default.** When this Primary fails over and later rejoins as Standby, auto-reclaim swings it back to "
                        + "Primary after a healthy window. That's convenient but assumes this node is always the canonical Primary — if "
                        + "you'd rather have the cluster stay on whichever node took over, leave this off and use **Promote to Primary** "
                        + "when you actually want to swap back. Manual promotion always works regardless."
                    )
                }
            }

            // MARK: - Worker Offload

            Section {
                Toggle("Enable Worker Offload", isOn: workerOffloadBinding)

                if app.settings.clusterWorkerOffloadEnabled {
                    Toggle("Offload AI replies to workers when Primary", isOn: $app.settings.clusterOffloadAIReplies)
                    Toggle("Offload Wiki lookups to workers when Primary", isOn: $app.settings.clusterOffloadWikiLookups)
                }
            } header: {
                Label("Worker Offload", systemImage: "point.3.connected.trianglepath.dotted")
            } footer: {
                Text("Allow SwiftBot to distribute certain workloads to worker nodes in the SwiftMesh cluster.")
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
                    Enabling Worker Offload allows SwiftBot to distribute certain responses to worker nodes.

                    Worker nodes will use the same Discord API token as the primary bot instance. Running multiple bot processes with the same token may cause duplicate responses or rate-limit conflicts.

                    Discord recommends operating a single active bot connection per token. This feature should only be enabled in advanced or controlled environments.
                    """
                )
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
            let applied = app.applySwiftMeshJoinCode(raw)
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
