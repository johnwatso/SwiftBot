import SwiftUI
import AppKit

// MARK: - Standalone Setup View

struct StandaloneSetupView: View {
    @EnvironmentObject var app: AppModel
    let onBack: () -> Void

    @State private var step: StandaloneStep = .entry
    @State private var inviteURL: String?
    @State private var inviteConfirmed: Bool = false
    @State private var isLoadingInviteURL: Bool = false
    @State private var inviteLoadFailed: Bool = false
    @State private var errorMessage: String?

    // Local sign-in onboarding state
    @State private var localUsernameDraft = "admin"
    @State private var localPasswordDraft = ""

    // Internet Access onboarding state
    @State private var cfTokenDraft = ""
    @State private var cfTokenError: String?
    @State private var isCFTokenVerifying = false
    @State private var cfTokenVerified = false
    @State private var cfAvailableZones: [CloudflareDNSProvider.ZoneSummary] = []
    @State private var cfSelectedZoneID = ""
    @State private var cfSubdomain = AdminWebUISettings.defaultSubdomain
    @State private var isSettingUpInternetAccess = false
    @State private var internetAccessSetupProgress: OnboardingInternetAccessProgress?
    @State private var internetAccessSetupError: String?

    private enum StandaloneStep {
        case entry, validating, proceedingToDashboard, confirmed, failed
        case localSignIn, internetAccess
    }

    private var errorMessageToShow: String? {
        if let msg = errorMessage { return msg }
        if let result = app.lastTokenValidationResult, !result.isValid { return result.errorMessage }
        return nil
    }

    var body: some View {
        VStack(spacing: 16) {
            // Error banner
            if let errorMsg = errorMessageToShow {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection Failed")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(errorMsg)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(colorSchemeIntensity))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.35), lineWidth: 1)
                )
                .frame(maxWidth: 520)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            switch step {
            case .entry, .failed:
                entryView
                    .transition(.opacity)
            case .validating:
                validatingView
                    .transition(.opacity)
            case .proceedingToDashboard:
                proceedingView
                    .transition(.opacity)
            case .confirmed:
                confirmedView
                    .transition(.opacity)
            case .localSignIn:
                localSignInStepView
                    .transition(.opacity)
            case .internetAccess:
                internetAccessStepView
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.22), value: step)
    }

    // MARK: - Subviews

