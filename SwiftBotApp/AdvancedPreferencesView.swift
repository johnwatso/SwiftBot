import AppKit
import SwiftUI

struct AdvancedPreferencesView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("Developer Mode", systemImage: "hammer.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable Developer Mode", isOn: Binding(
                        get: { app.settings.devFeaturesEnabled },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                app.settings.devFeaturesEnabled = newValue
                            }
                        }
                    ))
                    .toggleStyle(.switch)

                    Text("Unlock experimental SwiftBot features including SwiftBot Remote beta. These tools are under active development.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("Experimental Tools", systemImage: "wrench") {
                Text(
                    app.settings.devFeaturesEnabled
                    ? "Developer Mode is active. SwiftBot Remote beta and other experimental tools are available below."
                    : "Enable Developer Mode above to configure SwiftBot Remote beta and other experimental tools."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }

    @ViewBuilder
    private func settingsSubsectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.secondary)
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
