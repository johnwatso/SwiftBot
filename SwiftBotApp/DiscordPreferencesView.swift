import AppKit
import SwiftUI

struct DiscordPreferencesView: View {
    @EnvironmentObject var app: AppModel

    @State private var showToken = false
    @State private var transientToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var inviteActionInProgress = false

    private var canGenerateInviteLink: Bool {
        !app.settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        PreferencesTabContainer {
            if app.isFailoverManagedNode {
                PreferencesReadOnlyBanner(text: "Read-only on Failover nodes. These settings sync from Primary.")
            }

            PreferencesCard("Discord Authentication", systemImage: "message") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bot Token")
                        .font(.subheadline.weight(.medium))

                    HStack {
                        if showToken {
                            TextField("Token", text: $app.settings.token)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Token", text: $app.settings.token)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button {
                            showToken.toggle()
                        } label: {
                            Image(systemName: showToken ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.plain)
                    }

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
            }
            .disabled(app.isFailoverManagedNode)
            .opacity(app.isFailoverManagedNode ? 0.62 : 1)
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
