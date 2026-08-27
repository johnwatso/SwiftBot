import SwiftUI

/// Configuration sheet for one Game Tracking data provider.
///
/// Driven entirely by the provider's descriptor — the credential label, the
/// explanation, whether a rank endpoint contract even applies — so a second
/// provider gets this sheet for free with no branching added here.
struct GameProviderConfigurationSheet: View {
    let descriptor: GameProviderDescriptor
    let onCancel: () -> Void
    let onConnect: (GameProviderConnectionSettings) -> Void

    @State private var draft: GameProviderConnectionSettings
    @State private var isTokenRevealed = false
    @State private var isShowingAdvanced: Bool
    /// Populated only by a failed Connect attempt. A provider that has never
    /// been configured must not be greeted with a validation error.
    @State private var validationMessage: String?

    init(
        descriptor: GameProviderDescriptor,
        connection: GameProviderConnectionSettings,
        onCancel: @escaping () -> Void,
        onConnect: @escaping (GameProviderConnectionSettings) -> Void
    ) {
        self.descriptor = descriptor
        self.onCancel = onCancel
        self.onConnect = onConnect
        _draft = State(initialValue: connection)
        // Open Advanced up front only when it is the thing standing in the way.
        _isShowingAdvanced = State(
            initialValue: connection.hasCredential
                && connection.issue(for: descriptor) != nil
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section {
                    LabeledContent(descriptor.auth.credentialLabel) {
                        credentialField
                    }
                } footer: {
                    Text("Credentials are stored in the macOS Keychain, never in SwiftBot's settings file.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    DisclosureGroup("Advanced API Contract", isExpanded: $isShowingAdvanced) {
                        advancedFields
                            .padding(.top, 6)
                    }
                }

                if let validationMessage {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 420)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            IntegrationSymbolIcon(systemName: descriptor.symbolName)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Configure \(descriptor.id.displayName)")
                    .font(.title3.weight(.semibold))
                Text(descriptor.tagline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(descriptor.capabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - Fields

    private var credentialField: some View {
        HStack(spacing: 8) {
            Group {
                if isTokenRevealed {
                    TextField("Provided by \(descriptor.id.displayName)", text: $draft.token)
                } else {
                    SecureField("Provided by \(descriptor.id.displayName)", text: $draft.token)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 280)

            Button {
                isTokenRevealed.toggle()
            } label: {
                Image(systemName: isTokenRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isTokenRevealed ? "Hide \(descriptor.auth.credentialLabel)" : "Show \(descriptor.auth.credentialLabel)")
            .accessibilityLabel(isTokenRevealed ? "Hide credential" : "Show credential")
        }
    }

    @ViewBuilder
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Base URL") {
                TextField(descriptor.defaultBaseURL, text: $draft.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)
            }

            if descriptor.requiresRankEndpointTemplate {
                LabeledContent("Rank Endpoint") {
                    TextField("/v1/players/{playerID}/rank", text: $draft.rankEndpointTemplate)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 300)
                }
                Text("The endpoint must contain {playerID}. Leave it blank until \(descriptor.id.displayName) confirms the public contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(descriptor.auth.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func connect() {
        var candidate = draft
        candidate.normalize()
        if let issue = candidate.issue(for: descriptor) {
            validationMessage = issue.message(for: descriptor)
            // Surface the section that actually needs the operator's input.
            if issue != .missingCredential {
                isShowingAdvanced = true
            }
            return
        }
        validationMessage = nil
        onConnect(candidate)
    }
}
