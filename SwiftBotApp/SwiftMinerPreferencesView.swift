import AppKit
import SwiftUI

struct SwiftMinerPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var swiftMinerPairingToken = ""
    @State private var swiftMinerPairingMessage: String?
    @State private var swiftMinerPairingSucceeded = false

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("SwiftMiner", systemImage: "shippingbox.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        settingsToggleRow("Enable SwiftMiner Integration", isOn: $app.settings.swiftMiner.enabled)
                        Spacer()
                        Text(app.settings.swiftMiner.enabled ? "Paired" : "Not Paired")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(app.settings.swiftMiner.enabled ? .green : .secondary)
                    }

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
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }

    private func settingsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center) {
            Text(title)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }
}
