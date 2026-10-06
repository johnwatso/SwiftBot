import AppKit
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
                HStack {
                    Text(witness.isConfigured ? "Ruru · \(URL(string: witness.endpoint)?.host ?? witness.endpoint)" : "Peer coordination")
                        .foregroundStyle(.secondary)
                    Button(witness.isConfigured ? "Edit Witness…" : "Set Up Ruru…") {
                        witness = MeshWitnessSettingsStore.load()
                        showWitnessEditor = true
                    }
                }
            }
            if witness.isConfigured {
                // Ruru's Preferred Primary is intent; Current Owner is who
                // holds ownership now. They can differ, e.g. after a failover.
                LabeledContent("Current Owner") {
                    Text(app.meshCurrentOwnerName).foregroundStyle(.secondary)
                }
                LabeledContent("Preferred Primary") {
                    Text(app.meshPreferredPrimaryText(grants: grants)).foregroundStyle(.secondary)
                }
                if !app.meshLocalNodeID.isEmpty {
                    // What Ruru's Choose Primary → Enter Node ID expects for this Mac.
                    LabeledContent("This Mac's node ID") {
                        Text(app.meshLocalNodeID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
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
                A Ruru witness prevents both nodes acquiring ownership during a network partition.
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
    /// The saved settings. Advanced edits a copy, so Cancel or a failed
    /// import leaves them untouched.
    let existing: MeshWitnessConfiguration
    let onSave: (MeshWitnessConfiguration) -> Void
    @State private var manual: MeshWitnessConfiguration
    @State private var pastedCode = ""
    @State private var pairing: RuruPairingCode?
    @State private var showAdvanced = false
    @State private var error: String?

    init(configuration: MeshWitnessConfiguration, onSave: @escaping (MeshWitnessConfiguration) -> Void) {
        existing = configuration
        self.onSave = onSave
        _manual = State(initialValue: configuration)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up Ruru").font(.title2)
            Text("Run Ruru on a Mac separate from both bot Macs. In Ruru, copy this service’s pairing code, then paste it here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let pairing {
                Form {
                    LabeledContent("Service", value: pairing.serviceName ?? "Unnamed service")
                    LabeledContent("Address") {
                        Text(pairing.configuration.endpoint).textSelection(.enabled)
                    }
                    LabeledContent("Cluster ID", value: pairing.configuration.clusterID)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                Button("Use a Different Code") { self.pairing = nil; error = nil }
            } else {
                HStack {
                    Button("Paste Pairing Code") { pasteFromClipboard() }
                        .controlSize(.large)
                    SecureField("or paste it here", text: $pastedCode)
                        .onSubmit { importCode(pastedCode) }
                        .onChange(of: pastedCode) { _, code in
                            if !code.isEmpty { importCode(code) }
                        }
                }
            }

            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 12) {
                    Form {
                        TextField("HTTPS endpoint", text: $manual.endpoint)
                        TextField("Cluster ID", text: $manual.clusterID)
                        SecureField("Bearer token", text: $manual.token)
                    }
                    HStack {
                        Spacer()
                        Button("Save Manual Settings") { commit(manual) }
                            .disabled(!manual.isValid || manual == existing)
                    }
                }
                .padding(.top, 8)
            }

            Text("""
                Settings are saved in this Mac’s Keychain and included in new failover Join Codes.
                Failovers that are already paired keep their old settings: set up Ruru on each one, or pair it again with a new Join Code.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if existing.isConfigured {
                    Button("Remove Witness", role: .destructive) { commit(.init()) }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Connect") { if let pairing { commit(pairing.configuration) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(pairing == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func pasteFromClipboard() {
        guard let code = NSPasteboard.general.string(forType: .string) else {
            error = RuruPairingCode.DecodeError.empty.localizedDescription
            return
        }
        importCode(code)
    }

    /// Decodes for review only; nothing is saved until Connect.
    private func importCode(_ code: String) {
        do {
            pairing = try RuruPairingCode.decode(code)
            error = nil
        } catch {
            pairing = nil
            self.error = error.localizedDescription
        }
        pastedCode = ""
    }

    private func commit(_ value: MeshWitnessConfiguration) {
        guard MeshWitnessSettingsStore.save(value) else {
            error = "The witness settings could not be saved to Keychain. Your previous settings are unchanged."
            return
        }
        onSave(value)
        dismiss()
    }
}
