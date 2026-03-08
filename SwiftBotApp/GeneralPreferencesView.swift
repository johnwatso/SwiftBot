import SwiftUI

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel

    @State private var showRunSetupPrompt = false

    private var advancedFeaturesBinding: Binding<Bool> {
        Binding(
            get: { app.settings.devFeaturesEnabled },
            set: { newValue in
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.settings.devFeaturesEnabled = newValue
                }
            }
        )
    }

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("General", systemImage: "gear") {
                Toggle("Start Bot Automatically", isOn: $app.settings.autoStart)
                    .toggleStyle(.switch)

                Divider()

                Toggle("Enable Advanced Features", isOn: advancedFeaturesBinding)
                    .toggleStyle(.switch)

                Text("Enable experimental SwiftBot functionality intended for testing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("Deployment", systemImage: "wand.and.stars") {
                Button(role: .none) {
                    showRunSetupPrompt = true
                } label: {
                    Label("Run Setup Wizard", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .confirmationDialog(
                    "Run setup again?",
                    isPresented: $showRunSetupPrompt,
                    titleVisibility: .visible
                ) {
                    Button("Start Setup", role: .destructive) { app.isOnboardingComplete = false }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will take you back to the initial configuration screens.")
                }

                Text("Reopen the guided setup flow if you need to reconfigure Discord or SwiftMesh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
        }
    }
}
