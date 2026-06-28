import AppKit
import SwiftUI

struct SwiftMinerPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var swiftMinerPairingMessage: String?
    @State private var swiftMinerPairingSucceeded = false

    var body: some View {
        Form {
            statusCard

            if !app.settings.swiftMiner.enabled {
                pairingSection
            }

            onboardingInfoSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
        .disabled(app.isFailoverManagedNode)
        .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        .onAppear {
            if app.settings.swiftMiner.enabled {
                app.cacheSwiftMinerArtworkIfNeeded()
            }
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    statusIconView

                    VStack(alignment: .leading, spacing: 0) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(statusSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: Binding(
                        get: { app.settings.swiftMiner.enabled },
                        set: { newValue in
                            // Block turning ON until a pairing bundle has been
                            // applied — otherwise the integration is missing
                            // the API key + HMAC secret and every call fails.
                            if newValue && !app.settings.swiftMiner.isPaired { return }
                            app.settings.swiftMiner.enabled = newValue
                        }
                    ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(!app.settings.swiftMiner.enabled && !app.settings.swiftMiner.isPaired)
                        .help(toggleHelpText)
                }

                Text("Receives mining events from SwiftMiner and relays Discord DMs for account recovery, drop claims, and campaign updates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineSpacing(1)
            }
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(statusColor.opacity(0.14), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private var statusIconView: some View {
        if app.settings.swiftMiner.enabled {
            swiftMinerArtwork
        } else {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: statusIcon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(statusColor)
            }
        }
    }

    private var toggleHelpText: String {
        if app.settings.swiftMiner.enabled {
            return "Disable SwiftMiner integration"
        }
        if !app.settings.swiftMiner.isPaired {
            return "Pair with SwiftMiner first to enable the integration"
        }
        return "Enable SwiftMiner integration"
    }

    private var statusTitle: String {
        app.settings.swiftMiner.enabled ? "Paired with SwiftMiner" : "SwiftMiner Integration"
    }

    private var statusSubtitle: String {
        app.settings.swiftMiner.enabled
            ? "SwiftMiner events will be delivered to Discord"
            : "Pair with SwiftMiner to get started"
    }

    private var statusIcon: String {
        app.settings.swiftMiner.enabled ? "checkmark.circle.fill" : "app.badge.checkmark"
    }

    private var statusColor: Color {
        app.settings.swiftMiner.enabled ? .green : .secondary
    }

    // MARK: - Pairing Section

    private var pairingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        openSwiftMinerPairing()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("Pair with SwiftMiner")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button {
                        let token = NSPasteboard.general.string(forType: .string) ?? ""
                        applyToken(token)
                    } label: {
                        Text("Paste Link")
                    }
                    .controlSize(.regular)

                    Spacer(minLength: 0)
                }

                if let pairingMessage {
                    Text(pairingMessage)
                        .font(.caption)
                        .foregroundStyle(pairingSucceeded ? .green : .red)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "link.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Pairing")
                    .font(.subheadline.weight(.semibold))
            }
        } footer: {
            Text("Click Pair with SwiftBot in SwiftMiner › Integrations. Manual paste still works as a fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingMessage: String? {
        swiftMinerPairingMessage ?? app.swiftMinerPairingStatusMessage
    }

    private var pairingSucceeded: Bool {
        swiftMinerPairingMessage == nil
            ? app.swiftMinerPairingStatusSucceeded
            : swiftMinerPairingSucceeded
    }

    private func openSwiftMinerPairing() {
        guard let url = URL(string: "swiftminer://pair") else { return }
        if NSWorkspace.shared.open(url) {
            swiftMinerPairingSucceeded = true
            swiftMinerPairingMessage = "SwiftMiner opened. Click Pair with SwiftBot there to finish."
        } else {
            swiftMinerPairingSucceeded = false
            swiftMinerPairingMessage = "I couldn't open SwiftMiner automatically. Open SwiftMiner › Integrations and click Pair with SwiftBot."
        }
    }

    private func applyToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            swiftMinerPairingSucceeded = false
            swiftMinerPairingMessage = "Clipboard is empty. Click Pair with SwiftBot in SwiftMiner, or copy its pairing link first."
            return
        }
        let result = app.applySwiftMinerPairingToken(trimmed)
        swiftMinerPairingSucceeded = result.ok
        swiftMinerPairingMessage = result.message
    }

    // MARK: - Onboarding Info

    private var onboardingInfoSection: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.blue)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text("SwiftMiner controls which DMs are sent")
                        .font(.caption.weight(.medium))
                    Text("Configure account recovery, drop, and campaign notifications from SwiftMiner › Integrations. SwiftBot just relays approved events to Discord.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
            }
            .padding(.vertical, 2)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.blue.opacity(0.10), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Artwork

    @ViewBuilder
    private var swiftMinerArtwork: some View {
        if let cachedURL = app.swiftMinerCachedArtworkURL(),
           let image = NSImage(contentsOf: cachedURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else if let remoteURL = URL(string: app.settings.swiftMiner.artworkURL),
                  ["http", "https"].contains(remoteURL.scheme?.lowercased()) {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    fallbackArtwork
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            fallbackArtwork
                .frame(width: 34, height: 34)
        }
    }

    private var fallbackArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
            Image(systemName: "shippingbox.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
