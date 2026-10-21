import SwiftUI
import AppKit

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel
    @State private var showRunSetupPrompt = false
    @State private var showClearCachePrompt = false
    @State private var showIntelligenceBridgeSetup = false
    @State private var intelligenceBridgeStatus: ShortcutIntelligenceBridge.Status?
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?

    var body: some View {
        SettingsForm {
            Section {
                Picker("Show SwiftBot as", selection: $app.settings.presenceMode) {
                    ForEach(AppPresenceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                LaunchAtLoginToggle()
            } header: {
                Text("Application")
            }

            Section {
                LabeledContent("Private Cloud Compute") {
                    if intelligenceBridgeStatus?.isReady == true {
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                SettingsSecondaryText(intelligenceBridgeStatus?.detail ?? "Checking SwiftBot’s Apple Intelligence Shortcuts…")

                Button {
                    showIntelligenceBridgeSetup = true
                } label: {
                    Label(
                        intelligenceBridgeStatus?.isReady == true ? "Manage Shortcuts…" : "Set Up Shortcuts…",
                        systemImage: "sparkles"
                    )
                }
                .settingsActionButton()
                .disabled(intelligenceBridgeStatus?.isSupported == false)
                SettingsSecondaryText("Patchy summarises releases through three optional SwiftBot Shortcuts, then falls back to the on-device model.")
            } header: {
                Text("Apple Intelligence")
            }

            Section {
                Button {
                    showRunSetupPrompt = true
                } label: {
                    Label("Run Setup Wizard…", systemImage: "wand.and.stars")
                }
                .settingsActionButton()
                .disabled(app.isFailoverManagedNode)
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
                SettingsSecondaryText(app.isFailoverManagedNode
                    ? "Run shared bot setup on the active Primary. This Mac’s preferences remain available here."
                    : "Walk through the initial configuration again. Existing settings are kept.")

                Button(role: .destructive) {
                    showClearCachePrompt = true
                } label: {
                    Label("Clear Cached Data…", systemImage: "trash")
                }
                .settingsActionButton()
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
                    Text("Removes cached channel, role, and member names on this Mac. Settings and credentials are kept. Names return with the next Discord connection or SwiftMesh sync.")
                }
                SettingsSecondaryText("Use this after moving SwiftBot to a different server so stale names don't linger.")
            } header: {
                Text("Maintenance")
            }
        }
        .task {
            intelligenceBridgeStatus = await ShortcutIntelligenceBridge.shared.status()
        }
        .sheet(
            isPresented: $showIntelligenceBridgeSetup,
            onDismiss: {
                Task { intelligenceBridgeStatus = await ShortcutIntelligenceBridge.shared.status() }
            },
            content: {
                IntelligenceBridgeSetupView(
                    completionTitle: "Done",
                    skipTitle: "Close"
                ) {
                    showIntelligenceBridgeSetup = false
                }
                .padding(28)
                .frame(width: 520, height: 560)
            }
        )
        .overlay(alignment: .topTrailing) {
            if let transientToastMessage {
                Text(transientToastMessage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(.separator, lineWidth: 1)
                    )
                    .padding(.trailing, 18)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}
