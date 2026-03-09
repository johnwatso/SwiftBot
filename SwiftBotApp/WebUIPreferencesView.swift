import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WebUIPreferencesView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            VStack(alignment: .leading, spacing: 20) {
                PreferencesCard("Web Server", systemImage: "globe") {
                    AdminWebServerConfigurationSection()
                }

                PreferencesCard("HTTPS", systemImage: "lock.shield") {
                    AdminWebHTTPSConfigurationSection()
                }

                PreferencesCard("Authentication", systemImage: "person.badge.key") {
                    AdminWebAuthenticationSection()
                }

                AdminWebLaunchControls(usesGlassActionStyle: false)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }
}

struct AdminWebServerConfigurationSection: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                Text("Bind Address")
                    .font(.subheadline.weight(.medium))
                TextField("127.0.0.1", text: $app.settings.adminWebUI.bindHost)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Port")
                    .font(.subheadline.weight(.medium))
                Stepper(value: $app.settings.adminWebUI.port, in: 1...65535) {
                    Text("\(app.settings.adminWebUI.port)")
                        .font(.body.monospacedDigit())
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Public Base URL")
                    .font(.subheadline.weight(.medium))
                TextField("https://admin.example.com", text: $app.settings.adminWebUI.publicBaseURL)
                    .textFieldStyle(.roundedBorder)
                Text("Leave empty to use the active listener URL automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AdminWebHTTPSConfigurationSection: View {
    @EnvironmentObject var app: AppModel
    @State private var isRefreshingSetupStatus = false
    @State private var isCreatingDNSRecord = false
    @State private var isMonitoringPropagation = false
    @State private var validationResult: CertificateManager.AutomaticHTTPSValidation?
    @State private var validationTask: Task<Void, Never>?
    @State private var propagationTask: Task<Void, Never>?
    @State private var setupFeedback: AdminWebHTTPSSetupFeedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable HTTPS", isOn: $app.settings.adminWebUI.httpsEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 8) {
                Text("Certificate Mode")
                    .font(.subheadline.weight(.medium))
                Picker("Certificate Mode", selection: $app.settings.adminWebUI.certificateMode) {
                    ForEach(AdminWebUICertificateMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            if app.settings.adminWebUI.httpsEnabled {
                switch app.settings.adminWebUI.certificateMode {
                case .automatic:
                    automaticFields
                case .importCertificate:
                    importedCertificateFields
                }
            }
        }
        .onAppear {
            scheduleValidation(after: 150_000_000)
        }
        .onChange(of: validationInputSignature) { _, _ in
            resetValidationState()
            scheduleValidation(after: 500_000_000)
        }
        .onDisappear {
            validationTask?.cancel()
            propagationTask?.cancel()
        }
    }

    private var automaticFields: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("HTTPS Domain")
                    .font(.subheadline.weight(.medium))
                TextField("admin.example.com", text: $app.settings.adminWebUI.httpsDomain)
                    .textFieldStyle(.roundedBorder)
                Text("Point this hostname at the machine running SwiftBot. DNS validation uses Cloudflare.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cloudflare API Token")
                    .font(.subheadline.weight(.medium))
                SecureField("Token with Zone DNS edit access", text: $app.settings.adminWebUI.cloudflareAPIToken)
                    .textFieldStyle(.roundedBorder)
                Text("Stored in Keychain. Used only for the `_acme-challenge` TXT record flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AdminWebHTTPSSetupStatusSection(
                validation: validationResult,
                isRefreshing: isRefreshingSetupStatus,
                isCreatingDNSRecord: isCreatingDNSRecord,
                isMonitoringPropagation: isMonitoringPropagation,
                feedback: setupFeedback,
                onRefresh: refreshSetupStatus,
                onCreateDNSRecord: createDNSRecord
            )
        }
    }

    private var importedCertificateFields: some View {
        Group {
            pemFileField(
                title: "Certificate File (.pem)",
                placeholder: "/path/to/certificate.pem",
                path: $app.settings.adminWebUI.importedCertificateFile,
                help: "SwiftBot copies the selected certificate into Application Support before enabling TLS."
            )

            pemFileField(
                title: "Private Key File (.pem)",
                placeholder: "/path/to/private-key.pem",
                path: $app.settings.adminWebUI.importedPrivateKeyFile
            )

            pemFileField(
                title: "Certificate Chain File (.pem, optional)",
                placeholder: "/path/to/chain.pem",
                path: $app.settings.adminWebUI.importedCertificateChainFile,
                allowsClear: true,
                help: "Optional intermediate certificates. SwiftBot appends this chain to the imported certificate when building the full chain."
            )
        }
    }

    private func pemFileField(
        title: String,
        placeholder: String,
        path: Binding<String>,
        allowsClear: Bool = false,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))

            HStack(spacing: 10) {
                TextField(placeholder, text: path)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    if let selectedPath = choosePEMFile() {
                        path.wrappedValue = selectedPath
                    }
                }
                .buttonStyle(.bordered)

                if allowsClear && !path.wrappedValue.isEmpty {
                    Button("Clear") {
                        path.wrappedValue = ""
                    }
                    .buttonStyle(.borderless)
                }
            }

            if let help, !help.isEmpty {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choosePEMFile() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pem") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private var validationInputSignature: String {
        [
            app.settings.adminWebUI.httpsEnabled ? "1" : "0",
            app.settings.adminWebUI.certificateMode.rawValue,
            app.settings.adminWebUI.normalizedHTTPSDomain,
            app.settings.adminWebUI.cloudflareAPIToken
        ].joined(separator: "|")
    }

    private func resetValidationState() {
        validationTask?.cancel()
        propagationTask?.cancel()
        validationTask = nil
        propagationTask = nil
        validationResult = nil
        isRefreshingSetupStatus = false
        isCreatingDNSRecord = false
        isMonitoringPropagation = false
        setupFeedback = nil
    }

    private func refreshSetupStatus() {
        setupFeedback = nil
        scheduleValidation()
    }

    private func createDNSRecord() {
        guard !isCreatingDNSRecord else { return }

        propagationTask?.cancel()
        propagationTask = nil
        isMonitoringPropagation = false
        isCreatingDNSRecord = true
        setupFeedback = nil

        Task { @MainActor in
            do {
                let creation = try await app.createAdminWebAutomaticHTTPSDNSRecord()
                guard !Task.isCancelled else { return }

                setupFeedback = AdminWebHTTPSSetupFeedback(
                    status: .success,
                    message: "Created \(creation.type) record \(creation.name) -> \(creation.content) in \(creation.zoneName)."
                )
                isCreatingDNSRecord = false
                scheduleValidation(after: 750_000_000)
            } catch {
                guard !Task.isCancelled else { return }
                setupFeedback = AdminWebHTTPSSetupFeedback(
                    status: .error,
                    message: error.localizedDescription
                )
                isCreatingDNSRecord = false
                scheduleValidation(after: 200_000_000)
            }
        }
    }

    private func scheduleValidation(after nanoseconds: UInt64 = 0) {
        guard app.settings.adminWebUI.httpsEnabled,
              app.settings.adminWebUI.certificateMode == .automatic
        else {
            resetValidationState()
            return
        }

        validationTask?.cancel()
        isRefreshingSetupStatus = true

        validationTask = Task { @MainActor in
            if nanoseconds > 0 {
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
            let result = await app.validateAdminWebAutomaticHTTPSConfiguration()
            guard !Task.isCancelled else { return }
            validationResult = result
            isRefreshingSetupStatus = false
            validationTask = nil
            updatePropagationMonitoring(for: result)
        }
    }

    private func updatePropagationMonitoring(for result: CertificateManager.AutomaticHTTPSValidation) {
        if result.isAwaitingDNSPropagation {
            startPropagationMonitoring()
        } else {
            propagationTask?.cancel()
            propagationTask = nil
            isMonitoringPropagation = false
        }
    }

    private func startPropagationMonitoring() {
        guard propagationTask == nil else { return }

        isMonitoringPropagation = true
        propagationTask = Task { @MainActor in
            defer {
                propagationTask = nil
                isMonitoringPropagation = false
            }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }

                let result = await app.validateAdminWebAutomaticHTTPSConfiguration()
                guard !Task.isCancelled else { return }

                validationResult = result
                if !result.isAwaitingDNSPropagation {
                    return
                }
            }
        }
    }
}

