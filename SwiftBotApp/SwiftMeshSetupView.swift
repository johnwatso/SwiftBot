import SwiftUI

// MARK: - SwiftMesh Setup View

struct SwiftMeshSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var step: MeshStep = .setup
    /// Disclosure toggle for splitting Listen Port and Leader Port. Initialised
    /// from the saved values so a user who returns to setup with diverged
    /// ports sees the advanced section already revealed.
    @State private var useSeparateLeaderPort: Bool = false

    private enum MeshStep {
        case setup, testing, confirmed, failed
    }

    var body: some View {
        // Wrap the switch in a Group so the .onChange listener below stays
        // mounted across every step. Previously the listener lived inside
        // `meshSetupFields` and was unsubscribed the moment we switched to
        // `.testing` — meaning the transition back to .confirmed/.failed
        // never fired and the UI got stuck on "Testing connection…".
        Group {
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
        .onChange(of: app.workerConnectionTestInProgress) { _, inProgress in
            guard step == .testing, !inProgress else { return }
            step = app.workerConnectionTestIsSuccess ? .confirmed : .failed
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

            HStack(spacing: 12) {
                Text("Mesh Port")
                    .font(.callout)
                Spacer()
                TextField("Port", text: Binding(
                    get: { String(app.settings.clusterListenPort) },
                    set: { newValue in
                        guard let v = Int(newValue) else { return }
                        app.settings.clusterListenPort = v
                        // Keep the leader port mirrored unless the advanced
                        // toggle is on (user is intentionally splitting ports
                        // because the Primary is on the same machine or
                        // behind a port-forward).
                        if !useSeparateLeaderPort {
                            app.settings.clusterLeaderPort = v
                        }
                    }
                ))
                .onboardingTextFieldStyle()
                .frame(width: 110)
            }
            .frame(maxWidth: 560)

            DisclosureGroup(isExpanded: $useSeparateLeaderPort) {
                HStack(spacing: 12) {
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
                .padding(.top, 4)
                Text("Only needed when the Primary listens on a different port than this node (e.g. two SwiftBot instances on the same machine, or a NAT port-forward).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Text("Advanced: use a different port for outbound")
                    .font(.callout)
            }
            .onChange(of: useSeparateLeaderPort) { _, isOn in
                // Collapsing snaps Leader Port back to Listen Port so the
                // common-case invariant is restored.
                if !isOn {
                    app.settings.clusterLeaderPort = app.settings.clusterListenPort
                }
            }
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
            // Reveal the advanced toggle if the saved configuration already
            // has divergent ports — otherwise the user would lose visibility
            // of why Leader Port differs.
            useSeparateLeaderPort = app.settings.clusterLeaderPort != app.settings.clusterListenPort
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
