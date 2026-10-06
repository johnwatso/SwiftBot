import Foundation

/// Debug-only demo state for website screenshots of the host console.
///
/// Launch a Debug build with `-SwiftBotScreenshotDemo YES`. The app then
/// behaves like it does under XCTest: `AppModel` skips loading settings and
/// starting the bot, Web Interface and SwiftMesh, storage goes to a throwaway
/// folder, and the Keychain is in memory, so nothing touches this Mac's real
/// configuration or secrets. The console is filled with a healthy sample host.
/// Release builds ignore the argument.
enum ScreenshotDemo {
    nonisolated static let isEnabled: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "SwiftBotScreenshotDemo")
        #else
        return false
        #endif
    }()
}

#if DEBUG
extension HostDetails {
    /// `current`, with the same sample Mac as the Web UI showcase (Mac mini,
    /// M4 Pro) and a release channel.
    static func screenshotDemo(from real: HostDetails) -> HostDetails {
        HostDetails(
            computerName: "Mac mini",
            hardware: "Mac mini (2024) · Apple M4 Pro · 48 GB memory",
            operatingSystem: "macOS 26.1",
            appVersion: real.appVersion,
            buildNumber: real.buildNumber,
            buildChannel: "Release",
            dataLocation: URL(filePath: NSHomeDirectory()).appending(path: "Library/Application Support/SwiftBot")
        )
    }
}

extension AppModel {
    /// A Primary running for a few days, with a Fail Over peer, the Web
    /// Interface and a Cloudflare Tunnel, all healthy.
    func applyScreenshotDemo() {
        settings.token = "screenshot-demo"
        settings.clusterMode = .leader
        settings.adminWebUI.enabled = true
        settings.adminWebUI.internetAccessEnabled = true

        botUsername = "SwiftBot"
        connectedServers = ["1001": "Swift Lounge", "1002": "Dev Bunker"]
        uptime = UptimeInfo(startedAt: Date().addingTimeInterval(-(6 * 86_400 + 4 * 3_600 + 12 * 60)))

        clusterSnapshot.mode = .leader
        clusterSnapshot.serverState = .listening
        clusterNodes = [
            ClusterNodeStatus(id: "mac-mini", hostname: "mac-mini.local", displayName: "Mac mini", role: .leader,
                              hardwareModel: "Mac16,10", cpu: 6, mem: 22, cpuName: "Apple M4 Pro",
                              physicalMemoryBytes: 48 << 30, uptime: 6 * 86_400, latencyMs: 3, status: .healthy, jobsActive: 1),
            ClusterNodeStatus(id: "studio", hostname: "studio.local", displayName: "Studio", role: .standby,
                              hardwareModel: "Mac14,13", cpu: 3, mem: 18, cpuName: "Apple M2 Max",
                              physicalMemoryBytes: 64 << 30, uptime: 12 * 86_400, latencyMs: 18, status: .healthy, jobsActive: 0)
        ]

        adminWebIsListening = true
        adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus(state: .enabled, publicURL: "https://bot.example.com")

        status = .running
        isOnboardingComplete = true
        hasLoadedSettings = true

        Task { await ScreenshotDemo.prepareMainWindow() }
    }
}

import AppKit

extension ScreenshotDemo {
    /// Sizes the main window for a screenshot and applies
    /// `-SwiftBotScreenshotDemoAppearance light|dark` when given. Capture it
    /// with `screencapture -l <window>` from a shell that has Screen Recording
    /// access: AppKit's offscreen drawing leaves the glass sidebar and the
    /// toolbar blank.
    @MainActor
    static func prepareMainWindow() async {
        switch UserDefaults.standard.string(forKey: "SwiftBotScreenshotDemoAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        try? await Task.sleep(for: .seconds(1))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "SwiftBot" }) else { return }
        window.setContentSize(NSSize(width: 1280, height: 860))
        window.center()
    }
}
#endif
