import Foundation
import SwiftUI
#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    enum UpdateChannel: String, CaseIterable, Identifiable {
        case stable
        case beta

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stable: return "Stable"
            case .beta: return "Beta"
            }
        }

        var symbolName: String {
            switch self {
            case .stable: return "checkmark.seal"
            case .beta: return "flask.fill"
            }
        }
    }

    private static let updateChannelDefaultsKey = "SwiftBotAppUpdateChannel"

    @Published private(set) var isConfigured = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var feedURLString = ""
    @Published private(set) var hasPublicKey = false
    @Published private(set) var bundlePath = Bundle.main.bundlePath
    @Published private(set) var selectedChannel: UpdateChannel = .stable
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var automaticallyDownloadsUpdates = false
    /// What the last check found, so the Web UI can report it without
    /// Sparkle's own window (which only appears on this Mac).
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var availableBuild: String?
    @Published private(set) var availableReleaseNotesURL: URL?
    @Published private(set) var lastErrorMessage: String?
    /// Set once an unattended download has finished and Sparkle is waiting
    /// for the app to quit. Calling it installs and relaunches now.
    private var pendingInstallHandler: (() -> Void)?
    @Published private(set) var isReadyToInstall = false

#if canImport(Sparkle)
    private var updaterController: SPUStandardUpdaterController?
