import SwiftUI

// MARK: - Remote Setup View

struct RemoteSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void
    
    @State private var remoteAddressInput: String = ""
    @State private var step: RemoteStep = .setup
    @StateObject private var remoteTester = RemoteControlService()
    
    private enum RemoteStep {
        case setup, authenticating, testing, confirmed, failed
    }
    
    var body: some View {
        Group {
            switch step {
            case .setup:
                remoteSetupFields
            case .authenticating:
                authenticatingView
            case .testing:
                testingView
            case .confirmed:
                confirmedView
            case .failed:
                failedView
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteAuthSessionReceived)) { _ in
            handleAuthCompleted()
        }
    }
    
    // MARK: - Setup Fields
    
    private var remoteSetupFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("https://mybot.example.com", text: $remoteAddressInput)
                .onboardingTextFieldStyle()
                .frame(maxWidth: 560)
            
            if let error = remoteTester.lastError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button {
                    startOAuthFlow()
                } label: {
                    Label("Sign in with Discord", systemImage: "person.badge.key")
                        .frame(minWidth: 220)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                .disabled(
                    remoteAddressInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .frame(maxWidth: 560)
        .onAppear {
            remoteAddressInput = app.settings.remoteMode.primaryNodeAddress
            app.settings.launchMode = .remoteControl
        }
    }
    
    // MARK: - OAuth Flow
    
    private func startOAuthFlow() {
        let normalizedAddress = RemoteModeSettings.normalizeBaseURL(remoteAddressInput)
        guard var components = URLComponents(string: "\(normalizedAddress)/auth/discord/login") else {
            remoteTester.lastError = "Invalid server URL"
            return
        }
        components.queryItems = [
            URLQueryItem(name: "return_to", value: "swiftbot://auth")
        ]
        guard let authURL = components.url else {
            remoteTester.lastError = "Invalid server URL"
            return
        }
        
        // Store the server address for later use
        app.updateRemoteModeConnection(
            primaryNodeAddress: normalizedAddress,
            accessToken: ""
        )
        remoteTester.lastError = nil
        
        // Open OAuth URL in browser
        NSWorkspace.shared.open(authURL)
        step = .authenticating
    }
    
    private func handleAuthCompleted() {
        guard step == .authenticating else { return }
        
        // Update remote tester with new configuration
        remoteTester.updateConfiguration(app.settings.remoteMode)
        
        // Test the connection
        step = .testing
        Task {
            let ok = await remoteTester.testConnection()
            step = ok ? .confirmed : .failed
        }
    }
    
    // MARK: - Authenticating View
    
    private var authenticatingView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Discord authentication…")
                    .foregroundStyle(.secondary)
            }
            
            Text("Complete the login in your browser. The app will automatically continue once authenticated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
            
            Button { step = .setup } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for Discord authentication, please complete login in browser")
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
        .accessibilityLabel("Testing remote connection, please wait")
    }
    
    // MARK: - Confirmed View
    
    private var confirmedView: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                    .accessibilityHidden(true)
                Text("Connected to \(remoteTester.status?.botUsername ?? "SwiftBot")")
                    .font(.body)
            }
            
            if let latency = remoteTester.lastLatencyMs {
                Text("Round-trip latency \(latency.formatted(.number.precision(.fractionLength(0)))) ms")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            
            // Display connection details
            VStack(alignment: .leading, spacing: 4) {
                if let status = remoteTester.status {
                    Text("Node: \(status.botUsername)")
                        .font(.callout)
                    Text("Cluster Mode: \(status.clusterMode.capitalized)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            
            Button {
                app.completeRemoteModeOnboarding(
                    primaryNodeAddress: remoteAddressInput,
                    accessToken: app.settings.remoteMode.accessToken
                )
            } label: {
                Label("Open Remote Dashboard", systemImage: "arrow.right.circle.fill")
                    .frame(minWidth: 220)
            }
            .onboardingGlassButton()
        }
    }
    
    // MARK: - Failed View
    
    private var failedView: some View {
        VStack(spacing: 16) {
            if let error = remoteTester.lastError, !error.isEmpty {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }
            
            HStack(spacing: 12) {
                Button { step = .setup } label: {
                    Label("Try Again", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    RemoteSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
