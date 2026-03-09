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
                    "Admin Web UI",
                    systemImage: "macwindow",
                    subtitle: "Enable the local web dashboard to manage SwiftBot from your browser."
                ) {
                    AdminWebServerConfigurationSection()
                }

                PreferencesCard(
                    "Internet Access",
                    systemImage: "network",
                    subtitle: "Expose your dashboard securely over the internet via Cloudflare Tunnel."
                ) {
                    InternetAccessConfigurationSection()
                }

                PreferencesCard(
                    "Authentication",
                    systemImage: "person.badge.key",
                    subtitle: "Control who can sign in to your dashboard with Discord."
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

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                .toggleStyle(.switch)
            
            Text("Run a local web server to manage SwiftBot from your browser. This server is required for Internet Access.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                .init(id: "start-tunnel", title: "Start Cloudflare tunnel", status: .success, detail: "SwiftBot is available at \(publicURLString).")
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
                id: "start-tunnel",
                title: "Start Cloudflare tunnel",
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
                if app.settings.adminWebUI.internetAccessEnabled && app.adminWebPublicAccessStatus.isEnabled && !publicURLString.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SwiftBot is available at: \(publicURLString)")
                            .font(.subheadline.weight(.medium))
                            .textSelection(.enabled)
                        
                        HStack(spacing: 10) {
                            Button("Open in Browser") {
                                openURL()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)

                            Button("Copy URL") {
                                copyURL()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            
                            Spacer()
                            
                            Button("Disable") {
                                disable()
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.red)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    HStack(spacing: 8) {
                        Text("Status")
                            .font(.subheadline.weight(.medium))
                        Text(statusText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(statusColor)
                    }

                    if let feedback = setupFeedback {
                        Text(feedback.message)
                            .font(.caption)
                            .foregroundStyle(feedback.status == .error ? .red : .secondary)
                    }
                }
            }

            if !app.settings.adminWebUI.internetAccessEnabled || isEnabling || isDisabling {
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
            }

            if !app.settings.adminWebUI.internetAccessEnabled && !isEnabling && !isDisabling {
                HStack(spacing: 10) {
                    if canEnable {
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
            }

            if !hasCloudflareAuthentication && !app.settings.adminWebUI.internetAccessEnabled {
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
        "start-tunnel"
    ]

    private var itemsByID: [String: CertificateManager.ValidationItem]

    init(hostname: String) {
        let normalizedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemsByID = [
            "cloudflare-access": .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: .pending, detail: nil),
            "cloudflare-zone": .init(id: "cloudflare-zone", title: "Detect zone", status: .pending, detail: normalizedHostname.isEmpty ? nil : "Preparing setup for \(normalizedHostname)."),
            "create-tunnel": .init(id: "create-tunnel", title: "Detect or create tunnel", status: .pending, detail: nil),
            "create-dns": .init(id: "create-dns", title: "Configure DNS route", status: .pending, detail: nil),
            "start-tunnel": .init(id: "start-tunnel", title: "Start Cloudflare tunnel", status: .pending, detail: nil)
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
        case .startingCloudflareTunnel:
            setItem(id: "start-tunnel", status: .warning, detail: "Starting Cloudflare tunnel…")
        case .cloudflareTunnelStarted:
            setItem(id: "start-tunnel", status: .success, detail: "Cloudflare tunnel active.")
        case .internetAccessEnabled(_):
            break
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

    private var hostname: String {
        app.settings.adminWebUI.normalizedHostname
    }

    private func redirectURL(for provider: String) -> String {
        guard !hostname.isEmpty else { return "" }
        return "https://\(hostname)/auth/\(provider)/callback"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sign-in")
                .font(.headline.weight(.semibold))

            if app.settings.adminWebUI.discordOAuth.enabled {
                OAuthProviderCard(
                    name: "Discord",
                    icon: "message.fill",
                    color: .indigo,
                    settings: $app.settings.adminWebUI.discordOAuth,
                    redirectURL: redirectURL(for: "discord")
                )
            }

            if app.settings.adminWebUI.appleOAuth.enabled {
                OAuthProviderCard(
                    name: "Apple",
                    icon: "apple.logo",
                    color: .primary,
                    settings: $app.settings.adminWebUI.appleOAuth,
                    redirectURL: redirectURL(for: "apple")
                )
            }

            if app.settings.adminWebUI.steamOAuth.enabled {
                OAuthProviderCard(
                    name: "Steam",
                    icon: "gamecontroller.fill",
                    color: .blue,
                    settings: $app.settings.adminWebUI.steamOAuth,
                    redirectURL: redirectURL(for: "steam")
                )
            }

            if app.settings.adminWebUI.githubOAuth.enabled {
                OAuthProviderCard(
                    name: "GitHub",
                    icon: "cat.fill",
                    color: .primary,
                    settings: $app.settings.adminWebUI.githubOAuth,
                    redirectURL: redirectURL(for: "github")
                )
            }

            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Restrict access to specific users", isOn: $app.settings.adminWebUI.restrictAccessToSpecificUsers)
                    .toggleStyle(.switch)

                Text("Access is automatically limited to Discord server administrators. Enable this to further restrict access to specific User IDs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.settings.adminWebUI.restrictAccessToSpecificUsers {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Allowed User IDs")
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
                    }
                }
            }
        }
    }
}

struct OAuthProviderCard: View {
    let name: String
    let icon: String
    let color: Color
    @Binding var settings: OAuthProviderSettings
    let redirectURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                }

                Spacer()

                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(14)

            if settings.enabled {
                VStack(alignment: .leading, spacing: 14) {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Client ID")
                            .font(.caption.weight(.medium))
                        TextField("Enter Client ID", text: $settings.clientID)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Client Secret")
                            .font(.caption.weight(.medium))
                        SecureField("Enter Client Secret", text: $settings.clientSecret)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Redirect URL")
                            .font(.caption.weight(.medium))
                        
                        HStack(spacing: 8) {
                            TextField("", text: .constant(redirectURL.isEmpty ? "Configure Hostname first" : redirectURL))
                                .textFieldStyle(.roundedBorder)
                                .disabled(true)
                            
                            Button {
                                copyToClipboard(redirectURL)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.bordered)
                            .disabled(redirectURL.isEmpty)
                            .help("Copy Redirect URL")
                        }
                        
                        Text("Use this URL in your \(name) developer portal.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding([.horizontal, .bottom], 14)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.spring(duration: 0.3), value: settings.enabled)
    }

    private func copyToClipboard(_ value: String) {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
                    Label("Open in Browser", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(GlassActionButtonStyle())
                .disabled(!canLaunchAdminWebUI)
            } else {
                Button {
                    app.launchAdminWebUI()
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.bordered)
                .disabled(!canLaunchAdminWebUI)
            }

            Text("Opens \(app.adminWebLaunchURL()?.absoluteString ?? "the local dashboard").")
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
