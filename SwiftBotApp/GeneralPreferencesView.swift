import SwiftUI
import AppKit

struct GeneralPreferencesView: View {
    @EnvironmentObject var app: AppModel

    @State private var showRunSetupPrompt = false
    
    // Discord Authentication State (Moved from Discord tab)
    @State private var showToken = false
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false
    @State private var showingClearTokenConfirmation = false

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("General", systemImage: "gear") {
                Toggle("Start Bot Automatically", isOn: $app.settings.autoStart)
                    .toggleStyle(.switch)
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("Discord Authentication", systemImage: "message") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bot Token")
                        .font(.subheadline.weight(.medium))

                    HStack {
                        Group {
                            if showToken {
                                TextField("Token", text: $app.settings.token)
                            } else {
                                SecureField("Token", text: $app.settings.token)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))

                        HStack(spacing: 8) {
                            Button {
                                showToken.toggle()
                            } label: {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)

                            if !app.settings.token.isEmpty {
                                Button {
                                    showingClearTokenConfirmation = true
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                    )
                    .frame(maxWidth: 560)

                    Text("Obtain this from the Discord Developer Portal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Invite Bot")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Button {
                            Task { await copyInviteLink() }
                        } label: {
                            Label("Copy Invite Link", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task { await openInviteLink() }
                        } label: {
                            Label("Open Invite Link", systemImage: "arrow.up.forward.square")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(!canGenerateInviteLink || inviteActionInProgress)

                    if !canGenerateInviteLink {
                        Text("Bot token required to generate invite link.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if app.isFailoverManagedNode {
                    Text("This node is in Failover mode. Authentication settings are managed by the Primary node.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 4)
                }
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)

            PreferencesCard("Setup", systemImage: "wand.and.stars") {
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
        .alert("Remove Bot Token?", isPresented: $showingClearTokenConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                app.settings.token = ""
            }
        } message: {
            Text("Removing the token will disconnect SwiftBot from Discord until a new token is entered.")
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

    private func copyInviteLink() async {
        guard let inviteURL = await resolveInviteURL() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(inviteURL, forType: .string)
        showToast("Invite link copied")
    }

    private func openInviteLink() async {
        guard let inviteURL = await resolveInviteURL(),
              let url = URL(string: inviteURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func resolveInviteURL() async -> String? {
        guard canGenerateInviteLink else {
            showToast("Bot token required to generate invite link")
            return nil
        }

        inviteActionInProgress = true
        defer { inviteActionInProgress = false }

        let inviteURL = await app.generateInviteURL()
        if inviteURL == nil {
            showToast("Unable to generate invite link")
        }
        return inviteURL
    }

    private func showToast(_ message: String) {
        toastDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            transientToastMessage = message
        }
        toastDismissTask = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    transientToastMessage = nil
                }
            }
        }
    }
}
