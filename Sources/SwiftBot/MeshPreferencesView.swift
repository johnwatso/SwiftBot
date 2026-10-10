import SwiftUI
import AppKit

/// Configuration for this Mac's SwiftMesh membership. Runtime health and
/// cluster diagnostics deliberately live on the adjacent Status tab.
struct MeshPreferencesView: View {
    @EnvironmentObject private var app: AppModel
    @State private var showWorkerOffloadWarning = false
    @State private var useSeparateLeaderPort = false
    @State private var isAdvancedPortsExpanded = false
    @State private var isCopyingJoinCode = false
    @State private var justCopiedJoinCode = false
    @State private var isApplyingJoinCode = false
    @State private var joinCodeFeedback: JoinCodeFeedback?
    @State private var showRotateSecretConfirm = false
    @State private var showPairingSheet = false
    @State private var showSecretManagement = false
    @State private var showIdentitySheet = false
    @State private var showNodeManager = false
    @State private var managedNodeID: String?
    @State private var credentialGrants: [MeshCredentialGrant] = []

    private struct JoinCodeFeedback: Equatable {
        let ok: Bool
        let message: String
    }

    private static let defaultListenPort = 38787

    private var shouldShowMeshSettings: Bool { app.settings.clusterMode != .standalone }
    private var canEditOffloadPolicy: Bool { app.settings.clusterMode == .leader }
    private var canManageCredentials: Bool { app.runtimeClusterMode == .leader }
    private var pairedGrants: [MeshCredentialGrant] {
        credentialGrants.filter { $0.nodeID != app.meshLocalNodeID }
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

    var body: some View {
        SettingsForm {
            thisMacSection

            if shouldShowMeshSettings {
                pairedNodesSection
                pairingSection
                failoverSection
                MeshWitnessPreferencesSection()
                workSharingSection
            }
        }
        .onAppear {
            useSeparateLeaderPort = app.settings.clusterLeaderPort != app.settings.clusterListenPort
            isAdvancedPortsExpanded = useSeparateLeaderPort || app.settings.clusterListenPort != Self.defaultListenPort
        }
        .task { await refreshCredentialGrants() }
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
        .sheet(isPresented: $showPairingSheet) {
            MeshJoinCodeSheet(isCopying: $isCopyingJoinCode, justCopied: $justCopiedJoinCode) { nodeName in
                copyJoinCode(for: nodeName)
            }
        }
        .sheet(isPresented: $showNodeManager) {
            if let grant = pairedGrants.first(where: { $0.nodeID == managedNodeID }) {
                MeshPairedNodeSheet(
                    grant: grant,
                    node: runtimeNode(for: grant),
                    canRevoke: canManageCredentials,
                    onRevoke: { await revokeCredential(for: grant) }
                )
            }
        }
        .confirmationDialog("Rotate SwiftMesh shared secret?", isPresented: $showRotateSecretConfirm, titleVisibility: .visible) {
            Button("Rotate Secret", role: .destructive) { app.rotateSwiftMeshSharedSecret() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any Join Codes already shared will stop working and connected nodes will need to re-pair using a new code.")
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
    }

    private var thisMacSection: some View {
        Section {
            Picker("Configured Role", selection: $app.settings.clusterMode) {
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

    private var pairedNodesSection: some View {
        Section {
            if pairedGrants.isEmpty {
                ConsoleSettingRow(
                    title: "No Paired Nodes",
                    symbol: "desktopcomputer.trianglebadge.exclamationmark",
                    subtitle: "Copy a Join Code to pair another Mac."
                )
            } else {
                ForEach(pairedGrants, id: \.nodeID) { grant in
                    let node = runtimeNode(for: grant)
                    ConsoleSettingRow(
                        title: displayedName(for: grant),
                        symbol: "desktopcomputer",
                        subtitle: node.map { "\($0.role.displayName) · \($0.connectionStatusText)" }
                            ?? "Credential access approved"
                    ) {
                        Button("Manage…") {
                            managedNodeID = grant.nodeID
                            showNodeManager = true
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
            }
        } header: {
            Text("Paired Nodes")
        } footer: {
            Text("Each paired node has its own credential approval. Connection details and cluster diagnostics are available in Status.")
        }
    }

    private var pairingSection: some View {
        Section {
            if app.settings.clusterMode == .standby {
                ConsoleSettingRow(
                    title: "Join Code",
                    symbol: "doc.on.clipboard",
                    subtitle: joinCodeFeedback == nil ? "Paste the code copied on the Primary to configure this Mac." : nil,
                    status: joinCodeFeedback.map { ($0.message, $0.ok ? .healthy : .error) }
                ) {
                    Button(isApplyingJoinCode ? "Checking…" : "Paste & Verify") {
                        Task { await pasteAndVerifyJoinCode() }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(isApplyingJoinCode)
                }
            } else if app.settings.clusterMode == .leader {
                ConsoleSettingRow(
                    title: "Join Code",
                    symbol: "doc.on.clipboard",
                    subtitle: "Copy a code to configure a named Fail Over or Worker Mac."
                ) {
                    Button("Copy Join Code…") { showPairingSheet = true }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                }
            }

            ConsoleSettingRow(
                title: "Shared Secret",
                symbol: "key.fill",
                subtitle: app.settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Not configured"
                    : "Stored securely in this Mac’s Keychain."
            ) {
                Button("Manage…") { showSecretManagement = true }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        } header: {
            Text("Pairing")
        } footer: {
            Text("Join Codes carry the connection details and a unique credential approval. Rotating the shared secret requires every connected node to re-pair.")
        }
    }

    private var failoverSection: some View {
        Section {
            Toggle("Automatically Restore Preferred Primary", isOn: $app.settings.clusterAutomaticHandbackEnabled)

            if app.settings.clusterAutomaticHandbackEnabled {
                Stepper(value: $app.settings.clusterAutoReclaimAfterHours, in: 0...72, step: 1) {
                    Text(app.settings.clusterAutoReclaimAfterHours == 0
                         ? "Restore after 60 seconds of stable health and synchronisation"
                         : "Restore after \(app.settings.clusterAutoReclaimAfterHours) hours of stable health and synchronisation")
                        .font(.subheadline)
                }
            }
        } header: {
            Text("Failover")
        } footer: {
            Text(autoReclaimFooter)
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
        let safety = " SwiftMesh still checks ownership, state synchronisation, and a valid handback before changing the Primary."
        switch app.meshPrimaryPreference.status {
        case .current where app.meshPrimaryPreference.policy?.preferredPrimaryNodeID != nil:
            let preferred = app.meshPrimaryPreference.policy?.preferredPrimaryNodeID == app.meshLocalNodeID
            return (preferred
                ? "Once this Mac is healthy and synchronised, it can automatically resume the Primary role."
                : "Ruru currently prefers another Mac, so this Mac will not restore Primary automatically.") + safety
        case .checking, .unavailable:
            return "Automatic restore waits until Ruru’s Preferred Primary is known. Failover monitoring continues." + safety
        default:
            return "Once this Mac is healthy and synchronised, it can automatically resume the Primary role." + safety
        }
    }

    private var workSharingFooter: String {
        let available = app.clusterNodes.contains { $0.role == .worker && $0.status != .disconnected }
        return available
            ? "Distribute supported tasks to available Worker nodes."
            : "Distribute supported tasks to available Worker nodes. No Worker nodes are currently available."
    }

    private func displayedName(for grant: MeshCredentialGrant) -> String {
        let name = grant.nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "Paired Failover" ? "Paired Node" : name
    }

    private func runtimeNode(for grant: MeshCredentialGrant) -> ClusterNodeStatus? {
        app.clusterNodes.first {
            $0.displayName.caseInsensitiveCompare(grant.nodeName) == .orderedSame
                && $0.role != .leader
        }
    }

    @MainActor
    private func refreshCredentialGrants() async {
        credentialGrants = await app.meshCredentialStore.allGrants()
    }

    private func copyJoinCode(for nodeName: String) {
        isCopyingJoinCode = true
        Task {
            if let code = await app.generateSwiftMeshJoinCode(nodeName: nodeName) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                app.logs.append("[SwiftMesh] Join code copied to clipboard for \(nodeName).")
                await refreshCredentialGrants()
                justCopiedJoinCode = true
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                justCopiedJoinCode = false
            }
            isCopyingJoinCode = false
        }
    }

    @MainActor
    private func pasteAndVerifyJoinCode() async {
        guard !isApplyingJoinCode else { return }
        joinCodeFeedback = nil
        let code = (NSPasteboard.general.string(forType: .string) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            joinCodeFeedback = .init(ok: false, message: "Clipboard is empty. Copy the Join Code on the Primary first.")
            return
        }
        guard code.contains("swiftmesh://join") || code.count > 50 else {
            joinCodeFeedback = .init(ok: false, message: "That doesn’t look like a SwiftMesh Join Code.")
            return
        }

        isApplyingJoinCode = true
        defer { isApplyingJoinCode = false }
        let result = await app.pairSwiftMeshFailover(code)
        joinCodeFeedback = .init(ok: result.ok, message: result.message)
    }

    @MainActor
    private func revokeCredential(for grant: MeshCredentialGrant) async {
        do {
            try await app.meshCredentialStore.revoke(nodeID: grant.nodeID)
            await refreshCredentialGrants()
            showNodeManager = false
        } catch {
            app.logs.append("SwiftMesh could not revoke credential access: \(error.localizedDescription)")
        }
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
            Text("Manage Shared Secret").font(.title2.weight(.semibold))
            Text("The shared secret authenticates mesh traffic and is stored in this Mac’s Keychain.")
                .foregroundStyle(.secondary)
            SecretSettingsControl(
                secret: $secret,
                title: "SwiftMesh Shared Secret",
                message: "Use the same secret on every node in your mesh.",
                replacementWarning: "Replacing the secret invalidates existing Join Codes. Connected nodes must use the new secret to reconnect.",
                allowsGeneration: true,
                isRequired: role != .leader,
                emptyLabel: role == .leader ? "Created with Join Code" : "Not configured",
                onSave: onSave
            )
            if role == .leader {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rotate Shared Secret").font(.body.weight(.medium))
                        Text("Connected nodes will need to re-pair.").font(.callout).foregroundStyle(.secondary)
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

private struct MeshJoinCodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isCopying: Bool
    @Binding var justCopied: Bool
    let onCopy: (String) -> Void
    @State private var nodeName = ""

    private var trimmedName: String { nodeName.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Pair Another Mac").font(.title2.weight(.semibold))
            Text("Name the Mac you are pairing so it remains recognisable in Paired Nodes. The Join Code is copied to the clipboard.")
                .foregroundStyle(.secondary)
            TextField("Mac name", text: $nodeName, prompt: Text("Studio Mac"))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(isCopying ? "Copying…" : justCopied ? "Copied" : "Copy Join Code") {
                    onCopy(trimmedName)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || isCopying)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: justCopied) { _, copied in if copied { dismiss() } }
    }
}

private struct MeshPairedNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let grant: MeshCredentialGrant
    let node: ClusterNodeStatus?
    let canRevoke: Bool
    let onRevoke: () async -> Void
    @State private var showRevokeConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(node?.displayName ?? (grant.nodeName == "Paired Failover" ? "Paired Node" : grant.nodeName))
                .font(.title2.weight(.semibold))
            Form {
                LabeledContent("Configured Role", value: node?.role.displayName ?? "Not reported")
                LabeledContent("Connection", value: node?.connectionStatusText ?? "Not currently reported")
                LabeledContent("Credential Access", value: "Approved")
                LabeledContent("Node ID") {
                    Text(grant.nodeID).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if canRevoke {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Credential Access").font(.body.weight(.medium))
                        Text("Revoking blocks future credential fetches. It does not erase credentials this Mac has already received or remove its network settings.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revoke…", role: .destructive) { showRevokeConfirmation = true }
                }
            } else {
                Text("Credential access is managed by the active Primary.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 560)
        .confirmationDialog("Revoke credential access?", isPresented: $showRevokeConfirmation, titleVisibility: .visible) {
            Button("Revoke Access", role: .destructive) { Task { await onRevoke() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This node will no longer be authorised to fetch shared credentials. To remove an untrusted node fully, also rotate the shared secret and any credentials it previously received.")
        }
    }
}
