import SwiftUI

struct WebUIPreferencesView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("Web UI", systemImage: "globe") {
                Toggle("Enable Admin Web UI", isOn: $app.settings.adminWebUI.enabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Bind Host")
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
                    Text("Leave empty to use http://\(app.settings.adminWebUI.bindHost):\(app.settings.adminWebUI.port)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Allowed User IDs")
                        .font(.subheadline.weight(.medium))
                    TextField("Comma-separated Discord user IDs", text: Binding(
                        get: { app.settings.adminWebUI.allowedUserIDs.joined(separator: ", ") },
                        set: { newValue in
                            app.settings.adminWebUI.allowedUserIDs = newValue
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    Text("If empty, only users who are in connected guilds and have Manage Server can log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }
}
