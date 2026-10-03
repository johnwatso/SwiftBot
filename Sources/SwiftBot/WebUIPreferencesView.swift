import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WebUIPreferencesView: View {
    @Environment(\.consoleFormContent) private var consoleFormContent
    @EnvironmentObject var app: AppModel

    var body: some View {
        SettingsForm(
            readOnlyBannerText: app.isFailoverManagedNode
                ? "Read-only on Failover nodes. These settings sync from Primary."
                : nil
        ) {
            Section {
                AdminWebServerConfigurationSection()
            } header: {
                Label("Admin Web UI", systemImage: "macwindow")
            } footer: {
                Text("Enable the local web dashboard to manage SwiftBot from your browser.")
            }

            Section {
                InternetAccessConfigurationSection()
            } header: {
                Label("Internet Access", systemImage: "network")
            } footer: {
                Text("Expose your dashboard securely over the internet via Cloudflare Tunnel.")
            }

            Section {
                AdminWebAuthenticationSection()
            } header: {
                Label("Authentication", systemImage: "person.badge.key")
            } footer: {
                Text("Control who can sign in to your dashboard with Discord.")
            }

            if !consoleFormContent {
                Section {
                    AdminWebLaunchControls(usesGlassActionStyle: false)
                }
            }
        }
        .preferencesCardDisabled(when: app.isFailoverManagedNode)
    }
}

struct AdminWebServerConfigurationSection: View {
    @Environment(\.consoleFormContent) private var consoleFormContent
    @EnvironmentObject var app: AppModel
    @State private var isAdvancedExpanded = false
    @State private var showRequireHTTPSDisableConfirm = false

