import AppKit
import SwiftUI
import UniformTypeIdentifiers

private func sharedAdminWebHostname(in settings: AdminWebUISettings) -> String {
    settings.normalizedHostname
}

private func sharedAdminWebHostnameBinding(for app: AppModel) -> Binding<String> {
    Binding(
        get: {
            app.settings.adminWebUI.hostname
        },
        set: { newValue in
            app.settings.adminWebUI.hostname = newValue
        }
    )
}

struct WebUIPreferencesView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            VStack(alignment: .leading, spacing: 24) {
                PreferencesCard(
                    "Web Server",
                    systemImage: "globe",
                    subtitle: "Manage the local SwiftBot dashboard listener and the URL SwiftBot shares with browsers."
                ) {
                    AdminWebServerConfigurationSection()
                }

                PreferencesCard(
                    "Internet Access",
                    systemImage: "network",
                    subtitle: "Expose SwiftBot securely over the internet with automatic HTTPS and Cloudflare Tunneling."
                ) {
                    InternetAccessConfigurationSection()
                }

                PreferencesCard(
                    "Authentication",
                    systemImage: "person.badge.key",
                    subtitle: "Control who can sign in to the Web UI with Discord."
                ) {
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

    private var publicURLPreview: String {
        let sharedHostname = sharedAdminWebHostname(in: app.settings.adminWebUI)
        if !sharedHostname.isEmpty {
            return "https://\(sharedHostname)"
        }
        return app.adminWebBaseURL().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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
                Text("Public URL")
                    .font(.subheadline.weight(.medium))
                TextField("https://hostname", text: .constant(publicURLPreview))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Text("Updates automatically when Internet Access is configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InternetAccessConfigurationSection: View {
    @EnvironmentObject var app: AppModel
    @State private var isEnabling = false
    @State private var isDisabling = false
    @State private var setupFeedback: InternetAccessFeedback?
    @State private var setupProgress: InternetAccessSetupProgress?
    @State private var lastError: Error? = nil

    private var publicURLString: String {
        app.adminWebPublicAccessURL()?.absoluteString ?? ""
    }

    private var sharedHostname: String {
        sharedAdminWebHostname(in: app.settings.adminWebUI)
    }

    private var hasCloudflareAuthentication: Bool {
        !app.settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canEnable: Bool {
        !app.settings.adminWebUI.internetAccessEnabled
            && !isEnabling
            && !isDisabling
            && hasCloudflareAuthentication
            && !sharedHostname.isEmpty
    }

    private var checklistItems: [CertificateManager.ValidationItem] {
        if let setupProgress {
            return setupProgress.items
        }

        if app.settings.adminWebUI.internetAccessEnabled && app.adminWebPublicAccessStatus.isEnabled {
            return [
                .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: .success, detail: "Cloudflare authentication is ready."),
                .init(id: "cloudflare-zone", title: "Detect zone", status: .success, detail: "The hostname is associated with your Cloudflare account."),
                .init(id: "create-tunnel", title: "Detect or create tunnel", status: .success, detail: "The secure tunnel is configured."),
                .init(id: "create-dns", title: "Configure DNS route", status: .success, detail: "Traffic is routed to the tunnel."),
                .init(id: "issue-cert", title: "Issue HTTPS certificate", status: .success, detail: "Secure communication is enabled."),
                .init(id: "enable-access", title: "Enable Internet Access", status: .success, detail: "SwiftBot is available at \(publicURLString).")
            ]
        }

        return [
            .init(
                id: "cloudflare-access",
                title: "Verify Cloudflare API",
                status: hasCloudflareAuthentication ? .pending : .warning,
                detail: hasCloudflareAuthentication
                    ? "Ready to verify when setup starts."
                    : "Cloudflare authentication required."
            ),
            .init(
                id: "cloudflare-zone",
                title: "Detect zone",
                status: .pending,
                detail: "SwiftBot will detect the matching Cloudflare zone."
            ),
            .init(
                id: "create-tunnel",
                title: "Detect or create tunnel",
                status: .pending,
                detail: "Detected or created during setup."
            ),
            .init(
                id: "create-dns",
                title: "Configure DNS route",
                status: .pending,
                detail: "Configured automatically during setup."
            ),
            .init(
                id: "issue-cert",
                title: "Issue HTTPS certificate",
                status: .pending,
                detail: "Issued automatically via Cloudflare DNS challenge."
            ),
            .init(
                id: "enable-access",
                title: "Enable Internet Access",
                status: .pending,
                detail: canEnable ? "Ready to enable Internet Access." : "Complete the fields above to continue."
            )
        ]
    }

    private var statusColor: Color {
        if isEnabling { return .orange }
        return app.settings.adminWebUI.internetAccessEnabled && app.adminWebPublicAccessStatus.isEnabled ? .green : .secondary
    }

    private var statusText: String {
        if isEnabling { return "Setting up" }
        if isDisabling { return "Disabling" }
        return app.settings.adminWebUI.internetAccessEnabled && app.adminWebPublicAccessStatus.isEnabled ? "Enabled" : "Disabled"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable Internet Access", isOn: Binding(
                get: { app.settings.adminWebUI.internetAccessEnabled },
                set: { newValue in
                    if newValue {
                        enable()
                    } else {
                        disable()
                    }
                }
            ))
            .toggleStyle(.switch)
            .disabled(isEnabling || isDisabling)

            VStack(alignment: .leading, spacing: 8) {
                Text("Hostname")
                    .font(.subheadline.weight(.medium))
                TextField("admin.example.com", text: sharedAdminWebHostnameBinding(for: app))
                    .textFieldStyle(.roundedBorder)
                Text("The public domain name for your SwiftBot dashboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cloudflare API Token")
                    .font(.subheadline.weight(.medium))
                SecureField("Token with DNS:Edit and Tunnel:Edit permissions", text: $app.settings.adminWebUI.cloudflareAPIToken)
                    .textFieldStyle(.roundedBorder)
                Text("Stored securely in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Status")
                        .font(.subheadline.weight(.medium))
                    Text(statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                }

                if app.settings.adminWebUI.internetAccessEnabled, app.adminWebPublicAccessStatus.isEnabled, !publicURLString.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Internet access active")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("SwiftBot is available at: \(publicURLString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Traffic is routed securely through Cloudflare Tunnel with automatic HTTPS.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let feedback = setupFeedback {
                    Text(feedback.message)
                        .font(.caption)
                        .foregroundStyle(feedback.status == .error ? .red : .secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Setup Status")
                    .font(.headline.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(checklistItems) { item in
                        AdminWebStatusRow(
                            title: item.title,
                            detail: item.detail,
                            status: item.status,
                            isProcessing: isEnabling && checklistItems.first(where: { $0.status == .warning })?.id == item.id
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 10) {
                if app.settings.adminWebUI.internetAccessEnabled {
                    Button("Open in Browser") {
                        openURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabling || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    Button("Copy URL") {
                        copyURL()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisabling || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    if !isEnabling && (app.adminWebPublicAccessStatus.state == .error || setupFeedback?.status == .error) {
                        Button("Re-run Setup") {
                            enable()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDisabling || !hasCloudflareAuthentication)
                    }
                } else if canEnable {
                    if lastError is CloudflareDNSProvider.TunnelDNSConflict {
                        Button("Override DNS") {
                            enable(forceReplaceDNS: true)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Enable Internet Access") {
                            enable()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if isEnabling || isDisabling {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !hasCloudflareAuthentication {
                Label("Cloudflare authentication required.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func enable(forceReplaceDNS: Bool = false) {
        guard !isEnabling else { return }

        isEnabling = true
        setupFeedback = nil
        lastError = nil
        setupProgress = InternetAccessSetupProgress(hostname: app.settings.adminWebUI.normalizedHostname)

        Task { @MainActor in
            do {
                let resultMessage = try await app.startInternetAccessSetup(
                    progress: { event in
                        guard var progress = setupProgress else { return }
                        progress.apply(event)
                        setupProgress = progress
                    },
                    forceReplaceDNS: forceReplaceDNS
                )
                guard !Task.isCancelled else { return }

                setupProgress = nil
                setupFeedback = InternetAccessFeedback(status: .success, message: resultMessage)
                isEnabling = false
            } catch {
                guard !Task.isCancelled else { return }

                lastError = error

                if var progress = setupProgress {
                    progress.markFailed(message: app.userFacingAdminWebPublicAccessMessage(for: error))
                    setupProgress = progress
                }
                setupFeedback = InternetAccessFeedback(
                    status: feedbackStatus(for: error),
                    message: neutralMessage(for: error)
                )
                isEnabling = false
            }
        }
    }

    private func disable() {
        guard !isDisabling else { return }

        isDisabling = true
        setupFeedback = nil

        Task { @MainActor in
            // For now, we still use the old disable method, but we also clear the new flag.
            await app.disableAdminWebPublicAccess()
            app.settings.adminWebUI.internetAccessEnabled = false
            app.settings.adminWebUI.httpsEnabled = false
            try? await app.store.save(app.settings)
            
            guard !Task.isCancelled else { return }

            setupProgress = nil
            setupFeedback = InternetAccessFeedback(
                status: .success,
                message: "Internet access disabled"
            )
            isDisabling = false
        }
    }

    private func openURL() {
        guard let url = app.adminWebPublicAccessURL() else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyURL() {
        guard !publicURLString.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURLString, forType: .string)
        setupFeedback = InternetAccessFeedback(status: .success, message: "URL copied")
    }

    private func feedbackStatus(for error: Error) -> CertificateManager.ValidationStatus {
        let userMessage = app.userFacingAdminWebPublicAccessMessage(for: error)
        switch error {
        case CertificateManager.Error.missingCloudflareToken,
             CertificateManager.Error.inactiveCloudflareToken,
             CloudflareDNSProvider.Error.zoneNotFound,
             is CloudflareDNSProvider.TunnelDNSConflict:
            return .warning
        default:
            return userMessage.localizedCaseInsensitiveContains("hostname")
                ? .warning
                : .error
        }
    }

    private func neutralMessage(for error: Error) -> String {
        let userMessage = app.userFacingAdminWebPublicAccessMessage(for: error)
        if let conflict = error as? CloudflareDNSProvider.TunnelDNSConflict {
            return conflict.errorDescription ?? userMessage
        }

        switch error {
        case CertificateManager.Error.missingCloudflareToken,
             CertificateManager.Error.inactiveCloudflareToken:
            return "Cloudflare authentication required."
        case CloudflareDNSProvider.Error.zoneNotFound:
            return "The hostname is not available in the current Cloudflare account."
        default:
            if userMessage.localizedCaseInsensitiveContains("hostname") {
                return "Enter a valid hostname to continue."
            }
            return userMessage
        }
    }
}

private struct InternetAccessSetupProgress {
    private static let orderedStepIDs = [
        "cloudflare-access",
        "cloudflare-zone",
        "create-tunnel",
        "create-dns",
        "issue-cert",
        "enable-access"
    ]

    private var itemsByID: [String: CertificateManager.ValidationItem]

    init(hostname: String) {
        let normalizedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemsByID = [
            "cloudflare-access": .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: .pending, detail: nil),
            "cloudflare-zone": .init(id: "cloudflare-zone", title: "Detect zone", status: .pending, detail: normalizedHostname.isEmpty ? nil : "Preparing setup for \(normalizedHostname)."),
            "create-tunnel": .init(id: "create-tunnel", title: "Detect or create tunnel", status: .pending, detail: nil),
            "create-dns": .init(id: "create-dns", title: "Configure DNS route", status: .pending, detail: nil),
            "issue-cert": .init(id: "issue-cert", title: "Issue HTTPS certificate", status: .pending, detail: nil),
            "enable-access": .init(id: "enable-access", title: "Enable Internet Access", status: .pending, detail: nil)
        ]
    }

    var items: [CertificateManager.ValidationItem] {
        Self.orderedStepIDs.compactMap { itemsByID[$0] }
    }

    mutating func apply(_ event: InternetAccessSetupEvent) {
        switch event {
        case .verifyingCloudflareAccess:
            setItem(id: "cloudflare-access", status: .warning, detail: "Verifying API token…")
        case .cloudflareAccessVerified:
            setItem(id: "cloudflare-access", status: .success, detail: "Cloudflare API verified.")
        case .detectingCloudflareZone(let domain):
            setItem(id: "cloudflare-zone", status: .warning, detail: "Detecting zone for \(domain)…")
        case .cloudflareZoneDetected(let zone):
            setItem(id: "cloudflare-zone", status: .success, detail: "Using Cloudflare zone \(zone).")
        case .creatingTunnel(let hostname):
            setItem(id: "create-tunnel", status: .warning, detail: "Configuring tunnel for \(hostname)…")
        case .tunnelCreated(let name), .tunnelDetected(let name):
            setItem(id: "create-tunnel", status: .success, detail: "Tunnel \(name) is active.")
        case .creatingTunnelDNSRecord(let hostname):
            setItem(id: "create-dns", status: .warning, detail: "Configuring DNS route for \(hostname)…")
        case .tunnelDNSRecordCreated(let hostname):
            setItem(id: "create-dns", status: .success, detail: "DNS route configured for \(hostname).")
        case .issuingHTTPSCertificate(let domain):
            setItem(id: "issue-cert", status: .warning, detail: "Issuing certificate for \(domain)…")
        case .httpsCertificateIssued(let domain):
            setItem(id: "issue-cert", status: .success, detail: "HTTPS certificate active for \(domain).")
        case .storingCredentials:
            setItem(id: "enable-access", status: .warning, detail: "Saving configuration…")
        case .enablingInternetAccess(let url):
            setItem(id: "enable-access", status: .warning, detail: "Starting secure listener…")
        case .internetAccessEnabled(let url):
            setItem(id: "enable-access", status: .success, detail: "SwiftBot is available at \(url).")
        }
    }

    mutating func markFailed(message: String) {
        guard let failingStepID = currentStepID else { return }
        setItem(id: failingStepID, status: .error, detail: message)
    }

    private var currentStepID: String? {
        if let warningID = Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .warning }) {
            return warningID
        }
        return Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .pending })
    }

    private mutating func setItem(id: String, status: CertificateManager.ValidationStatus, detail: String?) {
        guard let existing = itemsByID[id] else { return }
        itemsByID[id] = .init(id: existing.id, title: existing.title, status: status, detail: detail)
    }
}

private struct InternetAccessFeedback {
    let status: CertificateManager.ValidationStatus
    let message: String
}

private struct AdminWebStatusRow: View {
    let title: String
    let detail: String?
    let status: CertificateManager.ValidationStatus
    let isProcessing: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconColor)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var iconName: String {
        if isProcessing { return "arrow.triangle.2.circlepath" }
        switch status {
        case .pending: return "circle"
        case .success: return "checkmark.circle.fill"
        case .warning, .error: return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        if isProcessing { return .orange }
        return status.color
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

            Text("Access is automatically limited to Discord server administrators.")
                .font(.caption)
                .foregroundStyle(.secondary)

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


private extension CertificateManager.ValidationStatus {
    var color: Color {
        switch self {
        case .pending: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
