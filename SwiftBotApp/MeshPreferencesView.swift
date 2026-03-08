import SwiftUI

struct MeshPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var showWorkerOffloadWarning = false

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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Primary Address")
                            .font(.subheadline.weight(.medium))
                        TextField("http://host:port", text: $app.settings.clusterLeaderAddress)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Listen Port")
                        .font(.subheadline.weight(.medium))
                    Stepper(value: $app.settings.clusterListenPort, in: 1...65535) {
                        Text("\(app.settings.clusterListenPort)")
                            .font(.body.monospacedDigit())
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
                    HStack(spacing: 10) {
                        Button("Test Connection") {
                            app.testWorkerLeaderConnection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(app.workerConnectionTestInProgress)

                        Button("Refresh Status") {
                            app.refreshClusterStatus()
                        }
                        .buttonStyle(.bordered)
                    }

                    if app.workerConnectionTestInProgress {
                        ProgressView("Testing connection…")
                            .controlSize(.small)
                    } else {
                        Text(app.workerConnectionTestStatus)
                            .font(.caption)
                            .foregroundStyle(app.workerConnectionTestIsSuccess ? .green : .secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