#endif
    private let stableFeedURL: String
    private let currentShortVersion: String
    private var autoCheckTask: Task<Void, Never>?
    var onError: ((Error) -> Void)?

    init(bundle: Bundle = .main) {
        let persistedChannelRaw = UserDefaults.standard.string(forKey: Self.updateChannelDefaultsKey) ?? UpdateChannel.stable.rawValue
        let persistedChannel = UpdateChannel(rawValue: persistedChannelRaw) ?? .stable
        selectedChannel = persistedChannel

        let feedURL = (bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let shortVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let configured = !feedURL.isEmpty && !publicKey.isEmpty
        stableFeedURL = feedURL
        currentShortVersion = shortVersion

        let initialFeedURL = Self.resolvedFeedURL(stableFeedURL: feedURL, channel: persistedChannel)

        super.init()

        feedURLString = initialFeedURL
        hasPublicKey = !publicKey.isEmpty
        bundlePath = bundle.bundlePath
        isConfigured = configured

#if canImport(Sparkle)
        if configured {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: nil
            )
            automaticallyChecksForUpdates = updaterController?.updater.automaticallyChecksForUpdates ?? false
            automaticallyDownloadsUpdates = updaterController?.updater.automaticallyDownloadsUpdates ?? false
            canCheckForUpdates = true
            updateAutoCheckLoop()
        } else {
            updaterController = nil
            canCheckForUpdates = false
            automaticallyChecksForUpdates = false
            automaticallyDownloadsUpdates = false
        }
#else
        canCheckForUpdates = false
        automaticallyChecksForUpdates = false
        automaticallyDownloadsUpdates = false
#endif
    }

    func checkForUpdates() {
#if canImport(Sparkle)
        updaterController?.checkForUpdates(nil)
#endif
    }

    func checkForUpdatesInBackground() {
#if canImport(Sparkle)
        guard let updater = updaterController?.updater, !updater.sessionInProgress else { return }
        isChecking = true
        updater.checkForUpdatesInBackground()
#endif
    }

    /// Installs a downloaded update and relaunches. False when nothing is
    /// waiting to install.
    @discardableResult
    func installPendingUpdate() -> Bool {
        guard let handler = pendingInstallHandler else { return false }
        handler()
        return true
    }

    var currentVersion: String { currentShortVersion }

    var releaseNotesURL: URL? {
        Self.releaseNotesURL(from: feedURLString, shortVersion: currentShortVersion)
    }

    func setAutomaticallyChecksForUpdates(_ isEnabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyChecksForUpdates = isEnabled
#endif
        automaticallyChecksForUpdates = isEnabled
        updateAutoCheckLoop()
    }

    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool) {
#if canImport(Sparkle)
        updaterController?.updater.automaticallyDownloadsUpdates = isEnabled
#endif
        automaticallyDownloadsUpdates = isEnabled
    }

    private func updateAutoCheckLoop() {
        if automaticallyChecksForUpdates {
            startAutoCheckLoop()
        } else {
            autoCheckTask?.cancel()
            autoCheckTask = nil
        }
    }

    private func startAutoCheckLoop() {
        autoCheckTask?.cancel()
        autoCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000) // 5 minutes
                await MainActor.run {
                    self.checkForUpdatesInBackground()
                }
            }
        }
    }

    func setUpdateChannel(_ channel: UpdateChannel) {
        guard selectedChannel != channel else { return }
        selectedChannel = channel
        UserDefaults.standard.set(channel.rawValue, forKey: Self.updateChannelDefaultsKey)
        feedURLString = Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: channel)
    }

    private static func resolvedFeedURL(stableFeedURL: String, channel: UpdateChannel) -> String {
        switch channel {
        case .stable:
            return stableFeedURL
        case .beta:
            return betaFeedURL(from: stableFeedURL)
        }
    }

    private static func betaFeedURL(from stableFeedURL: String) -> String {
        guard var components = URLComponents(string: stableFeedURL) else {
            return stableFeedURL
        }
        let path = components.path
        let betaPath: String
        if path.hasSuffix("/appcast.xml") {
            betaPath = String(path.dropLast("/appcast.xml".count)) + "/beta/appcast.xml"
        } else if path.hasSuffix("appcast.xml") {
            betaPath = String(path.dropLast("appcast.xml".count)) + "beta/appcast.xml"
        } else {
            betaPath = path.hasSuffix("/") ? path + "beta/appcast.xml" : path + "/beta/appcast.xml"
        }
        components.path = betaPath
        return components.url?.absoluteString ?? stableFeedURL
    }

    static func releaseNotesURL(from feedURLString: String, shortVersion: String) -> URL? {
        guard var components = URLComponents(string: feedURLString) else {
            return nil
        }

        let sanitizedVersion = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = components.path
        if path.hasSuffix("/beta/appcast.xml") {
            components.path = String(path.dropLast("/beta/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("/appcast.xml") {
            components.path = String(path.dropLast("/appcast.xml".count)) + "/release-notes/"
        } else if path.hasSuffix("appcast.xml") {
            components.path = String(path.dropLast("appcast.xml".count)) + "release-notes/"
        } else {
            components.path = path.hasSuffix("/") ? path + "release-notes/" : path + "/release-notes/"
        }

        if !sanitizedVersion.isEmpty {
            components.path += components.path.hasSuffix("/") ? "\(sanitizedVersion).html" : "/\(sanitizedVersion).html"
        }

        return components.url
    }
}

#if canImport(Sparkle)
extension AppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        Self.resolvedFeedURL(stableFeedURL: stableFeedURL, channel: selectedChannel)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        availableBuild = item.versionString
        availableReleaseNotesURL = item.fullReleaseNotesURL ?? item.releaseNotesURL
            ?? Self.releaseNotesURL(from: feedURLString, shortVersion: item.displayVersionString)
        lastErrorMessage = nil
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        availableVersion = nil
        availableBuild = nil
        availableReleaseNotesURL = nil
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        isChecking = false
        lastCheckedAt = Date()
    }

    /// Only called for an unattended download. Taking it over keeps the
    /// install handler so the Web UI (or Settings) can install now instead of
    /// waiting for a quit that a long-running bot may never do. Sparkle still
    /// installs on quit if nobody does.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        availableVersion = item.displayVersionString
        availableBuild = item.versionString
        pendingInstallHandler = immediateInstallHandler
        isReadyToInstall = true
        return true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // Do not postpone relaunch; install immediately when Sparkle is ready.
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        // Skip expected non-failure errors:
        // SUNoUpdateError = 4001 or 2401
        // SUInstallationCanceledError = 4003 or 2403
        if nsError.domain == "SUSparkleErrorDomain" {
            let code = nsError.code
            if code == 4001 || code == 4003 || code == 2401 || code == 2403 {
                return
            }
        }

        lastErrorMessage = error.localizedDescription

        onError?(error)
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        true
    }

}
#endif