    private var hasAnyAuthConfigured: Bool {
        let s = app.settings.adminWebUI
        func configured(_ p: OAuthProviderSettings) -> Bool {
            p.enabled
                && !p.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !p.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let localReady = s.localAuthEnabled
            && !s.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !s.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return configured(s.discordOAuth)
            || localReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !consoleFormContent {
                Toggle("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                    .toggleStyle(.switch)
            }

            Text("SwiftBot automatically detects the correct public URL for OAuth redirects.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if app.settings.adminWebUI.enabled && !hasAnyAuthConfigured {
                AdminWebAuthMissingBanner()
            }

            requireHTTPSSection

            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Override Public Base URL")
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 10)

                    TextField("https://example.com", text: $app.settings.adminWebUI.publicBaseURL)
                        .textFieldStyle(.roundedBorder)

                    Text("Optional. Only required when running behind a custom proxy or tunnel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                Text("Advanced Options")
                    .font(.subheadline.weight(.medium))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isAdvancedExpanded)
        .onAppear {
            isAdvancedExpanded = !app.settings.adminWebUI.publicBaseURL
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @ViewBuilder
    private var requireHTTPSSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.vertical, 2)

            Toggle(isOn: Binding(
                get: { app.settings.adminWebUI.requireHTTPS },
                set: { newValue in
                    if newValue {
                        // Enabling is always safe — apply immediately.
                        app.settings.adminWebUI.requireHTTPS = true
                    } else {
                        // Disabling weakens security; defer until the operator
                        // confirms in the alert below.
                        showRequireHTTPSDisableConfirm = true
                    }
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.orange)
                    Text("Require HTTPS")
                        .font(.subheadline.weight(.medium))
                }
            }
            .toggleStyle(.switch)
            .alert("Disable HTTPS requirement?", isPresented: $showRequireHTTPSDisableConfirm) {
                Button("Cancel", role: .cancel) {
                    // No-op: the binding never wrote `false`, so the toggle
                    // visually snaps back to ON on its own.
                }
                Button("Disable", role: .destructive) {
                    app.settings.adminWebUI.requireHTTPS = false
                }
            } message: {
                Text("Turning this off allows the Admin Web UI to serve over plain HTTP if HTTPS isn't configured. Credentials and session cookies would be visible on the network. Only disable this if you've intentionally moved the admin panel behind a VPN, reverse proxy, or another TLS terminator.")
            }

            Text("When enabled, SwiftBot refuses to start the Admin Web UI unless HTTPS is configured (via the Internet Access setup above). Prevents the admin panel from accidentally serving over plain HTTP.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This setting can only be changed here in the desktop app — the Web UI cannot disable its own protection.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if app.settings.adminWebUI.requireHTTPS && !app.settings.adminWebUI.internetAccessEnabled {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.caption)
                    Text("HTTPS isn't configured yet — the Admin Web UI will refuse to start. Enable Internet Access (Cloudflare) below or turn this off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @State private var lastError: Error?
    @State private var showingReRunSetupConfirmation = false
    @State private var showingNonPrimaryWarning = false
    @State private var showingSetupStatusWindow = false

    // Cloudflare account state (transient — zones are reloaded from the saved token)
    @State private var availableZones: [CloudflareDNSProvider.ZoneSummary] = []
    @State private var isVerifyingToken = false
    @State private var hasVerifiedToken = false
    @State private var tokenVerificationTask: Task<Void, Never>?
    @State private var tokenDraft = ""
    @State private var isReplacingToken = false
    @State private var tokenError: String?

    // Hostname drafts. Written straight through while Internet Access is off;
    // held back behind "Apply Changes" while it's on, because the live server
    // derives its public hostname from these settings.
    @State private var draftSubdomain = ""
    @State private var draftZoneID = ""

    // MARK: Derived state

    private var settings: AdminWebUISettings { app.settings.adminWebUI }

    private var isBusy: Bool { isEnabling || isDisabling }

    private var isInternetAccessActive: Bool {
        settings.internetAccessEnabled && app.adminWebPublicAccessStatus.isEnabled
    }

    private var hasSavedToken: Bool {
        !settings.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsTokenEntry: Bool {
        !hasSavedToken || isReplacingToken
    }

    private var draftZoneName: String {
        if let zone = availableZones.first(where: { $0.id == draftZoneID }) {
            return zone.name
        }
        if !draftZoneID.isEmpty, draftZoneID == settings.selectedZoneID {
            return settings.selectedZoneName.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private var draftHostname: String {
        let subdomain = draftSubdomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let zone = draftZoneName.lowercased()
        guard !subdomain.isEmpty, !zone.isEmpty else { return "" }
        return "\(subdomain).\(zone)"
    }

    private var hasPendingHostnameChange: Bool {
        settings.internetAccessEnabled
            && (draftSubdomain != settings.subdomain || draftZoneID != settings.selectedZoneID)
    }

    private var isConfigurationComplete: Bool {
        hasSavedToken && !isReplacingToken && !draftHostname.isEmpty
    }

    private var publicURLString: String {
        if isInternetAccessActive, let url = app.adminWebPublicAccessURL() {
            return url.absoluteString
        }
        let hostname = settings.normalizedHostname
        return hostname.isEmpty ? "" : "https://\(hostname)"
    }

    private var addressPreview: String {
        draftHostname.isEmpty ? "—" : "https://\(draftHostname)"
    }

    private var statusSubtitle: (text: String, color: Color) {
        if isEnabling { return ("Setting up…", .orange) }
        if isDisabling { return ("Turning off…", .secondary) }
        if isInternetAccessActive { return ("Available at \(URL(string: publicURLString)?.host ?? publicURLString)", .secondary) }
        if settings.internetAccessEnabled { return ("Tunnel isn't running", .orange) }
        if !isConfigurationComplete { return ("Connect Cloudflare and choose an address to turn on", .secondary) }
        return ("Off", .secondary)
    }

    private var checklistItems: [CertificateManager.ValidationItem] {
        if let setupProgress {
            return setupProgress.items
        }

        if isInternetAccessActive {
            return [
                .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: .success, detail: "Cloudflare authentication is ready."),
                .init(id: "cloudflare-zone", title: "Detect zone", status: .success, detail: "The hostname is associated with your Cloudflare account."),
                .init(id: "create-tunnel", title: "Detect or create tunnel", status: .success, detail: "The secure tunnel is configured."),
                .init(id: "create-dns", title: "Configure DNS route", status: .success, detail: "Traffic is routed to the tunnel."),
                .init(id: "issue-certificate", title: "Issue HTTPS certificate", status: .success, detail: "Secure communication is enabled."),
                .init(id: "enable-access", title: "Enable Internet Access", status: .success, detail: "SwiftBot is available at \(publicURLString).")
            ]
        }

        return [
            .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: hasSavedToken ? .pending : .warning,
                  detail: hasSavedToken ? "Ready to verify when setup starts." : "Cloudflare authentication required."),
            .init(id: "cloudflare-zone", title: "Detect zone", status: .pending, detail: "SwiftBot will detect the matching Cloudflare zone."),
            .init(id: "create-tunnel", title: "Detect or create tunnel", status: .pending, detail: "Detected or created during setup."),
            .init(id: "create-dns", title: "Configure DNS route", status: .pending, detail: "Configured automatically during setup."),
            .init(id: "issue-certificate", title: "Issue HTTPS certificate", status: .pending, detail: "Issued automatically via Cloudflare Edge."),
            .init(id: "enable-access", title: "Enable Internet Access", status: .pending,
                  detail: isConfigurationComplete ? "Ready to enable Internet Access." : "Complete the fields above to continue.")
        ]
    }

    // MARK: Body

    var body: some View {
        enableRow
            .alert("Re-run Internet Access Setup?", isPresented: $showingReRunSetupConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Repair Configuration") {
                    enable()
                }
                Button("Reset and Start Over", role: .destructive) {
                    reset()
                }
            } message: {
                Text("You can attempt to repair the existing configuration, or remove the configuration and start setup again.")
            }
            .sheet(isPresented: $showingSetupStatusWindow) {
                InternetAccessSetupStatusWindow(
                    items: checklistItems,
                    feedback: setupFeedback,
                    isProcessing: isEnabling,
                    currentProcessingItemID: checklistItems.first(where: { $0.status == .warning })?.id
                )
                .interactiveDismissDisabled(isEnabling)
            }
            .alert("Web UI Configuration on Non-Primary Node", isPresented: $showingNonPrimaryWarning) {
                Button("Cancel", role: .cancel) { }
                Button("Continue Anyway") {
                    enable()
                }
            } message: {
                let primaryHost = app.settings.clusterLeaderAddress
                let message = "This SwiftBot instance is running as a Worker node in a SwiftMesh cluster.\n\nWeb UI configuration changes made here will NOT be synchronized to the Primary node.\n\nFor consistent configuration, it is recommended to access the Web UI through the Primary SwiftBot instance instead." // swiftlint:disable:this line_length

                if !primaryHost.isEmpty {
                    Text("\(message)\n\nPrimary node detected at: \(primaryHost)")
                } else {
                    Text(message)
                }
            }
            .onAppear {
                syncDraftsFromSettings()
                if hasSavedToken && !hasVerifiedToken {
                    verifySavedToken()
                }
            }
            .onDisappear {
                tokenVerificationTask?.cancel()
            }
            .onChange(of: settings.internetAccessEnabled) { _, _ in
                syncDraftsFromSettings()
            }
            .onChange(of: settings.subdomain) { _, _ in
                if !settings.internetAccessEnabled { syncDraftsFromSettings() }
            }
            .onChange(of: settings.selectedZoneID) { _, _ in
                if !settings.internetAccessEnabled { syncDraftsFromSettings() }
            }

        tokenRow

        Picker("Domain", selection: zoneSelection) {
            if availableZones.isEmpty {
                if !draftZoneName.isEmpty {
                    Text(draftZoneName).tag(draftZoneID)
                } else {
                    Text(isVerifyingToken ? "Loading…" : "None").tag("")
                }
            } else {
                if draftZoneID.isEmpty {
                    Text("Choose…").tag("")
                }
                ForEach(availableZones, id: \.id) { zone in
                    Text(zone.name).tag(zone.id)
                }
            }
        }
        .disabled(availableZones.isEmpty || isBusy)

        TextField("Subdomain", text: subdomainBinding, prompt: Text(AdminWebUISettings.defaultSubdomain))
            .disabled(isBusy)

        LabeledContent("Address") {
            HStack(spacing: 8) {
                Text(addressPreview)
                    .foregroundStyle(draftHostname.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if isInternetAccessActive && !hasPendingHostnameChange {
                    Button {
                        openURL()
                    } label: {
                        Image(systemName: "safari")
                    }
                    .buttonStyle(.borderless)
                    .help("Open in browser")

                    Button {
                        copyURL()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy address")
                }
            }
        }

        Toggle(isOn: $app.settings.adminWebUI.tunnelHealthCheckEnabled) {
            Text("Auto-repair tunnel")
            Text("Checks the address every 10 minutes and restarts the tunnel if it's been unreachable for about 30 minutes.")
        }
        .disabled(!settings.internetAccessEnabled)

        if let actionRow = actionRowContent {
            actionRow
        }
    }

    // MARK: Rows

    private var enableRow: some View {
        Toggle(isOn: Binding(
            get: { settings.internetAccessEnabled },
            set: { newValue in
                if newValue {
                    requestEnable()
                } else {
                    stop()
                }
            }
        )) {
            Text("Internet Access")
            Text(statusSubtitle.text)
                .foregroundStyle(statusSubtitle.color)
        }
        .disabled(isBusy || (!settings.internetAccessEnabled && !isConfigurationComplete))
    }

    @ViewBuilder
    private var tokenRow: some View {
        if showsTokenEntry {
            LabeledContent {
                HStack(spacing: 8) {
                    SecureField("API Token", text: $tokenDraft, prompt: Text("Paste token"))
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        .onSubmit(verifyDraftToken)
                        .disabled(isVerifyingToken)

                    if isVerifyingToken {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Verify", action: verifyDraftToken)
                            .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if isReplacingToken {
                        Button("Cancel") {
                            tokenVerificationTask?.cancel()
                            isVerifyingToken = false
                            isReplacingToken = false
                            tokenDraft = ""
                            tokenError = nil
                        }
                    }
                }
            } label: {
                Text("Cloudflare API Token")
                if let tokenError {
                    Text(tokenError).foregroundStyle(.red)
                } else {
                    Text("Needs Zone › DNS › Edit and Account › Cloudflare Tunnel › Edit. [Create a token…](https://dash.cloudflare.com/profile/api-tokens)")
                }
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    if isVerifyingToken {
                        ProgressView().controlSize(.small)
                        Text("Verifying…").foregroundStyle(.secondary)
                    } else if hasVerifiedToken {
                        Label("Verified", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if tokenError != nil {
                        Button("Retry", action: verifySavedToken)
                    }

                    Button("Replace…") {
                        tokenDraft = ""
                        tokenError = nil
                        isReplacingToken = true
                    }
                    .disabled(isVerifyingToken || isBusy)
                }
            } label: {
                Text("Cloudflare API Token")
                if let tokenError {
                    Text(tokenError).foregroundStyle(.red)
                } else {
                    Text("Stored in your Keychain.")
                }
            }
        }
    }

    private var actionRowContent: AnyView? {
        let showsConflict = lastError is CloudflareDNSProvider.TunnelDNSConflict && isConfigurationComplete
        let showsApply = hasPendingHostnameChange && isConfigurationComplete
        let showsRetry = settings.internetAccessEnabled && !isInternetAccessActive && !hasPendingHostnameChange
        let showsRepair = isInternetAccessActive && !hasPendingHostnameChange
        let feedback = setupFeedback

        guard !isBusy, showsConflict || showsApply || showsRetry || showsRepair || feedback != nil else {
            return nil
        }

        return AnyView(
            HStack(spacing: 8) {
                if let feedback {
                    Label(feedback.message, systemImage: feedback.status == .error ? "exclamationmark.octagon.fill" : "info.circle")
                        .font(.callout)
                        .foregroundStyle(feedback.status == .error ? .red : .secondary)
                        .lineLimit(2)
                } else if showsApply {
                    Text("Address changes take effect after setup re-runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if showsConflict {
                    Button("Override & Don't Warn Again") {
                        app.dismissDNSConflict(for: draftHostname)
                        commitDrafts()
                        requestEnable(forceReplaceDNS: true)
                    }
                    Button("Override DNS") {
                        commitDrafts()
                        requestEnable(forceReplaceDNS: true)
                    }
                    .buttonStyle(.borderedProminent)
                } else if showsApply {
                    Button("Revert") {
                        syncDraftsFromSettings()
                    }
                    Button("Apply Changes") {
                        commitDrafts()
                        requestEnable()
                    }
                    .buttonStyle(.borderedProminent)
                } else if showsRetry {
                    Button("Retry Setup") {
                        requestEnable()
                    }
                } else if showsRepair {
                    Button("Repair…") {
                        showingReRunSetupConfirmation = true
                    }
                }
            }
        )
    }

    // MARK: Bindings

    private var zoneSelection: Binding<String> {
        Binding(
            get: { draftZoneID },
            set: { newValue in
                draftZoneID = newValue
                lastError = nil
                if !settings.internetAccessEnabled { commitDrafts() }
            }
        )
    }

    private var subdomainBinding: Binding<String> {
        Binding(
            get: { draftSubdomain },
            set: { newValue in
                draftSubdomain = newValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
                lastError = nil
                if !settings.internetAccessEnabled { commitDrafts() }
            }
        )
    }

    private func syncDraftsFromSettings() {
        draftSubdomain = settings.subdomain
        draftZoneID = settings.selectedZoneID
    }

    private func commitDrafts() {
        let zoneName = draftZoneName
        app.settings.adminWebUI.subdomain = draftSubdomain
        app.settings.adminWebUI.selectedZoneID = draftZoneID
        app.settings.adminWebUI.selectedZoneName = zoneName
    }

    // MARK: Token verification

    private func verifyDraftToken() {
        let token = CloudflareDNSProvider.normalizedAPIToken(from: tokenDraft)
        guard !token.isEmpty else { return }
        verify(token: token, saveOnSuccess: true)
    }

    private func verifySavedToken() {
        let token = CloudflareDNSProvider.normalizedAPIToken(from: settings.cloudflareAPIToken)
        guard !token.isEmpty else { return }
        verify(token: token, saveOnSuccess: false)
    }

    /// Verifies a token and loads its zones. A replacement token is only saved
    /// once Cloudflare accepts it, so a typo never wipes a working setup.
    private func verify(token: String, saveOnSuccess: Bool) {
        tokenVerificationTask?.cancel()
        isVerifyingToken = true
        tokenError = nil

        tokenVerificationTask = Task { @MainActor in
            do {
                let zones = try await app.verifyCloudflareTokenAndListZones(token: token)
                guard !Task.isCancelled else { return }

                if saveOnSuccess {
                    app.settings.adminWebUI.cloudflareAPIToken = token
                    tokenDraft = ""
                    isReplacingToken = false
                }
                availableZones = zones
                hasVerifiedToken = true
                isVerifyingToken = false

                if !zones.contains(where: { $0.id == draftZoneID }) {
                    draftZoneID = zones.count == 1 ? zones[0].id : ""
                    if !settings.internetAccessEnabled { commitDrafts() }
                }
            } catch {
                guard !Task.isCancelled else { return }
                if !saveOnSuccess { hasVerifiedToken = false }
                isVerifyingToken = false
                tokenError = app.userFacingAdminWebPublicAccessMessage(for: error)
            }
        }
    }

    // MARK: Actions

    private func requestEnable(forceReplaceDNS: Bool = false) {
        if app.isFailoverManagedNode {
            showingNonPrimaryWarning = true
        } else {
            enable(forceReplaceDNS: forceReplaceDNS)
        }
    }

    private func enable(forceReplaceDNS: Bool = false) {
        guard !isEnabling else { return }

        if !settings.internetAccessEnabled { commitDrafts() }
        let fullHostname = settings.normalizedHostname

        guard !fullHostname.isEmpty else {
            setupFeedback = InternetAccessFeedback(status: .warning, message: "Choose a domain and subdomain first.")
            return
        }

        isEnabling = true
        setupFeedback = nil
        lastError = nil
        setupProgress = InternetAccessSetupProgress(hostname: fullHostname)
        showingSetupStatusWindow = true

        // Ensure settings are updated with the chosen hostname before starting
        app.settings.adminWebUI.hostname = fullHostname

        Task { @MainActor in
            do {
                _ = try await app.startInternetAccessSetup(
                    progress: { event in
                        guard var progress = setupProgress else { return }
                        progress.apply(event)
                        setupProgress = progress
                    },
                    forceReplaceDNS: forceReplaceDNS
                )
                guard !Task.isCancelled else { return }

                setupProgress = nil
                setupFeedback = nil
                isEnabling = false
                syncDraftsFromSettings()
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

    /// Stops the tunnel at runtime but keeps all configuration intact.
    private func stop() {
        guard !isDisabling else { return }

        isDisabling = true
        setupFeedback = nil
        lastError = nil

        Task { @MainActor in
            await app.stopInternetAccess()
            guard !Task.isCancelled else { return }

            setupProgress = nil
            isDisabling = false
        }
    }

    /// Destructive reset: removes tunnel, DNS record, and clears all stored configuration.
    private func reset() {
        guard !isDisabling else { return }

        isDisabling = true
        setupFeedback = nil
        lastError = nil
        availableZones = []
        hasVerifiedToken = false

        Task { @MainActor in
            await app.resetInternetAccess()
            guard !Task.isCancelled else { return }

            setupProgress = nil
            isDisabling = false
            syncDraftsFromSettings()
            if hasSavedToken { verifySavedToken() }
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
        "issue-certificate",
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
            "issue-certificate": .init(id: "issue-certificate", title: "Issue HTTPS certificate", status: .pending, detail: nil),
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
        case .issuingHTTPSCertificate(let hostname):
            setItem(id: "issue-certificate", status: .warning, detail: "Issuing certificate for \(hostname)…")
        case .httpsCertificateIssued(let hostname):
            setItem(id: "issue-certificate", status: .success, detail: "HTTPS certificate active for \(hostname).")
        case .startingCloudflareTunnel:
            setItem(id: "enable-access", status: .warning, detail: "Starting Cloudflare tunnel…")
        case .cloudflareTunnelStarted:
            setItem(id: "enable-access", status: .success, detail: "Internet Access enabled.")
        case .internetAccessEnabled:
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

private struct InternetAccessSetupStatusWindow: View {
    @Environment(\.dismiss) private var dismiss

    let items: [CertificateManager.ValidationItem]
    let feedback: InternetAccessFeedback?
    let isProcessing: Bool
    let currentProcessingItemID: String?

    private var title: String {
        if isProcessing {
            return "Setting Up Internet Access"
        }

        if feedback?.status == .error {
            return "Setup Needs Attention"
        }

        return "Internet Access Setup"
    }

    private var iconName: String {
        if isProcessing {
            return "network"
        }

        switch feedback?.status {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "exclamationmark.octagon.fill"
        case .pending, .none:
            return "network"
        }
    }

    private var iconColor: Color {
        if isProcessing {
            return .orange
        }

        return feedback?.status.color ?? .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .symbolRenderingMode(.hierarchical)

                Text(title)
                    .font(.headline.weight(.semibold))

                Spacer()

                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    AdminWebStatusRow(
                        title: item.title,
                        detail: item.detail,
                        status: item.status,
                        isProcessing: isProcessing && currentProcessingItemID == item.id
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.05), lineWidth: 1)
            )

            if let feedback {
                Label(
                    feedback.message,
                    systemImage: feedback.status == .error ? "exclamationmark.octagon.fill" : "info.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(feedback.status == .error ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(isProcessing ? "Setting Up..." : "Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isProcessing)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
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

    private func redirectURL(for _: String) -> String {
        app.adminWebDiscordRedirectURL()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Sign-in")
                .font(.headline.weight(.semibold))

            OAuthProviderCard(
                name: "Discord",
                icon: "message.fill",
                assetIcon: "DiscordLogo",
                color: .indigo,
                settings: $app.settings.adminWebUI.discordOAuth,
                redirectURL: app.adminWebDiscordRedirectURL()
            )

#if DEBUG
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local Fallback")
                            .font(.subheadline.weight(.semibold))
                        Text("Use a local username/password when Discord auth is unavailable during testing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $app.settings.adminWebUI.localAuthEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                if app.settings.adminWebUI.localAuthEnabled {
                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Username")
                            .font(.caption.weight(.medium))
                        TextField("admin", text: $app.settings.adminWebUI.localAuthUsername)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password")
                            .font(.caption.weight(.medium))
                        SecureField("Enter local fallback password", text: $app.settings.adminWebUI.localAuthPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    Text("Stored securely in your macOS Keychain.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            #endif // DEBUG (Local Fallback)


            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 12) {
                Toggle("Only allow specific users", isOn: $app.settings.adminWebUI.restrictAccessToSpecificUsers)
                    .toggleStyle(.switch)

                Text("By default, anyone who owns a connected server or has Administrator or Manage Server can sign in. Turn this on to allow only the users listed, server managers included. Password sign-in isn't affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if app.settings.adminWebUI.restrictAccessToSpecificUsers,
                   app.settings.adminWebUI.normalizedAllowedUserIDs.isEmpty {
                    Label("Nobody is listed, so server managers can still sign in until you add someone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

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
    let assetIcon: String?
    let color: Color
    @Binding var settings: OAuthProviderSettings
    let redirectURL: String

    @State private var showingOAuthSetup = false
    @State private var draftClientID = ""
    @State private var draftClientSecret = ""

    private var isConfigured: Bool {
        !settings.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                providerIcon
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    Text("Sign in with \(name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if settings.enabled {
                    HStack(spacing: 8) {
                        // Status Badge
                        HStack(spacing: 4) {
                            Circle()
                                .fill(isConfigured ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(isConfigured ? "Configured" : "Incomplete")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isConfigured ? .green : .orange)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill((isConfigured ? Color.green : Color.orange).opacity(0.12))
                        )
                    }
                    .transition(.opacity)
                }

                Toggle("", isOn: $settings.enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(14)

            if settings.enabled {
                Divider()
                    .padding(.horizontal, 14)

                if isConfigured {
                    HStack {
                        Label("\(name) OAuth configured", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)

                        Spacer()

                        Button {
                            openOAuthSetup()
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.borderless)
                        .help("Replace \(name) OAuth details")
                        .accessibilityLabel("Replace \(name) OAuth details")
                    }
                    .padding(14)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            openOAuthSetup()
                        } label: {
                            Label("Set Up \(name) OAuth", systemImage: "key.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        Label("\(name) OAuth is not configured yet.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .padding(14)
                }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $showingOAuthSetup) {
            oauthSetupSheet
        }
        .onChange(of: settings.enabled) { _, newValue in
            if newValue && !isConfigured {
                openOAuthSetup()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: settings.enabled)
        .animation(.easeInOut(duration: 0.2), value: isConfigured)
    }

    private var oauthSetupSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                providerIcon
                    .frame(width: 18, height: 18)
                Text(isConfigured ? "Replace \(name) OAuth Details" : "Set Up \(name) OAuth")
                    .font(.headline)
            }

            Text("Enter the client ID and client secret from your \(name) developer application. These are used only for Admin Web UI sign-in.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Form {
                TextField("Client ID", text: $draftClientID)
                    .textContentType(.username)
                SecureField("Client Secret", text: $draftClientSecret)
                    .textContentType(.password)
            }
            .formStyle(.grouped)

            VStack(alignment: .leading, spacing: 6) {
                Text("Redirect URL")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

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

                Text("Register this exact URL in your \(name) developer portal.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    showingOAuthSetup = false
                }
                Button("Save") {
                    saveOAuthDetails()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draftOAuthIsValid)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private var draftOAuthIsValid: Bool {
        !draftClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var providerIcon: some View {
        if let assetIcon {
            Image(assetIcon)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private func openOAuthSetup() {
        draftClientID = settings.clientID
        draftClientSecret = settings.clientSecret
        showingOAuthSetup = true
    }

    private func saveOAuthDetails() {
        settings.clientID = draftClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.clientSecret = draftClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        draftClientID = ""
        draftClientSecret = ""
        showingOAuthSetup = false
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
                    Label("Open in Browser", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(GlassActionButtonStyle())
                .disabled(!canLaunchAdminWebUI)
            } else {
                Button {
                    app.launchAdminWebUI()
                } label: {
                    Label("Open in Browser", systemImage: "arrow.up.right.square")
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

/// Warning shown when Admin Web UI is enabled but no authentication provider
/// (Discord OAuth, Apple/Steam/GitHub OAuth, or the local fallback) is fully
/// configured. Without one, no one can actually sign in — the dashboard sits
/// at the login screen with no working buttons.
struct AdminWebAuthMissingBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("No sign-in method configured")
                    .font(.subheadline.weight(.semibold))
                Text("The Web UI will start, but no one will be able to sign in. Add a Discord OAuth client (or enable a fallback provider) in the Authentication section below before sharing the URL.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
