import AppKit
import RuruClient
import SwiftUI

/// Ruru is an independent ownership witness. Its configuration is kept
/// separate from pairing and credential management so reachability is never
/// mistaken for a blanket cluster-health claim.
struct MeshWitnessPreferencesSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var witness = MeshWitnessSettingsStore.load()
    @State private var showWitnessEditor = false

    var body: some View {
        Section {
            ConsoleSettingRow(
                title: witness.isConfigured ? "Witness" : "No Witness Configured",
                symbol: "shield.lefthalf.filled",
                subtitle: witnessSummary
            ) {
                Button(witness.isConfigured ? "Configure…" : "Set Up Ruru…") {
                    witness = MeshWitnessSettingsStore.load()
                    showWitnessEditor = true
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }

            if witness.isConfigured {
                LabeledContent("Witness Host") {
                    Text(URL(string: witness.endpoint)?.host ?? witness.endpoint)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                LabeledContent("Reachability", value: reachabilityText)
                LabeledContent("Ownership Protection", value: protectionText)
            }
        } header: {
            Text("Ruru")
        } footer: {
            Text("Ruru helps prevent multiple Macs from becoming Primary during network interruptions.")
        }
        .sheet(isPresented: $showWitnessEditor) {
            MeshWitnessEditor(configuration: witness, nodeID: app.meshLocalNodeID,
                              nodeName: app.settings.clusterNodeName) { saved in
                witness = saved
                Task { await app.configureMeshRecovery() }
            }
        }
    }

    private var witnessSummary: String {
        guard witness.isConfigured else {
            return app.settings.clusterMode == .standalone
                ? "Required before creating a new SwiftMesh deployment."
                : "Legacy peer deployment: migrate to Ruru for partition-safe ownership."
        }
        guard witness.isValid else { return "The saved witness details are incomplete." }
        return "\(URL(string: witness.endpoint)?.host ?? witness.endpoint)"
    }

    private var reachabilityText: String {
        guard witness.isValid else { return "Configuration incomplete" }
        return app.meshWitnessHealth?.displayName ?? "Checking"
    }

    private var protectionText: String {
        guard witness.isValid else {
            return app.settings.clusterMode == .standalone ? "Set up Ruru before pairing" : "Legacy peer only"
        }
        guard app.meshWitnessHealth == .ready else { return "Waiting for Ruru" }
        if app.runtimeClusterMode == .leader, !app.meshOwnershipExpired {
            return "Lease held on this Mac"
        }
        return "No local lease held"
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

    private var code: String? { RuruPairingCode.normalized(typedCode) }
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
        guard MeshWitnessConfiguration.isValidEndpoint(trimmedAddress) else {
            error = "Enter Ruru's HTTPS address, such as https://ruru.example.com."
            return
        }
        guard !nodeID.isEmpty else {
            error = "This Mac's SwiftMesh identity isn't ready yet. Try again in a moment."
            return
        }
        error = nil
        let address = trimmedAddress, nodeID = nodeID, nodeName = nodeName
        waiting = Task {
            do {
                guard let url = URL(string: address) else { return }
                let ruruConfig = try await RuruPairing.pair(endpoint: url, code: code,
                                                            nodeID: nodeID, nodeName: nodeName)
                approved = MeshWitnessConfiguration(endpoint: ruruConfig.endpoint.absoluteString,
                                                     clusterID: ruruConfig.clusterID, token: ruruConfig.token)
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
