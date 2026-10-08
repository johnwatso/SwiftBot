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
            MeshWitnessEditor(configuration: witness, nodeID: app.meshLocalNodeID,
                              nodeName: app.settings.clusterNodeName) { saved in
                witness = saved
                Task { await app.configureMeshRecovery() }
            }
        }
    }
}

private struct MeshWitnessEditor: View {
    @Environment(\.dismiss) private var dismiss
    /// The saved settings. Advanced edits a copy, so Cancel or a failed
    /// pairing leaves them untouched.
    let existing: MeshWitnessConfiguration
    let nodeID: String
    let nodeName: String
    let onSave: (MeshWitnessConfiguration) -> Void
    @State private var manual: MeshWitnessConfiguration
    @State private var typedCode = ""
    @State private var address: String
    /// Connection details Ruru released after approval, shown for review.
    @State private var approved: MeshWitnessConfiguration?
    @State private var waiting: Task<Void, Never>?
    @State private var showAdvanced = false
    @State private var error: String?

    init(configuration: MeshWitnessConfiguration, nodeID: String, nodeName: String,
         onSave: @escaping (MeshWitnessConfiguration) -> Void) {
        existing = configuration
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.onSave = onSave
        _manual = State(initialValue: configuration)
        _address = State(initialValue: configuration.endpoint)
    }

    private var code: String? { RuruShortCodePairing.normalized(typedCode) }
    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Set Up Ruru").font(.title2)
            Text("Run Ruru on a Mac separate from both bot Macs. In Ruru, open this service’s Connection Details → Pair a Server → Create Code, then enter the code here. You’ll approve the request in Ruru; no token is copied.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let approved {
                Form {
                    LabeledContent("Address") { Text(approved.endpoint).textSelection(.enabled) }
                    LabeledContent("Cluster ID", value: approved.clusterID)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                Button("Pair Again") { self.approved = nil; error = nil }
            } else {
                Form {
                    TextField("Pairing code", text: $typedCode, prompt: Text("7KQ4-M2XP"))
                        .font(.body.monospaced())
                    TextField("Ruru address", text: $address, prompt: Text("https://ruru.example.com"))
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(waiting != nil)
                HStack {
                    if waiting != nil {
                        ProgressView().controlSize(.small)
                        Text("Waiting for approval in Ruru…").foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop Waiting") { cancelWaiting() }
                    } else {
                        Spacer()
                        Button("Request Pairing", action: requestPairing)
                            .disabled(code == nil || !MeshWitnessConfiguration.isValidEndpoint(trimmedAddress))
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
                Button("Cancel") { cancelWaiting(); dismiss() }
                Button("Connect") { if let approved { commit(approved) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(approved == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onDisappear { cancelWaiting() }
    }

    /// Sends the code to Ruru and waits for approval there. Nothing is saved
    /// until the operator reviews the result and chooses Connect.
    private func requestPairing() {
        guard let code else { return }
        error = nil
        let address = trimmedAddress, nodeID = nodeID, nodeName = nodeName
        waiting = Task {
            do {
                approved = try await RuruShortCodePairing.pair(endpoint: address, code: code,
                                                              nodeID: nodeID, nodeName: nodeName)
                typedCode = ""
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            waiting = nil
        }
    }

    private func cancelWaiting() {
        waiting?.cancel()
        waiting = nil
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
