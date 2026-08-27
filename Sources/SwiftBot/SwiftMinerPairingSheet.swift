import AppKit
import SwiftUI

/// Pairing and connection sheet for the SwiftMiner companion app.
///
/// SwiftMiner authenticates by exchanging a pairing bundle rather than an API
/// key the operator types, so this sheet is a pairing workflow: open SwiftMiner,
/// or paste the bundle it copied, then manage or drop the pairing afterwards.
struct SwiftMinerPairingSheet: View {
    @EnvironmentObject var app: AppModel
    let onDone: () -> Void

    @State private var pairingMessageOverride: String?
    @State private var pairingSucceededOverride = false
    @State private var isConfirmingDisconnect = false

    private var isPaired: Bool { app.settings.swiftMiner.isPaired }

    private var status: IntegrationConnectionStatus {
        .companionApp(isPaired: isPaired, isEnabled: app.settings.swiftMiner.enabled)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Form {
                Section {
                    LabeledContent("Status") {
                        IntegrationStatusLabel(status: status)
                    }

                    if isPaired {
                        Toggle("Relay SwiftMiner events to Discord", isOn: $app.settings.swiftMiner.enabled)
                    }
                } footer: {
                    Text("Notifications are configured in SwiftMiner. SwiftBot only relays approved events to Discord.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack(spacing: 10) {
                        Button {
                            openSwiftMinerPairing()
                        } label: {
                            Label(isPaired ? "Re-pair with SwiftMiner" : "Pair with SwiftMiner", systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Paste Link") {
                            applyToken(NSPasteboard.general.string(forType: .string) ?? "")
                        }

                        Spacer(minLength: 0)

                        if isPaired {
                            Button("Disconnect", role: .destructive) {
                                isConfirmingDisconnect = true
                            }
                        }
                    }

                    if let pairingMessage {
                        Text(pairingMessage)
                            .font(.caption)
                            .foregroundStyle(pairingSucceeded ? .green : .red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Click Pair with SwiftBot in SwiftMiner › Integrations. Manual paste still works as a fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 540, height: 420)
        .confirmationDialog(
            "Disconnect SwiftMiner?",
            isPresented: $isConfirmingDisconnect
        ) {
            Button("Disconnect", role: .destructive) {
                app.disconnectSwiftMiner()
                pairingMessageOverride = nil
                pairingSucceededOverride = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SwiftBot will forget the SwiftMiner API key and webhook secret. Pair again to resume relaying events.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SwiftMinerArtworkView(size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text("Configure SwiftMiner")
                    .font(.title3.weight(.semibold))
                Text("Mining events and account notifications")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Relays account recovery, drop claim, and campaign events from SwiftMiner as Discord DMs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    // MARK: - Pairing state

    private var pairingMessage: String? {
        pairingMessageOverride ?? app.swiftMinerPairingStatusMessage
    }

    private var pairingSucceeded: Bool {
        pairingMessageOverride == nil
            ? app.swiftMinerPairingStatusSucceeded
            : pairingSucceededOverride
    }

    private func openSwiftMinerPairing() {
        guard let url = URL(string: "swiftminer://pair") else { return }
        if NSWorkspace.shared.open(url) {
            pairingSucceededOverride = true
            pairingMessageOverride = "SwiftMiner opened. Click Pair with SwiftBot there to finish."
        } else {
            pairingSucceededOverride = false
            pairingMessageOverride = "I couldn't open SwiftMiner automatically. Open SwiftMiner › Integrations and click Pair with SwiftBot."
        }
    }

    private func applyToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pairingSucceededOverride = false
            pairingMessageOverride = "Clipboard is empty. Click Pair with SwiftBot in SwiftMiner, or copy its pairing link first."
            return
        }
        let result = app.applySwiftMinerPairingToken(trimmed)
        pairingSucceededOverride = result.ok
        pairingMessageOverride = result.message
    }
}

/// SwiftMiner's own artwork when it has been cached or can be fetched,
/// falling back to a neutral glyph. Shared by the Integrations row and the
/// pairing sheet so the app is recognisable in both places.
struct SwiftMinerArtworkView: View {
    @EnvironmentObject var app: AppModel
    let size: CGFloat

    var body: some View {
        Group {
            if let cachedURL = app.swiftMinerCachedArtworkURL(),
               let image = NSImage(contentsOf: cachedURL) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = URL(string: app.settings.swiftMiner.artworkURL),
                      ["http", "https"].contains(remoteURL.scheme?.lowercased()) {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var fallback: some View {
        IntegrationSymbolIcon(systemName: "shippingbox.fill", tint: .orange)
    }
}
