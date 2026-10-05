import SwiftUI

struct MeshRecoveryPreferencesSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var witness = MeshWitnessSettingsStore.load()
    @State private var showWitnessEditor = false
    @State private var grants: [MeshCredentialGrant] = []
    @State private var feedback: String?

    var body: some View {
        Section {
            LabeledContent("Backup WebUI") {
                Text(app.localMeshPublicAddress.isEmpty ? "Configure on this Mac" : app.localMeshPublicAddress)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Ownership") {
                Text(witness.isConfigured ? "Independent witness" : "Peer coordination")
                    .foregroundStyle(.secondary)
            }
            Button("Configure Ownership Witness…") {
                witness = MeshWitnessSettingsStore.load()
                showWitnessEditor = true
            }
            if let synced = app.meshLastSuccessfulSync {
                LabeledContent("Last shared-state sync", value: synced.formatted(.relative(presentation: .named)))
            }
            if app.runtimeClusterMode == .leader {
                ForEach(grants, id: \.nodeID) { grant in
                    LabeledContent(grant.nodeName.isEmpty ? "Paired node" : grant.nodeName) {
                        Button("Revoke Credential Access", role: .destructive) {
                            Task {
                                do {
                                    try await app.meshCredentialStore.revoke(nodeID: grant.nodeID)
                                    grants = await app.meshCredentialStore.allGrants()
                                } catch { feedback = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Label("Recovery and Pairing", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("""
                Use a dedicated backup hostname and tunnel on this Mac. Pairing shares Discord sign-in and bot state.
                Tunnel credentials, companion apps, browser sessions, and passkeys stay local.
                An independent witness prevents both nodes acquiring ownership during a network partition.
                """)
        }
        .task { grants = await app.meshCredentialStore.allGrants() }
        .sheet(isPresented: $showWitnessEditor) {
            MeshWitnessEditor(configuration: witness) { saved in
                witness = saved
                Task { await app.configureMeshRecovery() }
            }
        }
    }
}

private struct MeshWitnessEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var configuration: MeshWitnessConfiguration
    @State private var error: String?
    let onSave: (MeshWitnessConfiguration) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ownership Witness").font(.title2)
            Text("""
                Run the witness independently of both bot Macs. Use the same cluster ID and bearer token on trusted failover nodes.
                These settings are saved in Keychain and included in new failover Join Codes.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("HTTPS endpoint", text: $configuration.endpoint)
                TextField("Cluster ID", text: $configuration.clusterID)
                SecureField("Bearer token", text: $configuration.token)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Remove Witness", role: .destructive) { commit(.init()) }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { commit(configuration) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!configuration.isValid)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func commit(_ value: MeshWitnessConfiguration) {
        guard MeshWitnessSettingsStore.save(value) else {
            error = "The witness settings could not be saved to Keychain."
            return
        }
        onSave(value)
        dismiss()
    }
}
