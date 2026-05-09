import AppKit
import SwiftUI

struct SwiftMinerPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var swiftMinerPairingToken = ""
    @State private var swiftMinerPairingMessage: String?
    @State private var swiftMinerPairingSucceeded = false

    var body: some View {
        PreferencesTabContainer {
            PreferencesCard("Integrations", systemImage: "app.connected.to.app.below.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    // SwiftMiner pairing status
                    HStack {
                        settingsToggleRow("Enable SwiftMiner Integration", isOn: $app.settings.swiftMiner.enabled)
                        Spacer()
                        Text(app.settings.swiftMiner.enabled ? "Paired" : "Not Paired")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(app.settings.swiftMiner.enabled ? .green : .secondary)
                    }

                    if app.settings.swiftMiner.enabled {
                        HStack(spacing: 10) {
                            swiftMinerArtwork
                            Text("SwiftMiner is paired and ready.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .onAppear {
                            app.cacheSwiftMinerArtworkIfNeeded()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pairing Bundle")
                                .font(.subheadline.weight(.medium))
                            TextField("Paste from SwiftMiner", text: $swiftMinerPairingToken)
                                .textFieldStyle(.roundedBorder)
                        }

                        HStack {
                            Button {
                                let result = app.applySwiftMinerPairingToken(swiftMinerPairingToken)
                                swiftMinerPairingSucceeded = result.ok
                                swiftMinerPairingMessage = result.message
                                if result.ok {
                                    swiftMinerPairingToken = ""
                                }
                            } label: {
                                Label("Pair with SwiftMiner", systemImage: "link")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                let token = NSPasteboard.general.string(forType: .string) ?? ""
                                swiftMinerPairingToken = token
                                let result = app.applySwiftMinerPairingToken(token)
                                swiftMinerPairingSucceeded = result.ok
                                swiftMinerPairingMessage = result.message
                                if result.ok {
                                    swiftMinerPairingToken = ""
                                }
                            } label: {
                                Label("Paste and Pair", systemImage: "doc.on.clipboard")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let swiftMinerPairingMessage {
                            Text(swiftMinerPairingMessage)
                                .font(.caption)
                                .foregroundStyle(swiftMinerPairingSucceeded ? .green : .red)
                        }

                        Text("Copy the pairing bundle from SwiftMiner > Integrations and paste it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Discord Integration — DM Notifications
                    if app.settings.swiftMiner.enabled {
                        Divider()
                            .padding(.vertical, 4)

                        Text("Discord Integration")
                            .font(.subheadline.weight(.medium))

                        Text("Choose which DMs SwiftBot sends to users. Onboarding messages are always sent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 6) {
                            settingsToggleRow("Drop claimed", isOn: notificationBinding(\.dropClaimedEnabled))
                            settingsToggleRow("Campaign complete", isOn: notificationBinding(\.campaignCompletedEnabled))
                            settingsToggleRow("Connection expired", isOn: notificationBinding(\.connectionExpiredEnabled))
                            settingsToggleRow("Welcome back", isOn: notificationBinding(\.welcomeBackEnabled))
                            settingsToggleRow("Link required for game", isOn: notificationBinding(\.linkRequiredEnabled))
                            settingsToggleRow("New campaign detected", isOn: notificationBinding(\.campaignDetectedEnabled))
                            settingsToggleRow("Account action required", isOn: notificationBinding(\.accountActionRequiredEnabled))
                        }
                    }
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }

    private func notificationBinding(_ keyPath: WritableKeyPath<SwiftMinerDMNotificationPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { app.settings.swiftMiner.notificationPreferences[keyPath: keyPath] },
            set: { app.settings.swiftMiner.notificationPreferences[keyPath: keyPath] = $0 }
        )
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private var swiftMinerArtwork: some View {
        if let cachedURL = app.swiftMinerCachedArtworkURL(),
           let image = NSImage(contentsOf: cachedURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else if let remoteURL = URL(string: app.settings.swiftMiner.artworkURL),
                  ["http", "https"].contains(remoteURL.scheme?.lowercased()) {
            AsyncImage(url: remoteURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Image(systemName: "shippingbox.circle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: "shippingbox.circle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
    }
}
