import SwiftUI

/// Settings › Integrations.
///
/// This page is an overview, not a configuration surface: it answers what
/// SwiftBot can connect to, what is connected, and what needs attention.
/// Credentials, pairing, and advanced options all live in per-integration
/// sheets, so adding a Game Tracking provider is a `GameProviderCatalog`
/// entry rather than a redesign.
struct IntegrationsSettingsView: View {
    @EnvironmentObject var app: AppModel

    @State private var configuringProvider: GameProviderID?
    @State private var isConfiguringSwiftMiner = false

    private var providerDescriptors: [GameProviderDescriptor] {
        GameProviderCatalog.descriptors.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    var body: some View {
        SettingsForm(
            readOnlyBannerText: app.isFailoverManagedNode
                ? "Read-only on Failover nodes. Integration settings sync from Primary."
                : nil
        ) {
            IntegrationSection(
                title: "Game Tracking",
                systemImage: "gamecontroller.fill",
                subtitle: "Connect data providers used by Game Tracker."
            ) {
                ForEach(providerDescriptors, id: \.id) { descriptor in
                    IntegrationRow(
                        title: descriptor.id.displayName,
                        subtitle: descriptor.tagline,
                        status: app.integrationStatus(for: descriptor.id),
                        icon: { IntegrationSymbolIcon(systemName: descriptor.symbolName) },
                        action: { configuringProvider = descriptor.id }
                    )
                }
            }

            IntegrationSection(
                title: "Companion Apps",
                systemImage: "app.connected.to.app.below.fill",
                subtitle: "Connect SwiftBot with companion apps and services."
            ) {
                IntegrationRow(
                    title: "SwiftMiner",
                    subtitle: "Mining events and account notifications",
                    status: .companionApp(
                        isPaired: app.settings.swiftMiner.isPaired,
                        isEnabled: app.settings.swiftMiner.enabled
                    ),
                    icon: { SwiftMinerArtworkView(size: 28) },
                    accessory: { swiftMinerEnableToggle },
                    action: { isConfiguringSwiftMiner = true }
                )
            }
        }
        .preferencesCardDisabled(when: app.isFailoverManagedNode)
        .onAppear {
            if app.settings.swiftMiner.enabled {
                app.cacheSwiftMinerArtworkIfNeeded()
            }
        }
        .sheet(item: $configuringProvider) { providerID in
            if let descriptor = GameProviderCatalog.descriptor(for: providerID) {
                GameProviderConfigurationSheet(
                    descriptor: descriptor,
                    connection: app.settings.gameProviders[providerID],
                    onCancel: { configuringProvider = nil },
                    onConnect: { connection in
                        app.applyGameProviderConnection(connection, for: providerID)
                        configuringProvider = nil
                    }
                )
            }
        }
        .sheet(isPresented: $isConfiguringSwiftMiner) {
            SwiftMinerPairingSheet(onDone: { isConfiguringSwiftMiner = false })
        }
    }

    /// Only meaningful once a pairing bundle has been applied — before that
    /// there are no credentials to switch on, so no toggle is shown.
    @ViewBuilder
    private var swiftMinerEnableToggle: some View {
        if app.settings.swiftMiner.isPaired {
            Toggle("Enable SwiftMiner integration", isOn: Binding(
                get: { app.settings.swiftMiner.enabled },
                set: { app.settings.swiftMiner.enabled = $0 }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
    }
}

// MARK: - Components

/// One grouped section of the Integrations overview: a titled header with a
/// short explanatory subtitle, wrapping compact integration rows.
struct IntegrationSection<Content: View>: View {
    let title: String
    let systemImage: String
    let subtitle: String
    private let content: Content

    init(
        title: String,
        systemImage: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        Section {
            content
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)
            .padding(.bottom, 2)
        }
    }
}

/// Compact row for a single integration: icon, name, description, status, an
/// optional live control, and a disclosure indicator into its sheet.
struct IntegrationRow<Icon: View, Accessory: View>: View {
    private let title: String
    private let subtitle: String
    private let status: IntegrationConnectionStatus
    private let icon: Icon
    private let accessory: Accessory
    private let action: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        subtitle: String,
        status: IntegrationConnectionStatus,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.icon = icon()
        self.accessory = accessory()
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    icon
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    IntegrationStatusLabel(status: status)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(status.label)")
            .accessibilityHint("Opens \(title) configuration")

            accessory

            Button(action: action) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.055 : 0))
        )
        .padding(.horizontal, -6)
        .onHover { isHovering = $0 }
    }
}

extension IntegrationRow where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String,
        status: IntegrationConnectionStatus,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            status: status,
            icon: icon,
            accessory: { EmptyView() },
            action: action
        )
    }
}

/// Restrained status pill: one symbol, one word or two, one colour.
struct IntegrationStatusLabel: View {
    let status: IntegrationConnectionStatus

    var body: some View {
        Label(status.label, systemImage: status.symbolName)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
            .font(.caption)
            .foregroundStyle(status.tint)
            .fixedSize()
    }
}

/// Tinted glyph tile for an integration that ships no artwork of its own.
struct IntegrationSymbolIcon: View {
    let systemName: String
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint.opacity(0.14))
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }
    }
}
