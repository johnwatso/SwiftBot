import SwiftUI
import AppKit

/// Configuration for this Mac's SwiftMesh membership. Runtime health and
/// cluster diagnostics deliberately live on the adjacent Status tab.
struct MeshPreferencesView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showWorkerOffloadWarning = false
    @State private var useSeparateLeaderPort = false
    @State private var isAdvancedPortsExpanded = false
    @State private var showRotateSecretConfirm = false
    @State private var showSecretManagement = false
    @State private var showIdentitySheet = false
    @State private var showRuruRequired = false
    @State private var showRuruSetup = false

    private static let defaultListenPort = 38787

    private var shouldShowMeshSettings: Bool { app.settings.clusterMode != .standalone }
    private var canEditOffloadPolicy: Bool {
        app.runtimeClusterMode == .leader && !app.isFailoverManagedNode
    }

    private var leaderPortBinding: Binding<String> {
        Binding(
            get: { "\(app.settings.clusterLeaderPort)" },
            set: { value in
                let filtered = String(value.filter(\.isNumber).prefix(5))
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
            set: { value in
                let filtered = String(value.filter(\.isNumber).prefix(5))
                let port: Int
                if let parsed = Int(filtered), (1...65535).contains(parsed) {
                    port = parsed
                } else if filtered.isEmpty {
                    port = Self.defaultListenPort
                } else {
                    return
                }
                app.settings.clusterListenPort = port
                if !useSeparateLeaderPort { app.settings.clusterLeaderPort = port }
            }
        )
    }

    private var workerOffloadBinding: Binding<Bool> {
        Binding(
            get: { app.settings.clusterWorkerOffloadEnabled },
            set: { enabled in
                guard enabled != app.settings.clusterWorkerOffloadEnabled else { return }
                if enabled {
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

    private var clusterModeBinding: Binding<ClusterMode> {
        Binding(
            get: { app.settings.clusterMode },
            set: { next in
                let current = app.settings.clusterMode
                let hasRuru = MeshWitnessSettingsStore.load().isValid
                guard SwiftMeshProtectionState.allowsTransition(from: current, to: next, hasRuru: hasRuru) else {
                    showRuruRequired = true
                    return
                }
                app.settings.clusterMode = next
            }
        )
    }

    var body: some View {
        SettingsForm {
            thisMacSection

            if shouldShowMeshSettings {
                transportSection
                failoverSection
                MeshWitnessPreferencesSection(showSetup: $showRuruSetup)
                workSharingSection
            }
        }
        .onAppear {
            useSeparateLeaderPort = app.settings.clusterLeaderPort != app.settings.clusterListenPort
            isAdvancedPortsExpanded = useSeparateLeaderPort || app.settings.clusterListenPort != Self.defaultListenPort
        }
        .sheet(isPresented: $showIdentitySheet) {
            MeshNodeIdentitySheet(nodeID: app.meshLocalNodeID)
        }
        .sheet(isPresented: $showSecretManagement) {
            MeshSharedSecretSheet(
                secret: $app.settings.clusterSharedSecret,
                role: app.settings.clusterMode,
                onSave: { app.saveSettings() },
                onRotate: { showRotateSecretConfirm = true }
            )
        }
        .confirmationDialog("Rotate SwiftMesh shared secret?", isPresented: $showRotateSecretConfirm, titleVisibility: .visible) {
            Button("Rotate Secret", role: .destructive) { app.rotateSwiftMeshSharedSecret() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Connected nodes must be updated with the new transport secret before they can communicate with this Mac.")
        }
        .alert("Enable Work Sharing?", isPresented: $showWorkerOffloadWarning) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Work Sharing") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.clusterWorkerOffloadEnabled = true
                }
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("Paired Worker nodes can process supported tasks for the active Primary. Only the active Primary sends results to Discord.")
        }
        .alert("Set Up Ruru First", isPresented: $showRuruRequired) {
            Button("Set Up Ruru…") { showRuruSetup = true }
            Button("OK", role: .cancel) { }
        } message: {
            Text("New SwiftMesh deployments require an independent Ruru service. Set it up now, create a pairing code in Ruru, approve this Mac there, then choose a Primary or Fail Over role. A newly paired standby inherits the Ruru connection through protected SwiftMesh credential sync. Existing legacy peer deployments remain available until you migrate them deliberately.")
        }
    }

    private var thisMacSection: some View {
        Section {
            Picker("Configured Role", selection: clusterModeBinding) {
                ForEach(ClusterMode.selectableCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if shouldShowMeshSettings {
                LabeledContent("Node Name") {
                    TextField("Node Name", text: $app.settings.clusterNodeName, prompt: Text("SwiftBot Node"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 220)
                }

                if app.settings.clusterMode == .standby {
                    LabeledContent("Primary Host") {
                        TextField("Primary Host", text: $app.settings.clusterLeaderAddress, prompt: Text("primary.example.com"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 220)
                    }
                }

                ConsoleSettingRow(
                    title: "Node Identity",
                    symbol: "number",
                    subtitle: "View and copy this Mac’s stable node ID for Ruru."
                ) {
                    Button("Show…") { showIdentitySheet = true }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }

                ConsoleDisclosureRow(
                    title: "Advanced Network Settings",
                    symbol: "network",
                    subtitle: "Ports for multi-instance or NAT configurations.",
                    isExpanded: $isAdvancedPortsExpanded
                )
                if isAdvancedPortsExpanded { advancedPortRows }
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text(app.settings.clusterMode.description)
        }
    }

    private var transportSection: some View {
        Section {
            ConsoleSettingRow(
                title: "Transport Secret",
                symbol: "key.fill",
                subtitle: app.settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Not configured"
                    : "Stored securely in this Mac’s Keychain; used for existing node-to-node transport."
            ) {
                Button("Manage…") { showSecretManagement = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        } header: {
            Text("Node Transport")
        } footer: {
            Text("This secret authenticates the existing HTTP transport used for status, sync, and work sharing. Changing it requires updating connected nodes.")
        }
    }

    private var failoverSection: some View {
        Section {
            Toggle("Automatic Return Preference", isOn: $app.settings.clusterAutomaticHandbackEnabled)

            if app.settings.clusterAutomaticHandbackEnabled {
                Stepper(value: $app.settings.clusterAutoReclaimAfterHours, in: 0...72, step: 1) {
                    Text(app.settings.clusterAutoReclaimAfterHours == 0
                         ? "Preferred delay: 60 seconds of stable health and synchronisation"
                         : "Preferred delay: \(app.settings.clusterAutoReclaimAfterHours) hours of stable health and synchronisation")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Preferred Primary Return")
        } footer: {
            Text(autoReclaimFooter + " Scheduling is not active in this build. Use Request Takeover on the preferred Mac for coordinated return. This saved preference does not disable standby takeover.")
        }
        .opacity(canConfigureAutomaticRestore ? 1 : 0.62)
        .disabled(!canConfigureAutomaticRestore)
    }

    private var workSharingSection: some View {
        Section {
            Toggle("Allow Worker Nodes to Process Tasks", isOn: workerOffloadBinding)

            if app.settings.clusterWorkerOffloadEnabled {
                Toggle("AI replies", isOn: $app.settings.clusterOffloadAIReplies)
                Toggle("Wiki lookups", isOn: $app.settings.clusterOffloadWikiLookups)
            }
        } header: {
            Text("Work Sharing")
        } footer: {
            Text(workSharingFooter)
        }
        .disabled(!canEditOffloadPolicy)
        .opacity(canEditOffloadPolicy ? 1 : 0.62)
        .animation(.easeInOut(duration: 0.2), value: app.settings.clusterWorkerOffloadEnabled)
    }

    @ViewBuilder
    private var advancedPortRows: some View {
        LabeledContent("Mesh Port") {
            TextField("38787", text: listenPortBinding)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 120)
        }

        Toggle(isOn: $useSeparateLeaderPort) {
            Text("Use a different Primary port")
            Text("For a Primary listening on another port, such as a NAT port-forward.")
        }
        .onChange(of: useSeparateLeaderPort) { _, enabled in
            if !enabled { app.settings.clusterLeaderPort = app.settings.clusterListenPort }
        }

        if useSeparateLeaderPort {
            LabeledContent("Primary Port") {
                TextField("38787", text: leaderPortBinding)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 120)
            }
        }
    }

    private var canConfigureAutomaticRestore: Bool {
        app.settings.clusterMode == .leader
            || (app.settings.clusterMode == .standby && app.meshPrimaryPreference.status != .notConfigured)
    }

    private var autoReclaimFooter: String {
        let safety = " Coordinated return requires synchronisation, a handback from the current owner and a Ruru grant."
        switch app.meshPrimaryPreference.status {
        case .current where app.meshPrimaryPreference.policy?.preferredPrimaryNodeID != nil:
            let preferred = app.meshPrimaryPreference.policy?.preferredPrimaryNodeID == app.meshLocalNodeID
            return (preferred
                ? "Ruru currently prefers this Mac for Primary."
                : "Ruru currently prefers another Mac for Primary.") + safety
        case .checking, .unavailable:
            return "Ruru’s Preferred Primary is currently unknown. Standby takeover still requires a lease." + safety
        default:
            return "Ruru has no current Preferred Primary selection." + safety
        }
    }

    private var workSharingFooter: String {
        guard canEditOffloadPolicy else { return "Work Sharing is shared bot policy. Change it on the active Primary." }
        let available = app.clusterNodes.contains { $0.role == .worker && $0.status != .disconnected }
        return available
            ? "Distribute supported tasks to available Worker nodes."
            : "Distribute supported tasks to available Worker nodes. No Worker nodes are currently available."
    }

}
private struct MeshNodeIdentitySheet: View {
    @Environment(\.dismiss) private var dismiss
    let nodeID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("This Mac’s Node ID").font(.title2.weight(.semibold))
            Text("Ruru uses this stable ID to identify a preferred Primary. It is not a password.")
                .foregroundStyle(.secondary)
            Text(nodeID.isEmpty ? "Node identity is preparing…" : nodeID)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(nodeID, forType: .string)
                }
                .disabled(nodeID.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct MeshSharedSecretSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var secret: String
    let role: ClusterMode
    let onSave: () -> Void
    let onRotate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Manage Transport Secret").font(.title2.weight(.semibold))
            Text("The secret authenticates the existing node transport and is stored in this Mac’s Keychain.")
                .foregroundStyle(.secondary)
            SecretSettingsControl(
                secret: $secret,
                title: "Node Transport Secret",
                message: "Use the same secret on every node in your mesh.",
                replacementWarning: "Connected nodes must be updated with the new secret before they can communicate again.",
                allowsGeneration: true,
                isRequired: role != .leader,
                emptyLabel: "Not configured",
                onSave: onSave
            )
            if role == .leader {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rotate Shared Secret").font(.body.weight(.medium))
                        Text("Connected nodes will need the new secret.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Rotate…", role: .destructive, action: onRotate)
                }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 520)
    }
}
