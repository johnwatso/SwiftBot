import SwiftUI

// MARK: - SwiftMesh Setup View

struct SwiftMeshSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var step: MeshStep = .setup

    private enum MeshStep {
        case setup, testing, confirmed, failed
    }

    var body: some View {
        switch step {
        case .setup:
            meshSetupFields
        case .testing:
            testingView
        case .confirmed:
            confirmedView
        case .failed:
            failedView
        }
    }

    // MARK: - Setup Fields

    private var meshSetupFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Node Name", text: $app.settings.clusterNodeName)
                .onboardingTextFieldStyle()
                .frame(maxWidth: 560)

            TextField("Cluster Host (e.g. 192.168.1.100 or server.example.com)", text: $app.settings.clusterLeaderAddress)
                .onboardingTextFieldStyle()
                .frame(maxWidth: 560)

            HStack(spacing: 16) {
                HStack {
                    Text("Listen Port")
                        .font(.callout)
                    Spacer()
                    TextField("Port", text: Binding(
                        get: { String(app.settings.clusterListenPort) },
                        set: { newValue in
                            guard let v = Int(newValue) else { return }
                            // If Leader Port still matches the old Listen Port
                            // (typical dev pair: both nodes on the same custom
                            // port), keep them in sync so users don't end up
                            // with one custom port and one default.
                            let wasInSync = app.settings.clusterLeaderPort == app.settings.clusterListenPort
                            app.settings.clusterListenPort = v
                            if wasInSync {
                                app.settings.clusterLeaderPort = v
                            }
                        }
                    ))
                    .onboardingTextFieldStyle()
                    .frame(width: 110)
                }
                .frame(maxWidth: .infinity)

                HStack {
                    Text("Leader Port")
                        .font(.callout)
                    Spacer()
                    TextField("Port", text: Binding(
                        get: { String(app.settings.clusterLeaderPort) },
                        set: { if let v = Int($0) { app.settings.clusterLeaderPort = v } }
                    ))
                    .onboardingTextFieldStyle()
                    .frame(width: 110)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 560)

            Text("Leader Port is the port the Primary listens on. For a single-machine dev setup or any pair using the same port on both sides, keep these equal — Listen Port edits propagate to Leader Port automatically while they match.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: 560, alignment: .leading)

            RevealableSecretField(
                text: $app.settings.clusterSharedSecret,
                placeholder: "Mesh Token",
                allowRegenerate: true
            )
            .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    step = .testing
                    app.testWorkerLeaderConnection()
                } label: {
                    Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(minWidth: 200)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                .disabled(app.settings.clusterLeaderAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(maxWidth: 560)
        .onAppear {
            app.settings.launchMode = .swiftMeshClusterNode
        }
        .onChange(of: app.workerConnectionTestInProgress) { _, inProgress in
            guard step == .testing, !inProgress else { return }
            step = app.workerConnectionTestIsSuccess ? .confirmed : .failed
        }
    }

    // MARK: - Testing View

    private var testingView: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Testing connection…")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Testing SwiftMesh connection, please wait")
    }

    // MARK: - Confirmed View

    private var confirmedView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(app.workerConnectionTestStatus)
                    .font(.body)
            }

            Button {
                app.saveSettings()
                app.completeOnboarding()
            } label: {
                Label("Go to Dashboard", systemImage: "arrow.right.circle.fill")
                    .frame(minWidth: 200)
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.large)
        }
    }

    // MARK: - Failed View

    private var failedView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text(app.workerConnectionTestStatus)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button { step = .setup } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    app.settings.clusterMode = .standalone
                    app.saveSettings()
                    app.completeOnboarding()
                } label: {
                    Label("Set Up Later (Limited Mode)", systemImage: "clock.arrow.2.circlepath")
                        .frame(minWidth: 200)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
            }

            Text("Limited Mode launches SwiftBot without Discord or SwiftMesh. Configure both from Settings after launch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }
}

// MARK: - Preview

#Preview {
    SwiftMeshSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
