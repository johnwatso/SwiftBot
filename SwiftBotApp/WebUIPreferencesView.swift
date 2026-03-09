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
                    "HTTPS",
                    systemImage: "lock.shield",
                    subtitle: "Protect the Web UI with TLS certificates managed automatically or imported from an existing PEM."
                ) {
                    AdminWebHTTPSConfigurationSection()
                }

                PreferencesCard(
                    "Public Access",
                    systemImage: "network",
                    subtitle: "Expose SwiftBot securely over the internet without opening router ports."
                ) {
                    AdminWebPublicAccessSection()
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
                Text("Updates automatically when HTTPS or Public Access is configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AdminWebHTTPSConfigurationSection: View {
    @EnvironmentObject var app: AppModel
    @State private var cloudflaredInstallation: CertificateManager.CloudflaredInstallation?
    @State private var isDetectingCloudflared = false
    @State private var isRefreshingSetupStatus = false
    @State private var isCreatingDNSRecord = false
    @State private var isMonitoringPropagation = false
    @State private var isProvisioningCertificate = false
    @State private var validationResult: CertificateManager.AutomaticHTTPSValidation?
    @State private var provisioningProgress: AdminWebHTTPSProvisioningProgress?
    @State private var validationTask: Task<Void, Never>?
    @State private var propagationTask: Task<Void, Never>?
    @State private var setupFeedback: AdminWebHTTPSSetupFeedback?

    private var hostnameBinding: Binding<String> {
        sharedAdminWebHostnameBinding(for: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Hostname")
                    .font(.subheadline.weight(.medium))
                TextField("admin.example.com", text: hostnameBinding)
                    .textFieldStyle(.roundedBorder)
                Text("Used for HTTPS and Public Access when Cloudflare services are enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            detectCloudflaredInstallation()
            scheduleValidation(after: 150_000_000)
        }
        .onChange(of: validationInputSignature) { _, _ in
            resetValidationState()
            detectCloudflaredInstallation()
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
                Text("Cloudflare API Token")
                    .font(.subheadline.weight(.medium))
                SecureField("Token with DNS edit + Cloudflare Tunnel edit access", text: $app.settings.adminWebUI.cloudflareAPIToken)
                    .textFieldStyle(.roundedBorder)
                Text("Requires Zone DNS: Edit for HTTPS, and Account Cloudflare Tunnel: Edit for Public Access. Stored in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AdminWebHTTPSSetupStatusSection(
                validation: validationResult,
                provisioningItems: provisioningProgress?.items,
                cloudflaredInstallation: cloudflaredInstallation,
                isDetectingCloudflared: isDetectingCloudflared,
                isRefreshing: isRefreshingSetupStatus,
                isCreatingDNSRecord: isCreatingDNSRecord,
                isMonitoringPropagation: isMonitoringPropagation,
                isProvisioningCertificate: isProvisioningCertificate,
                feedback: setupFeedback,
                onRefresh: refreshSetupStatus,
                onOpenInstallGuide: openCloudflaredInstallGuide,
                onRetryCloudflaredDetection: detectCloudflaredInstallation,
                onCreateDNSRecord: createDNSRecord,
                onEnableHTTPS: startCertificateProvisioning,
                canEnableHTTPS: validationResult?.isReadyForCertificateRequest == true
                    && (cloudflaredInstallation?.isInstalled == true)
                    && !isDetectingCloudflared
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
            sharedAdminWebHostname(in: app.settings.adminWebUI),
            app.settings.adminWebUI.cloudflareAPIToken
        ].joined(separator: "|")
    }

    private func resetValidationState() {
        validationTask?.cancel()
        propagationTask?.cancel()
        validationTask = nil
        propagationTask = nil
        validationResult = nil
        provisioningProgress = nil
        isRefreshingSetupStatus = false
        isCreatingDNSRecord = false
        isMonitoringPropagation = false
        isProvisioningCertificate = false
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
                    message: creation.reusedExistingRecord
                        ? "DNS record verified. The required DNS record already exists and will be reused for certificate provisioning."
                        : "Created \(creation.type) record \(creation.name) -> \(creation.content) in \(creation.zoneName)."
                )
                isCreatingDNSRecord = false
                scheduleValidation(after: 750_000_000)
            } catch {
                guard !Task.isCancelled else { return }
                setupFeedback = AdminWebHTTPSSetupFeedback(
                    status: .error,
                    message: app.userFacingAdminWebHTTPSSetupMessage(for: error)
                )
                isCreatingDNSRecord = false
                scheduleValidation(after: 200_000_000)
            }
        }
    }

    private func startCertificateProvisioning() {
        guard !isProvisioningCertificate,
              validationResult?.isReadyForCertificateRequest == true,
              cloudflaredInstallation?.isInstalled == true
        else {
            return
        }

        isProvisioningCertificate = true
        setupFeedback = nil
        provisioningProgress = AdminWebHTTPSProvisioningProgress(domain: app.settings.adminWebUI.normalizedHostname)

        Task { @MainActor in
            do {
                let resultMessage = try await app.startAdminWebAutomaticHTTPSProvisioning { event in
                    guard var progress = provisioningProgress else {
                        return
                    }

                    progress.apply(event)
                    provisioningProgress = progress
                }
                guard !Task.isCancelled else { return }

                provisioningProgress = nil
                setupFeedback = AdminWebHTTPSSetupFeedback(
                    status: .success,
                    message: resultMessage
                )
                isProvisioningCertificate = false
                scheduleValidation(after: 300_000_000)
            } catch {
                guard !Task.isCancelled else { return }

                if var progress = provisioningProgress {
                    progress.markFailed(message: app.userFacingAdminWebHTTPSSetupMessage(for: error))
                    provisioningProgress = progress
                }
                setupFeedback = AdminWebHTTPSSetupFeedback(
                    status: .error,
                    message: app.userFacingAdminWebHTTPSSetupMessage(for: error)
                )
                isProvisioningCertificate = false
            }
        }
    }

    private func detectCloudflaredInstallation() {
        guard app.settings.adminWebUI.httpsEnabled,
              app.settings.adminWebUI.certificateMode == .automatic
        else {
            cloudflaredInstallation = nil
            isDetectingCloudflared = false
            return
        }

        isDetectingCloudflared = true

        Task { @MainActor in
            let installation = await Task.detached(priority: .userInitiated) {
                CertificateManager.detectCloudflaredInstallation()
            }.value

            guard !Task.isCancelled else { return }
            cloudflaredInstallation = installation
            isDetectingCloudflared = false
        }
    }

    private func openCloudflaredInstallGuide() {
        guard let url = URL(string: "https://formulae.brew.sh/formula/cloudflared") else {
            return
        }

        NSWorkspace.shared.open(url)
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

private struct AdminWebStatusDisplay {
    let title: String
    let detail: String?
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
        if isProcessing {
            return "arrow.triangle.2.circlepath"
        }

        switch status {
        case .pending:
            return "circle"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        if isProcessing {
            return .orange
        }
        return status.color
    }
}

private struct AdminWebHTTPSSetupStatusSection: View {
    let validation: CertificateManager.AutomaticHTTPSValidation?
    let provisioningItems: [CertificateManager.ValidationItem]?
    let cloudflaredInstallation: CertificateManager.CloudflaredInstallation?
    let isDetectingCloudflared: Bool
    let isRefreshing: Bool
    let isCreatingDNSRecord: Bool
    let isMonitoringPropagation: Bool
    let isProvisioningCertificate: Bool
    let feedback: AdminWebHTTPSSetupFeedback?
    let onRefresh: () -> Void
    let onOpenInstallGuide: () -> Void
    let onRetryCloudflaredDetection: () -> Void
    let onCreateDNSRecord: () -> Void
    let onEnableHTTPS: () -> Void
    let canEnableHTTPS: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Setup Status")
                    .font(.headline.weight(.semibold))
                Text("SwiftBot checks Cloudflare and DNS, then enables HTTPS when everything is ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    onRefresh()
                } label: {
                    Label("Refresh Status", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isRefreshing || isCreatingDNSRecord || isProvisioningCertificate || isDetectingCloudflared)

                if validation?.canCreateDNSRecord == true {
                    Button("Create DNS Record") {
                        onCreateDNSRecord()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRefreshing || isCreatingDNSRecord || isProvisioningCertificate || isDetectingCloudflared)
                }

                if isRefreshing || isCreatingDNSRecord || isMonitoringPropagation || isProvisioningCertificate || isDetectingCloudflared {
                    ProgressView()
                        .controlSize(.small)
                    Text(activityText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsCloudflaredWarning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("cloudflared is required to complete HTTPS setup.")
                        .font(.subheadline.weight(.medium))
                    Text("Install it with: brew install cloudflared")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button("Install Guide") {
                            onOpenInstallGuide()
                        }
                        .buttonStyle(.bordered)

                        Button("Retry Detection") {
                            onRetryCloudflaredDetection()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDetectingCloudflared)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            if let items = displayedItems {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        let display = displayText(for: item)
                        AdminWebStatusRow(
                            title: display.title,
                            detail: display.detail,
                            status: item.status,
                            isProcessing: item.id == activeProcessingItemID
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )

                if canEnableHTTPS && provisioningItems == nil {
                    Button("Enable HTTPS") {
                        onEnableHTTPS()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isRefreshing
                            || isCreatingDNSRecord
                            || isMonitoringPropagation
                            || isProvisioningCertificate
                            || isDetectingCloudflared
                            || !canEnableHTTPS
                    )
                }
            } else {
                Text("Checking current HTTPS setup…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let feedback {
                Text(feedback.message)
                    .font(.caption)
                    .foregroundStyle(feedback.status == .error ? .red : .secondary)
            }

            if isMonitoringPropagation {
                Text("Waiting for DNS. SwiftBot keeps checking automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var activityText: String {
        if isDetectingCloudflared {
            return "Checking for cloudflared…"
        }
        if isProvisioningCertificate {
            return currentProvisioningStepTitle ?? "Running HTTPS setup…"
        }
        if isCreatingDNSRecord {
            return "Creating DNS record…"
        }
        if isMonitoringPropagation {
            return "Re-checking DNS propagation…"
        }
        return "Checking setup…"
    }

    private var showsCloudflaredWarning: Bool {
        guard let cloudflaredInstallation else {
            return false
        }

        return !cloudflaredInstallation.isInstalled
    }

    private var displayedItems: [CertificateManager.ValidationItem]? {
        provisioningItems ?? validation?.items
    }

    private var currentProvisioningStepTitle: String? {
        provisioningItems?.first(where: { $0.status == .warning })?.title
    }

    private var activeProcessingItemID: String? {
        guard isRefreshing || isCreatingDNSRecord || isMonitoringPropagation || isProvisioningCertificate else {
            return nil
        }
        return displayedItems?.first(where: { $0.status == .warning })?.id
    }

    private func displayText(for item: CertificateManager.ValidationItem) -> AdminWebStatusDisplay {
        switch item.id {
        case "cloudflare-access":
            switch item.status {
            case .success:
                return .init(title: "Cloudflare API verified", detail: "Authentication is ready.")
            case .pending:
                return .init(title: "Cloudflare authentication", detail: "Will be checked when setup runs.")
            case .warning, .error:
                return .init(title: "Cloudflare authentication required", detail: "Add a Cloudflare API token to continue.")
            }
        case "cloudflare-zone":
            switch item.status {
            case .success:
                return .init(title: "Cloudflare zone detected", detail: "Domain zone is ready for DNS management.")
            case .pending:
                return .init(title: "Cloudflare zone", detail: "Will be checked when authentication is ready.")
            case .warning:
                return .init(title: "Cloudflare zone", detail: "Waiting for Cloudflare authentication.")
            case .error:
                return .init(title: "Cloudflare zone not detected", detail: "Verify the hostname is in your Cloudflare account.")
            }
        case "domain-resolves":
            switch item.status {
            case .success:
                return .init(title: "DNS record detected", detail: "The hostname is reachable through system DNS.")
            case .pending:
                return .init(title: "DNS record detection", detail: "Will be checked when setup runs.")
            case .warning:
                return .init(title: "DNS record detection", detail: "Waiting for DNS propagation.")
            case .error:
                return .init(title: "DNS record not detected yet", detail: "Create a DNS record to continue.")
            }
        case "dns-record-present":
            switch item.status {
            case .success:
                return .init(title: "Cloudflare DNS record ready", detail: "The DNS record is ready for certificate issuance.")
            case .pending:
                return .init(title: "Cloudflare DNS record", detail: "Will be checked during setup.")
            case .warning:
                let detail = item.detail?.contains("Skipped") == true
                    ? "Waiting for Cloudflare authentication."
                    : "DNS record not created yet."
                return .init(title: "Cloudflare DNS record", detail: detail)
            case .error:
                return .init(title: "Cloudflare DNS record", detail: "Waiting for Cloudflare authentication.")
            }
        case "ready":
            switch item.status {
            case .success:
                return .init(title: "Ready to enable HTTPS", detail: "All checks passed. You can request a certificate.")
            case .pending:
                return .init(title: "HTTPS setup", detail: "Checking configuration…")
            case .warning:
                return .init(title: "HTTPS setup", detail: "Waiting for DNS propagation.")
            case .error:
                return .init(title: "HTTPS setup", detail: "Complete the steps above to continue.")
            }
        default:
            return .init(title: item.title, detail: item.detail)
        }
    }
}

private struct AdminWebHTTPSProvisioningProgress {
    private static let orderedStepIDs = [
        "cloudflare-access",
        "cloudflare-zone",
        "dns-record-create",
        "dns-propagation",
        "dns-record-verify",
        "request-certificate",
        "store-certificate"
    ]

    private var itemsByID: [String: CertificateManager.ValidationItem]

    init(domain: String) {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemsByID = [
            "cloudflare-access": .init(
                id: "cloudflare-access",
                title: "Cloudflare API access verified",
                status: .pending,
                detail: nil
            ),
            "cloudflare-zone": .init(
                id: "cloudflare-zone",
                title: "Cloudflare zone detected",
                status: .pending,
                detail: normalizedDomain.isEmpty ? nil : "Preparing HTTPS setup for \(normalizedDomain)."
            ),
            "dns-record-create": .init(
                id: "dns-record-create",
                title: "DNS challenge record created",
                status: .pending,
                detail: nil
            ),
            "dns-propagation": .init(
                id: "dns-propagation",
                title: "DNS propagation confirmed",
                status: .pending,
                detail: nil
            ),
            "dns-record-verify": .init(
                id: "dns-record-verify",
                title: "DNS challenge record verified",
                status: .pending,
                detail: nil
            ),
            "request-certificate": .init(
                id: "request-certificate",
                title: "TLS certificate requested",
                status: .pending,
                detail: nil
            ),
            "store-certificate": .init(
                id: "store-certificate",
                title: "Certificate stored securely",
                status: .pending,
                detail: nil
            )
        ]
    }

    var items: [CertificateManager.ValidationItem] {
        Self.orderedStepIDs.compactMap { itemsByID[$0] }
    }

    mutating func apply(_ event: AdminWebAutomaticHTTPSSetupEvent) {
        switch event {
        case .verifyingCloudflareAccess:
            setItem(
                id: "cloudflare-access",
                status: .warning,
                detail: "Checking the configured Cloudflare API token."
            )
        case .cloudflareAccessVerified:
            setItem(
                id: "cloudflare-access",
                status: .success,
                detail: "Cloudflare API access verified."
            )
        case .detectingCloudflareZone(let domain):
            setItem(
                id: "cloudflare-zone",
                status: .warning,
                detail: "Detecting the Cloudflare zone for \(domain)."
            )
        case .cloudflareZoneDetected(let zone):
            setItem(
                id: "cloudflare-zone",
                status: .success,
                detail: "Using Cloudflare zone \(zone)."
            )
        case .creatingDNSChallengeRecord(let recordName):
            setItem(
                id: "dns-record-create",
                status: .warning,
                detail: "Creating TXT record \(recordName)."
            )
        case .dnsChallengeRecordCreated(let recordName, let reusedExistingRecord):
            setItem(
                id: "dns-record-create",
                status: .success,
                detail: reusedExistingRecord
                    ? "Existing DNS record \(recordName) will be reused for certificate provisioning."
                    : "Created TXT record \(recordName)."
            )
        case .waitingForDNSPropagation(let recordName):
            setItem(
                id: "dns-propagation",
                status: .warning,
                detail: "Waiting for public DNS to publish \(recordName)."
            )
        case .dnsChallengeRecordPropagated(let recordName):
            setItem(
                id: "dns-propagation",
                status: .success,
                detail: "Public DNS has propagated \(recordName)."
            )
        case .dnsChallengeRecordVerified(let recordName, let reusedExistingRecord):
            setItem(
                id: "dns-record-verify",
                status: .success,
                detail: reusedExistingRecord
                    ? "DNS challenge record verified. The existing TXT record \(recordName) is ready."
                    : "DNS challenge record verified via public DNS."
            )
        case .requestingTLSCertificate(let domain):
            setItem(
                id: "request-certificate",
                status: .warning,
                detail: "Requesting a TLS certificate for \(domain)."
            )
        case .tlsCertificateIssued(let domain):
            setItem(
                id: "request-certificate",
                status: .success,
                detail: "Let's Encrypt issued a TLS certificate for \(domain)."
            )
        case .storingCertificate:
            setItem(
                id: "store-certificate",
                status: .warning,
                detail: "Saving the certificate and private key securely."
            )
        case .certificateStored(let path):
            setItem(
                id: "store-certificate",
                status: .success,
                detail: "Certificate stored at \(path)."
            )
        case .enablingHTTPSListener:
            setItem(
                id: "store-certificate",
                status: .warning,
                detail: "Certificate stored. Starting the HTTPS listener."
            )
        case .httpsListenerEnabled(let url):
            setItem(
                id: "store-certificate",
                status: .success,
                detail: "Certificate stored and HTTPS enabled at \(url)."
            )
        }
    }

    mutating func markFailed(message: String) {
        guard let failingStepID = currentStepID else {
            return
        }

        setItem(id: failingStepID, status: .error, detail: message)
    }

    private var currentStepID: String? {
        if let warningID = Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .warning }) {
            return warningID
        }

        return Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .pending })
    }

    private mutating func setItem(id: String, status: CertificateManager.ValidationStatus, detail: String?) {
        guard let existing = itemsByID[id] else {
            return
        }

        itemsByID[id] = .init(
            id: existing.id,
            title: existing.title,
            status: status,
            detail: detail
        )
    }
}

private extension CertificateManager.ValidationStatus {
    var color: Color {
        switch self {
        case .pending:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct AdminWebPublicAccessFeedback {
    let status: CertificateManager.ValidationStatus
    let message: String
}

struct AdminWebPublicAccessSection: View {
    @EnvironmentObject var app: AppModel
    @State private var isEnablingPublicAccess = false
    @State private var isDisablingPublicAccess = false
    @State private var setupFeedback: AdminWebPublicAccessFeedback?
    @State private var setupProgress: AdminWebPublicAccessSetupProgress?

    private var publicURLString: String {
        app.adminWebPublicAccessURL()?.absoluteString ?? ""
    }

    private var sharedHostname: String {
        sharedAdminWebHostname(in: app.settings.adminWebUI)
    }

    private var hasCloudflareAuthentication: Bool {
        !app.settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canEnablePublicAccess: Bool {
        !app.settings.adminWebUI.publicAccessEnabled
            && !isEnablingPublicAccess
            && !isDisablingPublicAccess
            && hasCloudflareAuthentication
            && !sharedHostname.isEmpty
    }

    private var checklistItems: [CertificateManager.ValidationItem] {
        if let setupProgress {
            return setupProgress.items
        }

        if app.settings.adminWebUI.publicAccessEnabled, app.adminWebPublicAccessStatus.isEnabled {
            return [
                .init(id: "cloudflare-access", title: "Cloudflare API verified", status: .success, detail: "Cloudflare authentication is ready."),
                .init(id: "cloudflare-zone", title: "Cloudflare zone detected", status: .success, detail: "The hostname is associated with your Cloudflare account."),
                .init(id: "create-tunnel", title: "Create Cloudflare tunnel", status: .success, detail: "The Cloudflare tunnel is configured."),
                .init(id: "create-dns", title: "Configure DNS route", status: .success, detail: "Traffic is routed to the tunnel hostname."),
                .init(id: "start-public-access", title: "Enable public access", status: .success, detail: "SwiftBot is available at \(publicURLString).")
            ]
        }

        return [
            .init(
                id: "cloudflare-access",
                title: "Cloudflare API verified",
                status: hasCloudflareAuthentication ? .pending : .warning,
                detail: hasCloudflareAuthentication
                    ? "Ready to verify when Public Access starts."
                    : "Cloudflare authentication required to create a tunnel."
            ),
            .init(
                id: "cloudflare-zone",
                title: "Cloudflare zone detected",
                status: sharedHostname.isEmpty ? .pending : .pending,
                detail: sharedHostname.isEmpty
                    ? "Add a hostname in HTTPS to continue."
                    : "SwiftBot will detect the matching Cloudflare zone during setup."
            ),
            .init(
                id: "create-tunnel",
                title: "Cloudflare tunnel",
                status: .pending,
                detail: "Created or detected automatically during setup."
            ),
            .init(
                id: "create-dns",
                title: "Configure DNS route",
                status: .pending,
                detail: "Configured automatically during setup."
            ),
            .init(
                id: "start-public-access",
                title: "Enable public access",
                status: canEnablePublicAccess ? .pending : .pending,
                detail: canEnablePublicAccess ? "Ready when you choose Enable Public Access." : "Complete the items above to continue."
            )
        ]
    }

    private var statusColor: Color {
        switch app.adminWebPublicAccessStatus.state {
        case .enabled:
            return .green
        case .enabling:
            return .orange
        case .disabled:
            return .secondary
        case .error:
            return .red
        }
    }

    private var statusText: String {
        switch app.adminWebPublicAccessStatus.state {
        case .enabled:
            return "Enabled"
        case .enabling:
            return "Setting up"
        case .disabled:
            return "Disabled"
        case .error:
            return "Needs attention"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hostname")
                    .font(.subheadline.weight(.medium))
                TextField("Set a hostname in HTTPS", text: .constant(sharedHostname))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)
                Text("Uses the same hostname and Cloudflare authentication configured for HTTPS.")
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

                if app.adminWebPublicAccessStatus.isEnabled, !publicURLString.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Public access enabled")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("SwiftBot is available at: \(publicURLString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Traffic is routed securely through Cloudflare Tunnel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !app.adminWebPublicAccessStatus.detail.isEmpty {
                    Text(app.adminWebPublicAccessStatus.detail)
                        .font(.caption)
                        .foregroundStyle(app.adminWebPublicAccessStatus.state == .error ? .red : .secondary)
                } else {
                    Text("Public access disabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                            isProcessing: isEnablingPublicAccess && checklistItems.first(where: { $0.status == .warning })?.id == item.id
                        )
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack(spacing: 10) {
                if app.settings.adminWebUI.publicAccessEnabled {
                    Button("Open in Browser") {
                        openPublicAccessURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisablingPublicAccess || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    Button("Copy URL") {
                        copyPublicAccessURL()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisablingPublicAccess || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    Button("Disable Public Access") {
                        disablePublicAccess()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisablingPublicAccess || isEnablingPublicAccess)
                } else if canEnablePublicAccess {
                    Button("Enable Public Access") {
                        enablePublicAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }

                if isEnablingPublicAccess || isDisablingPublicAccess {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !hasCloudflareAuthentication {
                Label("Cloudflare authentication required to create a tunnel.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let setupFeedback {
                Text(setupFeedback.message)
                    .font(.caption)
                    .foregroundStyle(setupFeedback.status == .error ? .red : .secondary)
            }
        }
    }

    private func enablePublicAccess() {
        guard !isEnablingPublicAccess else { return }

        isEnablingPublicAccess = true
        setupFeedback = nil
        setupProgress = AdminWebPublicAccessSetupProgress(hostname: app.settings.adminWebUI.normalizedHostname)

        Task { @MainActor in
            do {
                let resultMessage = try await app.startAdminWebPublicAccessSetup { event in
                    guard var progress = setupProgress else {
                        return
                    }

                    progress.apply(event)
                    setupProgress = progress
                }
                guard !Task.isCancelled else { return }

                setupProgress = nil
                setupFeedback = AdminWebPublicAccessFeedback(status: .success, message: resultMessage)
                isEnablingPublicAccess = false
            } catch {
                guard !Task.isCancelled else { return }

                if var progress = setupProgress {
                    progress.markFailed(message: app.userFacingAdminWebPublicAccessMessage(for: error))
                    setupProgress = progress
                }
                setupFeedback = AdminWebPublicAccessFeedback(
                    status: feedbackStatus(for: error),
                    message: neutralPublicAccessMessage(for: error)
                )
                isEnablingPublicAccess = false
            }
        }
    }

    private func disablePublicAccess() {
        guard !isDisablingPublicAccess else { return }

        isDisablingPublicAccess = true
        setupFeedback = nil

        Task { @MainActor in
            await app.disableAdminWebPublicAccess()
            guard !Task.isCancelled else { return }

            setupProgress = nil
            setupFeedback = AdminWebPublicAccessFeedback(
                status: .success,
                message: "Public access disabled"
            )
            isDisablingPublicAccess = false
        }
    }

    private func openPublicAccessURL() {
        guard let url = app.adminWebPublicAccessURL() else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func copyPublicAccessURL() {
        guard !publicURLString.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURLString, forType: .string)
        setupFeedback = AdminWebPublicAccessFeedback(
            status: .success,
            message: "Public URL copied"
        )
    }

    private func feedbackStatus(for error: Error) -> CertificateManager.ValidationStatus {
        let userMessage = app.userFacingAdminWebPublicAccessMessage(for: error)
        switch error {
        case CertificateManager.Error.missingCloudflareToken,
             CertificateManager.Error.inactiveCloudflareToken,
             CloudflareDNSProvider.Error.zoneNotFound:
            return .warning
        default:
            return userMessage.localizedCaseInsensitiveContains("public hostname")
                ? .warning
                : .error
        }
    }

    private func neutralPublicAccessMessage(for error: Error) -> String {
        let userMessage = app.userFacingAdminWebPublicAccessMessage(for: error)
        switch error {
        case CertificateManager.Error.missingCloudflareToken,
             CertificateManager.Error.inactiveCloudflareToken:
            return "Cloudflare authentication required to create a tunnel."
        case CloudflareDNSProvider.Error.zoneNotFound:
            return "The hostname is not available in the current Cloudflare account yet."
        case let tunnelError as CloudflareTunnelClient.Error:
            switch tunnelError {
            case .apiFailed(let message)
                where message.localizedCaseInsensitiveContains("auth")
                    || message.localizedCaseInsensitiveContains("permission")
                    || message.localizedCaseInsensitiveContains("forbidden")
                    || message.localizedCaseInsensitiveContains("10000"):
                return "The Cloudflare API token needs 'Cloudflare Tunnel: Edit' permission. Update your token in the Cloudflare dashboard and try again."
            default:
                return userMessage
            }
        default:
            if userMessage.localizedCaseInsensitiveContains("public hostname") {
                return "Add a hostname in HTTPS to continue."
            }
            if userMessage.localizedCaseInsensitiveContains("authentication error")
                || userMessage.localizedCaseInsensitiveContains("10000") {
                return "The Cloudflare API token needs 'Cloudflare Tunnel: Edit' permission. Update your token in the Cloudflare dashboard and try again."
            }
            return userMessage
        }
    }
}

private struct AdminWebPublicAccessSetupProgress {
    private static let orderedStepIDs = [
        "cloudflare-access",
        "cloudflare-zone",
        "create-tunnel",
        "create-dns",
        "start-public-access"
    ]

    private var itemsByID: [String: CertificateManager.ValidationItem]

    init(hostname: String) {
        let normalizedHostname = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        self.itemsByID = [
            "cloudflare-access": .init(
                id: "cloudflare-access",
                title: "Cloudflare API access verified",
                status: .pending,
                detail: nil
            ),
            "cloudflare-zone": .init(
                id: "cloudflare-zone",
                title: "Cloudflare zone detected",
                status: .pending,
                detail: normalizedHostname.isEmpty ? nil : "Preparing Public Access for \(normalizedHostname)."
            ),
            "create-tunnel": .init(
                id: "create-tunnel",
                title: "Create Cloudflare tunnel",
                status: .pending,
                detail: nil
            ),
            "create-dns": .init(
                id: "create-dns",
                title: "Configure DNS route",
                status: .pending,
                detail: nil
            ),
            "start-public-access": .init(
                id: "start-public-access",
                title: "Enable public access",
                status: .pending,
                detail: nil
            )
        ]
    }

    var items: [CertificateManager.ValidationItem] {
        Self.orderedStepIDs.compactMap { itemsByID[$0] }
    }

    mutating func apply(_ event: AdminWebPublicAccessSetupEvent) {
        switch event {
        case .verifyingCloudflareAccess:
            setItem(id: "cloudflare-access", status: .warning, detail: "Checking the configured Cloudflare API token.")
        case .cloudflareAccessVerified:
            setItem(id: "cloudflare-access", status: .success, detail: "Cloudflare API access verified.")
        case .detectingCloudflareZone(let domain):
            setItem(id: "cloudflare-zone", status: .warning, detail: "Detecting the Cloudflare zone for \(domain).")
        case .cloudflareZoneDetected(let zone):
            setItem(id: "cloudflare-zone", status: .success, detail: "Using Cloudflare zone \(zone).")
        case .creatingTunnel(let hostname):
            setItem(id: "create-tunnel", status: .warning, detail: "Creating a Cloudflare Tunnel for \(hostname).")
        case .tunnelCreated(let name):
            setItem(id: "create-tunnel", status: .success, detail: "Created tunnel \(name).")
        case .tunnelDetected(let name):
            setItem(id: "create-tunnel", title: "Cloudflare tunnel detected", status: .success, detail: "Using existing tunnel \(name).")
        case .creatingTunnelDNSRecord(let hostname):
            setItem(id: "create-dns", status: .warning, detail: "Configuring the DNS route for \(hostname).")
        case .tunnelDNSRecordCreated(let hostname):
            setItem(id: "create-dns", status: .success, detail: "DNS route configured for \(hostname).")
        case .storingTunnelCredentials:
            setItem(id: "start-public-access", status: .warning, detail: "Saving tunnel access securely.")
        case .startingTunnelProcess:
            setItem(id: "start-public-access", status: .warning, detail: "Starting cloudflared in the background.")
        case .publicAccessEnabled(let url):
            setItem(id: "start-public-access", status: .success, detail: "SwiftBot is available at \(url).")
        }
    }

    mutating func markFailed(message: String) {
        guard let failingStepID = currentStepID else {
            return
        }

        setItem(id: failingStepID, status: .error, detail: message)
    }

    private var currentStepID: String? {
        if let warningID = Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .warning }) {
            return warningID
        }

        return Self.orderedStepIDs.first(where: { itemsByID[$0]?.status == .pending })
    }

    private mutating func setItem(id: String, title: String? = nil, status: CertificateManager.ValidationStatus, detail: String?) {
        guard let existing = itemsByID[id] else {
            return
        }

        itemsByID[id] = .init(
            id: existing.id,
            title: title ?? existing.title,
            status: status,
            detail: detail
        )
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
