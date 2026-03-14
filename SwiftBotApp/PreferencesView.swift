import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel

    // Persist selected tab to fix toolbar rendering issues
    @AppStorage("swiftbot.preferences.selectedTab")
    private var selectedTab = 0

    @State private var autoSaveTask: Task<Void, Never>? = nil

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

                    UpdatesPreferencesView()
                        .tabItem {
                            Label("Updates", systemImage: "arrow.clockwise")
                        }
                        .tag(3)

                    AdvancedPreferencesView()
                        .tabItem {
                            Label("Developer", systemImage: "wrench")
                        }
                        .tag(4)
                }
                .onChange(of: app.createPreferencesSnapshot()) { _, _ in
                    autoSaveTask?.cancel()
                    autoSaveTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        app.saveSettings()
                    }
                }
            }
        }
        .frame(width: 720, height: 480)
        .background(
            // Hidden view that observes onboarding state and closes window when complete
            PreferencesWindowCloser()
        )
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
