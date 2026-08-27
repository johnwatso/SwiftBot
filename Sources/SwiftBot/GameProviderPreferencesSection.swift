import SwiftUI

/// Integrations card for game data providers. Renders one row per provider in
/// `GameProviderCatalog`, driven entirely by the descriptor — the credential
/// label, help text, and whether a rank endpoint is even applicable all come
/// from the provider's own metadata, so a new provider needs no view changes.
struct GameProviderPreferencesSection: View {
    @EnvironmentObject var app: AppModel

    private var descriptors: [GameProviderDescriptor] {
        GameProviderCatalog.descriptors.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(descriptors, id: \.id) { descriptor in
                    GameProviderConnectionCard(descriptor: descriptor)
                    if descriptor.id != descriptors.last?.id {
                        Divider()
                    }
                }
            }
        } header: {
            Label("Game Data Providers", systemImage: "point.3.connected.trianglepath.dotted")
        } footer: {
            Text("Credentials stay in the macOS Keychain. Player profiles, schedules, and Discord announcements are managed from the Game Tracker service.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct GameProviderConnectionCard: View {
    @EnvironmentObject var app: AppModel
    @State private var showToken = false

    let descriptor: GameProviderDescriptor

    private var connection: GameProviderConnectionSettings {
        app.settings.gameProviders[descriptor.id]
    }

    private var binding: Binding<GameProviderConnectionSettings> {
        Binding(
            get: { app.settings.gameProviders[descriptor.id] },
            set: { app.settings.gameProviders[descriptor.id] = $0 }
        )
    }

    private var issue: String? {
        connection.configurationIssue(for: descriptor)
    }

    private var isReady: Bool { issue == nil }

    private var statusColor: Color { isReady ? .green : .orange }

    private var supportedGamesText: String {
        descriptor.supportedGames
            .map(\.displayName)
            .sorted()
            .formatted(.list(type: .and))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(statusColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "scope")
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.id.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(isReady ? "Ready for Game Tracker" : "Connect to enable \(supportedGamesText) tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(
                    isReady ? "READY" : "SETUP REQUIRED",
                    systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(statusColor)
            }

            Text(capabilitySummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent(descriptor.auth.credentialLabel) {
                HStack(spacing: 8) {
                    Group {
                        if showToken {
                            TextField("Provided by \(descriptor.id.displayName)", text: binding.token)
                        } else {
                            SecureField("Provided by \(descriptor.id.displayName)", text: binding.token)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 300)

                    Button {
                        showToken.toggle()
                    } label: {
                        Image(systemName: showToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }
            }

            DisclosureGroup("Advanced API Contract") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Base URL") {
                        TextField(descriptor.defaultBaseURL, text: binding.baseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 340)
                    }
                    if descriptor.requiresRankEndpointTemplate {
                        LabeledContent("Rank Endpoint") {
                            TextField("/v1/players/{playerID}/rank", text: binding.rankEndpointTemplate)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 340)
                        }
                        Text("The endpoint must contain {playerID}. Leave it blank until \(descriptor.id.displayName) confirms the public contract.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(descriptor.auth.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }

            if let issue {
                Label(issue, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var capabilitySummary: String {
        var parts: [String] = []
        if descriptor.capabilities.contains(.rankedScore) { parts.append("ranked score") }
        if descriptor.capabilities.contains(.rankTier) { parts.append("tier") }
        if descriptor.capabilities.contains(.latestSession) { parts.append("session") }
        if descriptor.capabilities.contains(.matchHistory) { parts.append("match history") }
        let capabilityText = parts.isEmpty ? "profile" : parts.formatted(.list(type: .and))
        return "Provides \(capabilityText) data for \(supportedGamesText) profiles in Game Tracker."
    }
}
