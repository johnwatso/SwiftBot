import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var app: AppModel

    static let generalTab = 0
    static let updatesTab = 1

    // Persist selected tab to fix toolbar rendering issues
    @AppStorage("swiftbot.preferences.selectedTab")
    private var selectedTab = 0

    var body: some View {
        Group {
            // App-level preferences only. Each service's settings (Web
            // Interface, Discord, SwiftMesh, Integrations) live on its own page in
            // the main window's sidebar.
            TabView(selection: $selectedTab) {
                GeneralPreferencesView()
                    .tabItem {
                        Label("General", systemImage: "gearshape")
                    }
                    .tag(Self.generalTab)

                UpdatesPreferencesView()
                    .tabItem {
                        Label("Updates", systemImage: "arrow.clockwise.circle")
                    }
                    .tag(Self.updatesTab)
            }
            // A tab saved by an older build (SwiftMesh, Web UI, …) no longer exists.
            .onAppear {
                if ![Self.generalTab, Self.updatesTab].contains(selectedTab) {
                    selectedTab = Self.generalTab
                }
            }
            .padding(.top, -2)
            .autosavesPreferences(for: app)
        }
        // A fixed, compact height keeps the window from resizing between
        // tabs; each tab's form scrolls when it needs more room. Matches Otter.
        .frame(width: 520, height: 360, alignment: .top)
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
