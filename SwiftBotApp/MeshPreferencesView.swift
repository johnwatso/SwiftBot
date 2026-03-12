import SwiftUI

struct MeshPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var showWorkerOffloadWarning = false
    @State private var showDiagnostics = false

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
                if let port = Int(filtered), (1...65535).contains(port) {
                    app.settings.clusterListenPort = port
                } else if filtered.isEmpty {
                    app.settings.clusterListenPort = Self.defaultListenPort
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
        PreferencesTabContainer {
            PreferencesCard("Configuration", systemImage: "network") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Role")
                        .font(.subheadline.weight(.medium))
                    Picker("Role", selection: $app.settings.clusterMode) {
                        ForEach(ClusterMode.selectableCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    Text(app.settings.clusterMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Node Name")
                        .font(.subheadline.weight(.medium))
                    TextField("SwiftBot Node", text: $app.settings.clusterNodeName)
                        .textFieldStyle(.roundedBorder)
                }

                if app.settings.clusterMode == .standby {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Primary Host")
                                .font(.subheadline.weight(.medium))
                            TextField("192.168.1.100", text: $app.settings.clusterLeaderAddress)
                                .textFieldStyle(.roundedBorder)
                        }
                        .frame(maxWidth: .infinity)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Port")
                                .font(.subheadline.weight(.medium))
                            TextField("38787", text: leaderPortBinding)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Listen Port")
                        .font(.subheadline.weight(.medium))
                    TextField("38787", text: listenPortBinding)
                        .textFieldStyle(.roundedBorder)
                    if hasInvalidPort {
                        Text("Port must be between 1 and 65535.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shared Secret")
                        .font(.subheadline.weight(.medium))
                    SecureField("Required for clustered mode", text: $app.settings.clusterSharedSecret)
                        .textFieldStyle(.roundedBorder)
                }
            }

            PreferencesCard("Worker Offload", systemImage: "point.3.connected.trianglepath.dotted") {
                Toggle("Enable Worker Offload", isOn: workerOffloadBinding)
                    .toggleStyle(.switch)

                Text("Allow SwiftBot to distribute certain workloads to worker nodes in the SwiftMesh cluster.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.settings.clusterWorkerOffloadEnabled {
                    Divider()

                    Toggle("Offload AI replies to workers when Primary", isOn: $app.settings.clusterOffloadAIReplies)
                        .toggleStyle(.switch)
                    Toggle("Offload Wiki lookups to workers when Primary", isOn: $app.settings.clusterOffloadWikiLookups)
                        .toggleStyle(.switch)
                }
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

            if app.settings.clusterMode == .standby {
                PreferencesCard("Cluster Status", systemImage: "arrow.clockwise") {
                    // Connection summary row
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

                    Divider()

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
                }
            }
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
