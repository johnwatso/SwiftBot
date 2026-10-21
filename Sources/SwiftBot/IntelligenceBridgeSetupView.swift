import AppKit
import SwiftUI

/// One-time provisioning for SwiftBot's three signed, system-owned Shortcuts.
/// Apple requires the user to review and add each Shortcut, then approve its
/// first model request while present at the Mac.
struct IntelligenceBridgeSetupView: View {
    let completionTitle: String
    let skipTitle: String
    let onCompletion: () -> Void

    @State private var status: ShortcutIntelligenceBridge.Status?
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    var body: some View {
        VStack(spacing: 20) {
            ConsoleIconTile(symbol: "apple.intelligence", size: 64)

            VStack(spacing: 8) {
                Text("Apple Intelligence Shortcuts")
                    .font(.title2.weight(.bold))

                Text(
                    "SwiftBot includes three finished, signed Shortcuts with their summary styles already built in. "
                        + "Add each once, approve the first test, and Patchy can run them unattended while this Mac is logged in."
                )
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ShortcutIntelligenceBridge.Profile.allCases.enumerated()), id: \.element) { index, profile in
                    profileRow(profile)
                    if index < ShortcutIntelligenceBridge.Profile.allCases.count - 1 {
                        Divider()
                            .padding(.vertical, 10)
                    }
                }

                Divider()
                    .padding(.vertical, 10)

                if let message {
                    Label(message, systemImage: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(isError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let status {
                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 500)

            VStack(spacing: 10) {
                primaryButton

                if status?.isReady != true {
                    HStack(spacing: 16) {
                        Button("Check Again") { refreshStatus() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        Button(skipTitle) { onCompletion() }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .task { await updateStatus() }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if status?.isReady == true {
            Button(completionTitle) { onCompletion() }
                .buttonStyle(GlassActionButtonStyle())
                .controlSize(.large)
        } else if status?.nextMissingProfile != nil {
            Button {
                installShortcuts()
            } label: {
                Label(
                    isWorking ? "Waiting for Add Confirmations…" : "Add SwiftBot Shortcuts…",
                    systemImage: "square.and.arrow.down.fill"
                )
                .font(.headline)
                .frame(minWidth: 250)
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.large)
            .disabled(isWorking || status?.isSupported == false)
        } else {
            Button {
                testShortcuts()
            } label: {
                Label(
                    isWorking ? "Testing…" : "Test & Authorize Shortcuts",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.headline)
                .frame(minWidth: 250)
            }
            .buttonStyle(GlassActionButtonStyle())
            .controlSize(.large)
            .disabled(isWorking || status?.isSupported == false)
        }
    }

    private func profileRow(_ profile: ShortcutIntelligenceBridge.Profile) -> some View {
        let installed = status?.installedProfiles.contains(profile) == true
        let ready = status?.readyProfiles.contains(profile) == true

        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: profile.symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ready ? .green : Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    (ready ? Color.green : Color.accentColor).opacity(0.12),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.title)
                    .font(.subheadline.weight(.semibold))
                Text(profile.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(ready ? "Ready" : (installed ? "Added" : "Not Added"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(ready ? .green : (installed ? .secondary : .orange))
        }
    }

    private func refreshStatus() {
        isWorking = true
        message = nil
        Task {
            await updateStatus()
            isWorking = false
        }
    }

    private func installShortcuts() {
        isWorking = true
        message = nil
        Task {
            do {
                for (index, profile) in ShortcutIntelligenceBridge.Profile.allCases.enumerated() {
                    let current = await ShortcutIntelligenceBridge.shared.status()
                    status = current
                    guard !current.installedProfiles.contains(profile) else { continue }

                    message = "In Shortcuts, confirm Add for \(profile.title) (\(index + 1) of 3)."
                    try await ShortcutIntelligenceBridge.shared.openInstaller(for: profile)

                    var didInstall = false
                    for _ in 0..<300 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let latest = await ShortcutIntelligenceBridge.shared.status()
                        status = latest
                        if latest.installedProfiles.contains(profile) {
                            didInstall = true
                            break
                        }
                    }
                    guard didInstall else {
                        throw ShortcutIntelligenceBridge.BridgeError.installationNotConfirmed(profile)
                    }
                }

                _ = await MainActor.run {
                    NSRunningApplication.current.activate(options: [.activateAllWindows])
                }
                isError = false
                message = "All three Shortcuts were added. Run the authorization test once to finish."
            } catch {
                isError = true
                message = error.localizedDescription
            }
            await updateStatus()
            isWorking = false
        }
    }

    private func testShortcuts() {
        isWorking = true
        message = nil
        Task {
            do {
                for profile in ShortcutIntelligenceBridge.Profile.allCases {
                    guard status?.readyProfiles.contains(profile) != true else { continue }
                    message = "Testing \(profile.title)…"
                    _ = try await ShortcutIntelligenceBridge.shared.testAndAuthorize(profile: profile)
                    await updateStatus()
                }
                isError = false
                message = "All three Apple Intelligence Shortcuts are ready."
            } catch {
                isError = true
                message = error.localizedDescription
            }
            await updateStatus()
            isWorking = false
        }
    }

    private func updateStatus() async {
        status = await ShortcutIntelligenceBridge.shared.status()
    }
}