private struct AdminWebHTTPSSetupFeedback {
    let status: CertificateManager.ValidationStatus
    let message: String
}

private struct AdminWebHTTPSSetupStatusSection: View {
    let validation: CertificateManager.AutomaticHTTPSValidation?
    let isRefreshing: Bool
    let isCreatingDNSRecord: Bool
    let isMonitoringPropagation: Bool
    let feedback: AdminWebHTTPSSetupFeedback?
    let onRefresh: () -> Void
    let onCreateDNSRecord: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HTTPS Setup Status")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing || isCreatingDNSRecord)

                if validation?.canCreateDNSRecord == true {
                    Button("Create DNS Record") {
                        onCreateDNSRecord()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRefreshing || isCreatingDNSRecord)
                }

                if isRefreshing || isCreatingDNSRecord || isMonitoringPropagation {
                    ProgressView()
                        .controlSize(.small)
                    Text(activityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("SwiftBot checks DNS and Cloudflare before requesting a certificate. It does not issue or renew certificates from this section.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let validation {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(validation.items.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 10) {
                            Text(item.status.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(item.status.color)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(index + 1). \(item.title)")
                                    .font(.subheadline.weight(.medium))

                                if let detail = item.detail, !detail.isEmpty {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
            } else {
                Text("Checking current HTTPS setup…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(feedback.status.color)
            }

            if isMonitoringPropagation {
                Text("Waiting for DNS propagation. SwiftBot is re-checking automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activityText: String {
        if isCreatingDNSRecord {
            return "Creating DNS record…"
        }
        if isMonitoringPropagation {
            return "Re-checking DNS propagation…"
        }
        return "Checking setup…"
    }
}

private extension CertificateManager.ValidationStatus {
    var symbol: String {
        switch self {
        case .success:
            return "●"
        case .warning:
            return "⚠"
        case .error:
            return "✖"
        }
    }

    var color: Color {
        switch self {
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

struct AdminWebAuthenticationSection: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Discord OAuth Client ID")
                    .font(.subheadline.weight(.medium))
                TextField("123456789012345678", text: $app.settings.adminWebUI.discordClientID)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Discord OAuth Client Secret")
                    .font(.subheadline.weight(.medium))
                SecureField("Client Secret", text: $app.settings.adminWebUI.discordClientSecret)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle("Restrict access to specific users", isOn: $app.settings.adminWebUI.restrictAccessToSpecificUsers)
                .toggleStyle(.switch)

            if app.settings.adminWebUI.restrictAccessToSpecificUsers {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Discord User IDs")
                        .font(.subheadline.weight(.medium))
                    TextField("Comma-separated Discord IDs", text: Binding(
                        get: { app.settings.adminWebUI.allowedUserIDs.joined(separator: ", ") },
                        set: { newValue in
                            app.settings.adminWebUI.allowedUserIDs = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("Leave empty to allow any server administrator.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Access is automatically limited to Discord server administrators.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AdminWebLaunchControls: View {
    @EnvironmentObject var app: AppModel

    let usesGlassActionStyle: Bool

    private var canLaunchAdminWebUI: Bool {
        app.settings.adminWebUI.enabled && app.adminWebLaunchURL() != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if usesGlassActionStyle {
                Button {
                    app.launchAdminWebUI()
                } label: {
                    Label("Launch Web UI", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(GlassActionButtonStyle())
                .disabled(!canLaunchAdminWebUI)
            } else {
                Button {
                    app.launchAdminWebUI()
                } label: {
                    Label("Launch Web UI", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.bordered)
                .disabled(!canLaunchAdminWebUI)
            }

            Text("Opens \(app.adminWebLaunchURL()?.absoluteString ?? "the configured Web UI URL"). Save settings first if you changed the host, port, or public base URL.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
