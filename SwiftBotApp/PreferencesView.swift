import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel

    // Persist selected tab to fix toolbar rendering issues
    @AppStorage("swiftbot.preferences.selectedTab")
    private var selectedTab = 0

    var body: some View {
        Group {
            if app.isRemoteLaunchMode {
                PreferencesTabContainer {
                    PreferencesCard(
                        "Remote Control Mode",
                        systemImage: "dot.radiowaves.left.and.right",
                        subtitle: "Local Discord, SwiftMesh, and Web UI runtime settings are inactive while this Mac is acting as a remote management client."
                    ) {
                        Text("Use the Remote dashboard to update the primary node connection, inspect status, edit rules, and change runtime settings on the primary.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                TabView(selection: $selectedTab) {
                    GeneralPreferencesView()
                        .tabItem {
                            Label("General", systemImage: "gear")
                        }
                        .tag(0)

                    MeshPreferencesView()
                        .tabItem {
                            Label("SwiftMesh", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .tag(1)

                    WebUIPreferencesView()
                        .tabItem {
                            Label("Web UI", systemImage: "globe")
                        }
                        .tag(2)

                    SwiftMinerPreferencesView()
                        .tabItem {
                            Label("Integrations", systemImage: "app.connected.to.app.below.fill")
                        }
                        .tag(3)

                    UpdatesPreferencesView()
                        .tabItem {
                            Label("Updates", systemImage: "arrow.clockwise")
                        }
                        .tag(4)

                    AdvancedPreferencesView()
                        .tabItem {
                            Label("Developer", systemImage: "wrench")
                        }
                        .tag(5)
                }
                .autosavesPreferences(for: app)
            }
        }
        .frame(width: 720, height: 480)
        .background(
            // Hidden view that observes onboarding state and closes window when complete
            PreferencesWindowCloser()
        )
    }
}

private struct PreferencesAutosaveModifier: ViewModifier {
    @ObservedObject var app: AppModel
    @State private var lastSnapshot: AppPreferencesSnapshot?

    func body(content: Content) -> some View {
        let snapshot = app.createPreferencesSnapshot()

        content
            .task(id: snapshot) {
                guard lastSnapshot != nil else {
                    lastSnapshot = snapshot
                    return
                }

                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }

                lastSnapshot = snapshot
                app.saveSettings()
            }
    }
}

extension View {
    func autosavesPreferences(for app: AppModel) -> some View {
        modifier(PreferencesAutosaveModifier(app: app))
    }
}

// Separate view to handle window closing without affecting PreferencesView identity
private struct PreferencesWindowCloser: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        EmptyView()
            .onChange(of: app.isOnboardingComplete) { oldValue, newValue in
                // Only close when transitioning TO complete (finishing setup)
                // NOT when transitioning FROM complete (starting setup)
                if newValue && !oldValue {
                    // Close the Preferences window
                    DispatchQueue.main.async {
                        NSApp.keyWindow?.close()
                    }
                }
            }
    }
}
