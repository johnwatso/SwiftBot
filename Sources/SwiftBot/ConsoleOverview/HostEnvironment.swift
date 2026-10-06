import Foundation

// MARK: - Host details

extension HostDetails {
    /// This Mac and this copy of SwiftBot. Cheap and synchronous; read once.
    static let current: HostDetails = {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = os.patchVersion == 0
            ? "\(os.majorVersion).\(os.minorVersion)"
            : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        let channel: String
        #if DEBUG
        channel = "Development"
        #else
        // Same flag AppModel.isBetaBuild reads; ShipHook sets it on beta builds.
        channel = (info["ShipHookIsBetaBuild"] as? Bool) == true ? "Beta" : "Release"
        #endif

        let details = HostDetails(
            computerName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            hardware: MacHardwareInfo.summary,
            operatingSystem: "macOS \(osVersion)",
            appVersion: info["CFBundleShortVersionString"] as? String ?? "—",
            buildNumber: info["CFBundleVersion"] as? String ?? "",
            buildChannel: channel,
            dataLocation: SwiftBotStorage.folderURL()
        )
        #if DEBUG
        if ScreenshotDemo.isEnabled { return .screenshotDemo(from: details) }
        #endif
        return details
    }()
}