    private var entryView: some View {
        VStack(spacing: 24) {
            ConsoleIconTile(symbol: "doc.on.clipboard.fill", size: 64)
            
            VStack(spacing: 8) {
                Text("Connect Your Bot")
                    .font(.title2.weight(.bold))
                
                Text("Copy your bot token from the Discord Developer Portal, then click **Paste & Connect** below. SwiftBot will automatically configure and secure your connection.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)
            
            VStack(spacing: 12) {
                Button {
                    handlePasteAndConnect()
                } label: {
                    Label("Paste & Connect", systemImage: "doc.on.clipboard.fill")
                        .font(.headline)
                        .frame(minWidth: 220)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                
                HStack(spacing: 16) {
                    Button(action: onBack) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    
                    Text("•")
                        .foregroundStyle(.tertiary)
                    
                    Button {
                        if let url = URL(string: "https://discord.com/developers/applications") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Developer Portal", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 4)
            }
        }
    }

    private var validatingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
            Text("Validating token & connecting…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 200)
    }

    private var proceedingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.green)
                .symbolEffect(.bounce, options: .nonRepeating)
                .accessibilityHidden(true)
            
            VStack(spacing: 8) {
                if let username = app.lastTokenValidationResult?.username {
                    Text("Connected as \(username)!")
                        .font(.title3.weight(.bold))
                } else {
                    Text("Connected!")
                        .font(.title3.weight(.bold))
                }
                
                Text("Your bot is already in a server. Continuing setup…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 200)
    }

    private var confirmedView: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                if let username = app.lastTokenValidationResult?.username {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Connected as **\(username)**")
                    }
                    .font(.headline)
                }
                
                Text("We've automatically opened the Discord authorization page in your browser. Please invite the bot to your server, then click below to enter.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)

            if isLoadingInviteURL {
                loadingInviteView
            } else if inviteLoadFailed {
                failedInviteView
            }

            if let url = inviteURL {
                inviteLinkView(url: url)

                Toggle(isOn: $inviteConfirmed) {
                    Text("I have invited SwiftBot already")
                        .font(.callout)
                }
                .toggleStyle(.switch)
                .frame(maxWidth: 520, alignment: .center)
            }

            Button { step = .localSignIn } label: {
                Label("Continue Setup", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 200)
            }
            .onboardingGlassButton()
            .disabled(inviteURL != nil && !inviteConfirmed)
        }
        .task {
            if inviteURL == nil {
                isLoadingInviteURL = true
                inviteURL = await app.generateInviteURL()
                isLoadingInviteURL = false
                inviteLoadFailed = (inviteURL == nil)
            }
        }
    }

    private var loadingInviteView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Generating invite link…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Generating invite link, please wait")
    }

    private var failedInviteView: some View {
        Text("Could not generate an invite link. Your bot's client ID may not be available yet — you can invite the bot manually from the Discord Developer Portal.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 560)
    }

    private func inviteLinkView(url: String) -> some View {
        VStack(spacing: 8) {
            Text("Invite your bot to a server:")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Copy Invite Link", systemImage: "doc.on.doc")
                }
                .onboardingGlassButton()
                .accessibilityHint("Copies the bot invite link to your clipboard")

                Button {
                    if let u = URL(string: url) {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Label("Open Invite", systemImage: "arrow.up.right.square")
                }
                .onboardingGlassButton()
                .accessibilityHint("Opens the Discord bot authorization page in your browser")
            }
        }
        .padding(12)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    // MARK: - Helpers

    @Environment(\.colorScheme) private var colorScheme

    private var colorSchemeIntensity: Double {
        colorScheme == .dark ? 0.08 : 0.04
    }

    private func handlePasteAndConnect() {
        let pasteboard = NSPasteboard.general
        guard let pastedToken = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pastedToken.isEmpty else {
            errorMessage = "Your clipboard is empty or does not contain text. Please copy your bot token first."
            step = .failed
            return
        }

        // Simple sanity check: Discord tokens are long and contain dots.
        guard pastedToken.contains(".") else {
            errorMessage = "The text in your clipboard does not look like a valid Discord bot token. Please check and copy the correct token."
            step = .failed
            return
        }

        app.settings.launchMode = .standaloneBot
        app.settings.token = pastedToken
        errorMessage = nil
        step = .validating

        Task {
            let ok = await app.validateAndOnboard()
            if ok {
                let inGuild = await app.checkBotInAnyGuild()
                if inGuild {
                    step = .proceedingToDashboard
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    await MainActor.run {
                        step = .localSignIn
                    }
                } else {
                    step = .confirmed
                    // Automatically open the invite link in browser if not in guild!
                    if let urlString = await app.generateInviteURL(), let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
            } else {
                step = .failed
            }
        }
    }

    // MARK: - Web UI Login

    private var localSignInStepView: some View {
        VStack(spacing: 24) {
            ConsoleIconTile(symbol: "person.badge.key.fill", size: 64)

            VStack(spacing: 8) {
                Text("Web UI Login")
                    .font(.title2.weight(.bold))

                Text("Create a username and password to sign in to your bot's dashboard.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Username")
                        .font(.subheadline.weight(.semibold))
                    TextField("admin", text: $localUsernameDraft)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Password")
                        .font(.subheadline.weight(.semibold))
                    SecureField("Choose a password", text: $localPasswordDraft)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(14)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .frame(maxWidth: 420)

            VStack(spacing: 12) {
                Button {
                    saveLocalAuthSettings()
                    step = .internetAccess
                } label: {
                    Label("Continue", systemImage: "arrow.right.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 200)
                }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
                .disabled(localPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    saveLocalAuthSettings()
                    app.saveSettings()
                    app.completeOnboarding()
                } label: {
                    Text("Skip & Go to Dashboard")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .disabled(localPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Step 3: Internet Access (optional)

    private var internetAccessStepView: some View {
        VStack(spacing: 24) {
            if let assetImage = NSImage(named: "CloudflareLogo") {
                Image(nsImage: assetImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            } else {
                ConsoleIconTile(symbol: "network", size: 64)
            }

            VStack(spacing: 8) {
                Text("Internet Access")
                    .font(.title2.weight(.bold))

                Text("Connect a Cloudflare account to give your dashboard a public HTTPS address. SwiftBot creates a secure tunnel automatically.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)

            VStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cloudflare API Token")
                        .font(.subheadline.weight(.semibold))

                    Text("Needs **Zone > DNS > Edit** and **Account > Cloudflare Tunnel > Edit** permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        SecureField("Cloudflare API Token", text: $cfTokenDraft)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isCFTokenVerifying || cfTokenVerified)

                        if cfTokenVerified {
                            Label("Verified", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        } else {
                            Button(isCFTokenVerifying ? "Verifying…" : "Verify") {
                                verifyCFToken()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isCFTokenVerifying || cfTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }

                    if let cfTokenError {
                        Label(cfTokenError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        if let url = URL(string: "https://dash.cloudflare.com/profile/api-tokens") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Create a token…", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if cfTokenVerified {
                    Divider()

                    HStack {
                        Text("Domain")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Picker("Domain", selection: $cfSelectedZoneID) {
                            if cfSelectedZoneID.isEmpty {
                                Text("Choose…").tag("")
                            }
                            ForEach(cfAvailableZones, id: \.id) { zone in
                                Text(zone.name).tag(zone.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    HStack {
                        Text("Subdomain")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        TextField("swiftbot", text: cfSubdomainBinding)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 160)
                    }

                    if !cfOnboardingHostname.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                                .foregroundStyle(.secondary)
                            Text("https://\(cfOnboardingHostname)")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if let internetAccessSetupProgress {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(internetAccessSetupProgress.items) { item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.status == .success ? "checkmark.circle.fill" : item.status == .warning ? "arrow.triangle.2.circlepath" : "circle")
                                        .font(.caption)
                                        .foregroundStyle(item.status == .success ? .green : item.status == .warning ? .orange : .secondary)
                                    Text(item.title)
                                        .font(.caption)
                                }
                            }
                        }
                    }

                    if let internetAccessSetupError {
                        Label(internetAccessSetupError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(14)
            .background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .frame(maxWidth: 420)
            .animation(.smooth(duration: 0.2), value: cfTokenVerified)

            VStack(spacing: 12) {
                if cfTokenVerified && !cfSelectedZoneID.isEmpty && !cfSubdomain.isEmpty {
                    Button {
                        startInternetAccessSetup()
                    } label: {
                        Label(
                            isSettingUpInternetAccess ? "Setting Up…" : "Enable Internet Access",
                            systemImage: "bolt.fill"
                        )
                        .font(.headline)
                        .frame(minWidth: 220)
                    }
                    .buttonStyle(GlassActionButtonStyle())
                    .controlSize(.large)
                    .disabled(isSettingUpInternetAccess)
                }

                Button {
                    app.saveSettings()
                    app.completeOnboarding()
                } label: {
                    Text(cfTokenVerified ? "Skip & Go to Dashboard" : "Skip for Now")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                .disabled(isSettingUpInternetAccess)
            }
        }
    }

    private func saveLocalAuthSettings() {
        let username = localUsernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = localPasswordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        app.settings.adminWebUI.enabled = true
        if !password.isEmpty {
            app.settings.adminWebUI.localAuthEnabled = true
            app.settings.adminWebUI.localAuthUsername = username.isEmpty ? "admin" : username
            app.settings.adminWebUI.localAuthPassword = password
        }
    }

    // MARK: - Internet Access Helpers

    private var cfSubdomainBinding: Binding<String> {
        Binding(
            get: { cfSubdomain },
            set: { newValue in
                cfSubdomain = newValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            }
        )
    }

    private var cfSelectedZoneName: String {
        cfAvailableZones.first(where: { $0.id == cfSelectedZoneID })?.name ?? ""
    }

    private var cfOnboardingHostname: String {
        let sub = cfSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = cfSelectedZoneName
        guard !sub.isEmpty, !zone.isEmpty else { return "" }
        return "\(sub).\(zone)"
    }

    private func verifyCFToken() {
        let token = CloudflareDNSProvider.normalizedAPIToken(from: cfTokenDraft)
        guard !token.isEmpty else { return }
        isCFTokenVerifying = true
        cfTokenError = nil

        Task { @MainActor in
            do {
                let zones = try await app.verifyCloudflareTokenAndListZones(token: token)
                cfAvailableZones = zones
                cfTokenVerified = true
                isCFTokenVerifying = false
                app.settings.adminWebUI.cloudflareAPIToken = token
                if zones.count == 1 {
                    cfSelectedZoneID = zones[0].id
                }
            } catch {
                isCFTokenVerifying = false
                cfTokenError = app.userFacingAdminWebPublicAccessMessage(for: error)
            }
        }
    }

    private func startInternetAccessSetup() {
        let hostname = cfOnboardingHostname
        guard !hostname.isEmpty else { return }

        app.settings.adminWebUI.enabled = true
        app.settings.adminWebUI.subdomain = cfSubdomain
        app.settings.adminWebUI.selectedZoneID = cfSelectedZoneID
        app.settings.adminWebUI.selectedZoneName = cfSelectedZoneName
        app.settings.adminWebUI.hostname = hostname
        app.saveSettings()

        isSettingUpInternetAccess = true
        internetAccessSetupError = nil
        internetAccessSetupProgress = OnboardingInternetAccessProgress()

        Task { @MainActor in
            do {
                _ = try await app.startInternetAccessSetup(progress: { event in
                    internetAccessSetupProgress?.apply(event)
                })
                isSettingUpInternetAccess = false
                internetAccessSetupProgress = nil
                app.saveSettings()
                app.completeOnboarding()
            } catch {
                isSettingUpInternetAccess = false
                internetAccessSetupError = app.userFacingAdminWebPublicAccessMessage(for: error)
            }
        }
    }
}

// MARK: - Onboarding Internet Access Progress

private struct OnboardingInternetAccessProgress {
    private static let orderedStepIDs = [
        "cloudflare-access", "cloudflare-zone", "create-tunnel",
        "create-dns", "issue-certificate", "enable-access"
    ]

    private var itemsByID: [String: CertificateManager.ValidationItem] = [
        "cloudflare-access": .init(id: "cloudflare-access", title: "Verify Cloudflare API", status: .pending, detail: nil),
        "cloudflare-zone": .init(id: "cloudflare-zone", title: "Detect zone", status: .pending, detail: nil),
        "create-tunnel": .init(id: "create-tunnel", title: "Detect or create tunnel", status: .pending, detail: nil),
        "create-dns": .init(id: "create-dns", title: "Configure DNS route", status: .pending, detail: nil),
        "issue-certificate": .init(id: "issue-certificate", title: "Issue HTTPS certificate", status: .pending, detail: nil),
        "enable-access": .init(id: "enable-access", title: "Enable Internet Access", status: .pending, detail: nil)
    ]

    var items: [CertificateManager.ValidationItem] {
        Self.orderedStepIDs.compactMap { itemsByID[$0] }
    }

    mutating func apply(_ event: InternetAccessSetupEvent) {
        switch event {
        case .verifyingCloudflareAccess:
            setItem(id: "cloudflare-access", status: .warning, detail: nil)
        case .cloudflareAccessVerified:
            setItem(id: "cloudflare-access", status: .success, detail: nil)
        case .detectingCloudflareZone:
            setItem(id: "cloudflare-zone", status: .warning, detail: nil)
        case .cloudflareZoneDetected:
            setItem(id: "cloudflare-zone", status: .success, detail: nil)
        case .creatingTunnel:
            setItem(id: "create-tunnel", status: .warning, detail: nil)
        case .tunnelCreated, .tunnelDetected:
            setItem(id: "create-tunnel", status: .success, detail: nil)
        case .creatingTunnelDNSRecord:
            setItem(id: "create-dns", status: .warning, detail: nil)
        case .tunnelDNSRecordCreated:
            setItem(id: "create-dns", status: .success, detail: nil)
        case .issuingHTTPSCertificate:
            setItem(id: "issue-certificate", status: .warning, detail: nil)
        case .httpsCertificateIssued:
            setItem(id: "issue-certificate", status: .success, detail: nil)
        case .startingCloudflareTunnel:
            setItem(id: "enable-access", status: .warning, detail: nil)
        case .cloudflareTunnelStarted:
            setItem(id: "enable-access", status: .success, detail: nil)
        case .internetAccessEnabled:
            break
        }
    }

    private mutating func setItem(id: String, status: CertificateManager.ValidationStatus, detail: String?) {
        guard let existing = itemsByID[id] else { return }
        itemsByID[id] = .init(id: existing.id, title: existing.title, status: status, detail: detail)
    }
}

// MARK: - Preview

#Preview {
    StandaloneSetupView(onBack: {})
        .environmentObject(AppModel())
        .padding()
        .frame(width: 600, height: 400)
}
