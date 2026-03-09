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

                PreferencesCard("Public Access", systemImage: "network") {
                    AdminWebPublicAccessSection()
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
        provisioningProgress = AdminWebHTTPSProvisioningProgress(domain: app.settings.adminWebUI.normalizedHTTPSDomain)

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

            Text("SwiftBot checks the environment, creates the DNS challenge, waits for propagation, requests the certificate, and enables HTTPS automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

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
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
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
    var symbol: String {
        switch self {
        case .pending:
            return "○"
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
            return "Enabling"
        case .disabled:
            return "Disabled"
        case .error:
            return "Error"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Hostname")
                    .font(.subheadline.weight(.medium))
                TextField("swiftbot.example.com", text: $app.settings.adminWebUI.publicAccessHostname)
                    .textFieldStyle(.roundedBorder)
                    .disabled(app.settings.adminWebUI.publicAccessEnabled || isEnablingPublicAccess || isDisablingPublicAccess)
                Text("Cloudflare Tunnel will publish this hostname over HTTPS without requiring port forwarding.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Cloudflare API Token")
                    .font(.subheadline.weight(.medium))
                SecureField("Token with Tunnel and DNS edit access", text: $app.settings.adminWebUI.cloudflareAPIToken)
                    .textFieldStyle(.roundedBorder)
                    .disabled(app.settings.adminWebUI.publicAccessEnabled || isEnablingPublicAccess || isDisablingPublicAccess)
                Text("This reuses the same Cloudflare token setting as automatic HTTPS.")
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
                        Text("SwiftBot is available at \(publicURLString)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else if !app.adminWebPublicAccessStatus.detail.isEmpty {
                    Text(app.adminWebPublicAccessStatus.detail)
                        .font(.caption)
                        .foregroundStyle(app.adminWebPublicAccessStatus.state == .error ? .red : .secondary)
                }
            }

            if let setupProgress {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(setupProgress.items.enumerated()), id: \.element.id) { index, item in
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
            }

            HStack(spacing: 10) {
                if app.settings.adminWebUI.publicAccessEnabled {
                    Button("Open in Browser") {
                        openPublicAccessURL()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisablingPublicAccess || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    Button("Copy Public URL") {
                        copyPublicAccessURL()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisablingPublicAccess || publicURLString.isEmpty || !app.adminWebPublicAccessStatus.isEnabled)

                    Button("Disable Public Access") {
                        disablePublicAccess()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDisablingPublicAccess || isEnablingPublicAccess)
                } else {
                    Button("Enable Public Access") {
                        enablePublicAccess()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isEnablingPublicAccess || isDisablingPublicAccess)
                }

                if isEnablingPublicAccess || isDisablingPublicAccess {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let setupFeedback {
                Text(setupFeedback.message)
                    .font(.caption)
                    .foregroundStyle(setupFeedback.status.color)
            }
        }
    }

    private func enablePublicAccess() {
        guard !isEnablingPublicAccess else { return }

        isEnablingPublicAccess = true
        setupFeedback = nil
        setupProgress = AdminWebPublicAccessSetupProgress(hostname: app.settings.adminWebUI.normalizedPublicAccessHostname)

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
                    status: .error,
                    message: app.userFacingAdminWebPublicAccessMessage(for: error)
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
}

private struct AdminWebPublicAccessSetupProgress {
    private static let orderedStepIDs = [
        "cloudflare-access",
        "cloudflare-zone",
        "create-tunnel",
        "create-dns",
        "store-credentials",
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
                title: "Cloudflare Tunnel created",
                status: .pending,
                detail: nil
            ),
            "create-dns": .init(
                id: "create-dns",
                title: "Public DNS route created",
                status: .pending,
                detail: nil
            ),
            "store-credentials": .init(
                id: "store-credentials",
                title: "Tunnel credentials stored securely",
                status: .pending,
                detail: nil
            ),
            "start-public-access": .init(
                id: "start-public-access",
                title: "Public access enabled",
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
        case .creatingTunnelDNSRecord(let hostname):
            setItem(id: "create-dns", status: .warning, detail: "Creating the public DNS record for \(hostname).")
        case .tunnelDNSRecordCreated(let hostname):
            setItem(id: "create-dns", status: .success, detail: "Public DNS route created for \(hostname).")
        case .storingTunnelCredentials:
            setItem(id: "store-credentials", status: .warning, detail: "Saving the tunnel token to the macOS Keychain.")
        case .startingTunnelProcess:
            setItem(id: "store-credentials", status: .success, detail: "Tunnel credentials stored securely.")
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
