import SwiftUI
import AppKit

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var showRunSetupPrompt = false
    @State private var showClearCachePrompt = false
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        SettingsForm(readOnlyBannerText: app.isFailoverManagedNode
            ? "Bot settings are read-only on Failover nodes. Recording folders stay local to this Mac." : nil) {
            Section {
                Picker("Show SwiftBot as", selection: $app.settings.presenceMode) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .disabled(app.isFailoverManagedNode)
                LaunchAtLoginToggle()
                Button("Open Discord Settings…") {
                    app.requestedSidebarItem = .discord
                    openWindow(id: "main")
                }
                    .buttonStyle(.borderless)
            } header: {
                Text("Startup & Services")
            }

            Section {
                Button {
                    showRunSetupPrompt = true
                } label: {
                    Label("Run Setup Wizard…", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .confirmationDialog(
                    "Run setup again?",
                    isPresented: $showRunSetupPrompt,
                    titleVisibility: .visible
                ) {
                    Button("Start Setup", role: .destructive) { app.isOnboardingComplete = false }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Returns you to the initial configuration screens. Existing settings are preserved.")
                }
            } header: {
                Text("Setup")
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)

            Section {
                Button(role: .destructive) {
                    showClearCachePrompt = true
                } label: {
                    Label("Clear Cached Data…", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .confirmationDialog(
                    "Clear cached server data?",
                    isPresented: $showClearCachePrompt,
                    titleVisibility: .visible
                ) {
                    Button("Clear Cache", role: .destructive) {
                        Task {
                            await app.clearCachedData()
                            transientToastMessage = "Cached server data cleared."
                            toastDismissTask?.cancel()
                            toastDismissTask = Task {
                                try? await Task.sleep(nanoseconds: 2_500_000_000)
                                transientToastMessage = nil
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Removes cached channel, role, and member names from previously-connected servers. Your settings and token are kept. Restart the bot to repopulate from the current server.")
                }
            } header: {
                Text("Cached Data")
            } footer: {
                Text("Use this after moving SwiftBot to a different server so stale names don't linger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .preferencesCardDisabled(when: app.isFailoverManagedNode)
        }
        .overlay(alignment: .topTrailing) {
            if let transientToastMessage {
                Text(transientToastMessage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                    )
                    .padding(.trailing, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
