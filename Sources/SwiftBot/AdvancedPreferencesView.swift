import AppKit
import SwiftUI

// The Developer tab is only compiled and shown in DEBUG builds.
// In release builds this view renders nothing — the tab item in
// PreferencesView.swift should also be conditionally included.
struct AdvancedPreferencesView: View {
    var body: some View {
        #if DEBUG
        debugContent
        #else
        // Release builds: this tab should not appear. If it does, show nothing.
        EmptyView()
        #endif
    }

    #if DEBUG
    @ViewBuilder
    private var debugContent: some View {
        SettingsForm {
            Section {
                Text("Developer tools are active because this is a DEBUG build. These settings are never compiled into release builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Debug Build", systemImage: "hammer.circle")
            }

            Section {
                Label("SwiftBot Remote (beta) and experimental features are available in debug builds automatically.", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Experimental Tools", systemImage: "wrench")
            }
        }
    }
    #endif
}
