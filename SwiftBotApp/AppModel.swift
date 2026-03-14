import AppKit
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI
import UpdateEngine
import Darwin

// MARK: - View Mode

enum ViewMode: String, Codable, CaseIterable, Identifiable {
    case local
    case remote
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .local: return "Local Dashboard"
        case .remote: return "Remote Dashboard"
        }
    }
    
    var icon: String {
        switch self {
        case .local: return "desktopcomputer"
        case .remote: return "dot.radiowaves.left.and.right"
        }
    }
}

private struct AdminWebCertificateRenewalConfiguration: Equatable {
    let enabled: Bool
    let domain: String
    let cloudflareToken: String
}

actor MediaLibraryIndexer {
    private struct CacheEntry {
        let signature: String
        let payload: MediaLibraryPayload
        let createdAt: Date
    }

    private var cachedEntry: CacheEntry?
    private let cacheTTL: TimeInterval = 30
    
    func cachedItem(for id: String) -> MediaLibraryItem? {
        cachedEntry?.payload.items.first(where: { $0.id == id })
    }

    func invalidate() {
        cachedEntry = nil
    }

    func snapshot(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?,
        configFilePath: String
    ) -> MediaLibraryPayload {
        let signature = makeSignature(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL, configFilePath: configFilePath)
        if let cachedEntry, cachedEntry.signature == signature, Date().timeIntervalSince(cachedEntry.createdAt) < cacheTTL {
            return cachedEntry.payload
        }

        let payload = MediaLibraryPayload(
            nodeName: ownerNodeName,
            configFilePath: configFilePath,
            sources: sources,
            items: scanItems(sources: sources, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL),
            generatedAt: Date()
        )
        cachedEntry = CacheEntry(signature: signature, payload: payload, createdAt: Date())
        return payload
    }

    private func makeSignature(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?,
        configFilePath: String
    ) -> String {
        let sourceSignature = sources.map {
            "\($0.id.uuidString)|\($0.name)|\($0.normalizedRootPath)|\($0.isEnabled)|\($0.normalizedExtensions.joined(separator: ","))"
        }.joined(separator: "||")
        return "\(ownerNodeName)|\(ownerBaseURL ?? "")|\(configFilePath)|\(sourceSignature)"
    }

    private func scanItems(
        sources: [MediaLibrarySource],
        ownerNodeName: String,
        ownerBaseURL: String?
    ) -> [MediaLibraryItem] {
        let fileManager = FileManager.default
        var items: [MediaLibraryItem] = []

        for source in sources where source.isEnabled {
            let root = source.normalizedRootPath
            guard !root.isEmpty else { continue }

            let rootURL = URL(fileURLWithPath: root, isDirectory: true)
            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let allowedExtensions = Set(source.normalizedExtensions)
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                guard allowedExtensions.isEmpty || allowedExtensions.contains(ext) else { continue }
                guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }

                let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let id = "\(source.id.uuidString)|\(relativePath)"
                items.append(
                    MediaLibraryItem(
                        id: id,
                        sourceID: source.id,
                        sourceName: source.name,
                        fileName: fileURL.lastPathComponent,
                        relativePath: relativePath,
                        absolutePath: fileURL.path,
                        fileExtension: ext,
                        sizeBytes: Int64(values.fileSize ?? 0),
                        modifiedAt: values.contentModificationDate ?? .distantPast,
                        ownerNodeName: ownerNodeName,
                        ownerBaseURL: ownerBaseURL
                    )
                )
            }
        }

        return items.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
        }
    }
}

actor MediaThumbnailCache {
    private let fileManager = FileManager.default

    private func cacheDirectoryURL() -> URL {
        let url = SwiftBotStorage.folderURL().appendingPathComponent("media-thumbnails", isDirectory: true)
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func thumbnailResponse(for item: MediaLibraryItem) async -> BinaryHTTPResponse? {
        let cacheURL = cachedThumbnailURL(for: item)
        if let data = try? Data(contentsOf: cacheURL) {
            return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=300"], body: data)
        }

        guard let image = await generateThumbnail(for: item) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else {
            return nil
        }
        try? jpeg.write(to: cacheURL, options: .atomic)
        return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=300"], body: jpeg)
    }

    func frameResponse(for item: MediaLibraryItem, atSeconds: Double) async -> BinaryHTTPResponse? {
        let cacheURL = cachedFrameURL(for: item, atSeconds: atSeconds)
        if let data = try? Data(contentsOf: cacheURL) {
            return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=120"], body: data)
        }

        guard let image = await generateFrame(for: item, atSeconds: atSeconds) else { return nil }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return nil
        }
        try? jpeg.write(to: cacheURL, options: .atomic)
        return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: ["Cache-Control": "public, max-age=120"], body: jpeg)
    }

    private func cachedThumbnailURL(for item: MediaLibraryItem) -> URL {
        let fingerprint = "\(item.absolutePath)|\(item.modifiedAt.timeIntervalSince1970)|\(item.sizeBytes)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectoryURL().appendingPathComponent("\(digest).jpg")
    }

    private func cachedFrameURL(for item: MediaLibraryItem, atSeconds: Double) -> URL {
        let rounded = String(format: "%.1f", max(0, atSeconds))
        let fingerprint = "\(item.absolutePath)|\(item.modifiedAt.timeIntervalSince1970)|\(item.sizeBytes)|frame|\(rounded)"
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = cacheDirectoryURL().appendingPathComponent("frames", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(digest).jpg")
    }

    private func generateThumbnail(for item: MediaLibraryItem) async -> NSImage? {
        let url = URL(fileURLWithPath: item.absolutePath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let time = CMTime(seconds: 2, preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                guard let cgImage, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }
    }

    private func generateFrame(for item: MediaLibraryItem, atSeconds: Double) async -> NSImage? {
        let url = URL(fileURLWithPath: item.absolutePath)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 420, height: 240)

        let time = CMTime(seconds: max(0, atSeconds), preferredTimescale: 600)
        return await withCheckedContinuation { continuation in
            generator.generateCGImageAsynchronously(for: time) { cgImage, _, error in
                guard let cgImage, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)))
            }
        }
    }
}

enum AdminWebAutomaticHTTPSSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingDNSChallengeRecord(recordName: String)
    case dnsChallengeRecordCreated(recordName: String, reusedExistingRecord: Bool)
    case waitingForDNSPropagation(recordName: String)
    case dnsChallengeRecordPropagated(recordName: String)
    case dnsChallengeRecordVerified(recordName: String, reusedExistingRecord: Bool)
    case requestingTLSCertificate(domain: String)
    case tlsCertificateIssued(domain: String)
    case storingCertificate
    case certificateStored(path: String)
    case enablingHTTPSListener
    case httpsListenerEnabled(url: String)
}

enum AdminWebPublicAccessSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingTunnel(hostname: String)
    case tunnelCreated(name: String)
    case tunnelDetected(name: String)
    case creatingTunnelDNSRecord(hostname: String)
    case tunnelDNSRecordCreated(hostname: String)
    case storingTunnelCredentials
    case startingTunnelProcess
    case publicAccessEnabled(url: String)
}

enum InternetAccessSetupEvent: Sendable, Equatable {
    case verifyingCloudflareAccess
    case cloudflareAccessVerified
    case detectingCloudflareZone(domain: String)
    case cloudflareZoneDetected(zone: String)
    case creatingTunnel(hostname: String)
    case tunnelCreated(name: String)
    case tunnelDetected(name: String)
    case creatingTunnelDNSRecord(hostname: String)
    case tunnelDNSRecordCreated(hostname: String)
    case issuingHTTPSCertificate(hostname: String)
    case httpsCertificateIssued(hostname: String)
    case startingCloudflareTunnel
    case cloudflareTunnelStarted
    case internetAccessEnabled(url: String)
}

private enum AdminWebHTTPSProvisioningError: LocalizedError {
    case tlsActivationFailed

    var errorDescription: String? {
        switch self {
        case .tlsActivationFailed:
            return "The certificate was issued, but SwiftBot could not start the Admin Web UI over HTTPS. Check the logs and TLS files, then try again."
        }
    }
}

private enum AdminWebPublicAccessError: LocalizedError {
    case missingHostname
    case invalidOriginURL
    case tunnelStartupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingHostname:
            return "Enter a public hostname before enabling Public Access."
        case .invalidOriginURL:
            return "SwiftBot could not determine the local Web UI address for Cloudflare Tunnel."
        case .tunnelStartupFailed(let detail):
            return detail
        }
    }
}

private let genericAdminWebHTTPSSetupFailureMessage = "HTTPS setup couldn’t be completed. Verify Cloudflare access and DNS propagation, then try again."
private let genericAdminWebPublicAccessFailureMessage = "Public Access couldn’t be completed. Verify the hostname, Cloudflare access, and tunnel configuration, then try again."

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = BotSettings()
    @Published var status: BotStatus = .stopped
    @Published var stats = StatCounter()
    @Published var events: [ActivityEvent] = []
    @Published var commandLog: [CommandLogEntry] = []
    @Published var voiceLog: [VoiceEventLogEntry] = []
    @Published var activeVoice: [VoiceMemberPresence] = []
    @Published var uptime: UptimeInfo?
    @Published var connectedServers: [String: String] = [:]
    @Published var availableVoiceChannelsByServer: [String: [GuildVoiceChannel]] = [:]
    @Published var availableTextChannelsByServer: [String: [GuildTextChannel]] = [:]
    @Published var availableRolesByServer: [String: [GuildRole]] = [:]
    @Published var knownUsersById: [String: String] = [:]
    @Published var gatewayEventCount = 0
    @Published var voiceStateEventCount = 0
    @Published var readyEventCount = 0
    @Published var guildCreateEventCount = 0
    @Published var lastGatewayEventName: String = "-"
    @Published var lastVoiceStateAt: Date?
    @Published var lastVoiceStateSummary: String = "-"
    @Published var clusterSnapshot = ClusterSnapshot()
    @Published var clusterNodes: [ClusterNodeStatus] = []
    @Published var workerConnectionTestStatus: String = "Not tested"
    @Published var workerConnectionTestIsSuccess = false
    @Published var workerConnectionTestInProgress = false
    @Published var workerConnectionTestOutcome: WorkerConnectionTestOutcome? = nil
    @Published var lastClusterStatusRefreshAt: Date? = nil
    @Published var appleIntelligenceOnline = false
    @Published var ollamaOnline = false
    @Published var openAIOnline = false
    @Published var recentMediaCount24h = 0
    @Published var ollamaDetectedModel: String?
    @Published var patchyDebugLogs: [String] = []
    @Published var patchyIsCycleRunning = false
    @Published var patchyLastCycleAt: Date?
    private var patchyTargetValidationCache: [String: (isValid: Bool, detail: String, validatedAt: Date)] = [:]
    @Published var bugAutoFixStatusText: String = "Idle"
    @Published var bugAutoFixConsoleText: String = ""
    @Published private(set) var adminWebResolvedBaseURL: String = ""
    @Published private(set) var adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
    @Published var workerModeMigrated = false
    // MARK: - P0.4 Diagnostics state

    @Published var connectionDiagnostics = ConnectionDiagnostics()
    /// Date after which another Test Connection is allowed (10s UI rate limit).
    @Published var testConnectionCooldownUntil: Date? = nil

    /// `true` once a valid token has been confirmed — gates the main dashboard.
    @Published var isOnboardingComplete: Bool = false
    
    // MARK: - View Mode
    
    /// The current view mode (local or remote dashboard). Persisted across launches.
    @AppStorage("swiftbot.viewMode")
    private var viewModeRaw: String = ViewMode.local.rawValue
    
    var viewMode: ViewMode {
        get { ViewMode(rawValue: viewModeRaw) ?? .local }
        set {
            viewModeRaw = newValue.rawValue
            updateProvider()
        }
    }
    
    // MARK: - Bot Data Provider
    
    /// The current data provider (local or remote). Views should use this instead of accessing AppModel directly.
    @Published var provider: AnyBotDataProvider?
    
    private var localProvider: LocalBotProvider?
    private var localProviderBox: AnyBotDataProvider?
    
    private func updateProvider() {
        if localProvider == nil {
            let localProvider = LocalBotProvider(app: self)
            self.localProvider = localProvider
            self.localProviderBox = AnyBotDataProvider(localProvider)
        }
        provider = localProviderBox
    }
    
    /// OAuth2 client ID resolved from a validated token; used to build the invite URL.
    @Published var resolvedClientID: String? = nil
    /// Result from the most recent rich token validation; exposed for onboarding UI error display.
    @Published var lastTokenValidationResult: DiscordService.TokenValidationResult? = nil
    let isBetaBuild: Bool = (Bundle.main.object(forInfoDictionaryKey: "ShipHookIsBetaBuild") as? Bool) ?? false

    var logs = LogStore()
    let ruleStore = RuleStore()

    let store = ConfigStore()
    let swiftMeshConfigStore = SwiftMeshConfigStore()
    let mediaLibraryConfigStore = MediaLibraryConfigStore()
    let discordCacheStore = DiscordCacheStore()
    let meshCursorStore = MeshCursorStore()
    let mediaLibraryIndexer = MediaLibraryIndexer()
    let mediaThumbnailCache = MediaThumbnailCache()
    let mediaExportCoordinator = MediaExportCoordinator()
    let discordCache = DiscordCache()
    
    /// Shared session for general Discord REST API calls (gateway, guild, message operations).
    /// Uses default configuration for connection pooling and reuse.
    let discordRESTSession = URLSession(configuration: .default)
    
    /// Dedicated session for Discord identity/token validation calls.
    /// Uses ephemeral configuration: no disk cache, no credential storage, short timeout.
    /// This ensures token validation responses are never cached and credentials aren't persisted.
    private static let identitySessionConfig: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        return c
    }()
    let identitySession = URLSession(configuration: AppModel.identitySessionConfig)
    
    lazy var aiService = DiscordAIService(session: discordRESTSession)
    lazy var identityRESTClient = DiscordIdentityRESTClient(
        session: discordRESTSession,
        identitySession: identitySession
    )
    lazy var guildRESTClient = DiscordGuildRESTClient(session: discordRESTSession)
    lazy var messageRESTClient = DiscordMessageRESTClient(session: discordRESTSession)
    lazy var wikiLookupService = WikiLookupService(session: discordRESTSession)
    lazy var service = DiscordService(
        session: discordRESTSession,
        identitySession: identitySession,
        aiService: aiService,
        wikiLookupService: wikiLookupService
    )
    let cluster = ClusterCoordinator()
    let adminWebServer = AdminWebServer()
    let certificateManager = CertificateManager()
    let tunnelProvider: any TunnelProvider = TunnelManager.shared
    let clusterStatusService = ClusterStatusPollingService()
    let ruleEngine: RuleEngine
    let wikiContextCache = WikiContextCache()
    var guildOwnerIdByGuild: [String: String] = [:]
    var serviceCallbacksConfigured = false
    lazy var gatewayEventDispatcher = makeGatewayEventDispatcher()
    lazy var commandProcessor = makeCommandProcessor()
    let voicePresenceStore = VoicePresenceStore()
    var uptimeTask: Task<Void, Never>?
    var discordCacheSaveTask: Task<Void, Never>?
    var meshSyncTask: Task<Void, Never>?
    let conversationStore = ConversationStore()
    /// Tracks the last MemoryRecord ID the standby successfully merged from the leader.
    var localLastMergedRecordID: String?
    var lastCommandTimeByUserId: [String: Date] = [:]
    /// Dedupe cache for GUILD_MEMBER_ADD: keyed by "guildId:userId", 10s window. Capped at 500 entries.
    var recentMemberJoins: [String: Date] = [:]
    /// Approximate member count per guild, seeded from GUILD_CREATE and incremented on GUILD_MEMBER_ADD.
    var guildMemberCounts: [String: Int] = [:]
    /// Burst-guard: recent join timestamps per guild (keyed by guildId). Used to detect member raids.
    var guildJoinTimestamps: [String: [Date]] = [:]
    let commandCooldown: TimeInterval = 3.0
    let maxMediaClipDurationSeconds: Double = 15 * 60
    let aiMemoryStopwords: Set<String> = [
        "a","an","and","are","as","at","be","but","by","for","from","hey","how",
        "i","if","in","into","is","it","its","me","my","of","on","or","our","so",
        "that","the","their","them","then","there","these","they","this","to","up",
        "use","was","we","what","when","where","which","who","why","with","you","your"
    ]
    lazy var memoryViewModel = MemoryViewModel(store: conversationStore, discordCache: discordCache)
    let eventBus = EventBus()
    let pluginManager: PluginManager
    var weeklyPlugin: WeeklySummaryPlugin?
    let patchyChecker: UpdateChecker?
    var patchyMonitorTask: Task<Void, Never>?
    var adminWebCertificateRenewalTask: Task<Void, Never>?
    private var adminWebCertificateRenewalConfiguration: AdminWebCertificateRenewalConfiguration?
    var mediaMonitorTask: Task<Void, Never>?
    var lastSeenMediaItemIDs: Set<String> = []
    var botUserId: String?
    let launchedAt = Date()
    var clusterNodesRefreshTask: Task<Void, Never>?
    var lastClusterStatusSuccessAt: Date?
    var lastGoodClusterNodes: [ClusterNodeStatus] = []
    var registeredWorkersDebugCount: Int = 0
    var registeredWorkersDebugSummary: String = "none"
    // P1b: off-peak background mesh refresh
    var backgroundRefreshScheduler: NSBackgroundActivityScheduler?
    @Published var botUsername: String = "OnlineBot"
    @Published var botDiscriminator: String?
    @Published var botAvatarHash: String?
    @Published var userAvatarHashById: [String: String] = [:]
    @Published var guildAvatarHashByMemberKey: [String: String] = [:]
    // Max cache entries to prevent unbounded memory growth during extended operation
    private let maxAvatarCacheCount = 1000

    private func cacheUserAvatar(_ hash: String, for userId: String) {
        userAvatarHashById[userId] = hash
        if userAvatarHashById.count > maxAvatarCacheCount {
            userAvatarHashById.keys.prefix(200).forEach { userAvatarHashById.removeValue(forKey: $0) }
        }
    }

    private func cacheGuildAvatar(_ hash: String, for key: String) {
        guildAvatarHashByMemberKey[key] = hash
        if guildAvatarHashByMemberKey.count > maxAvatarCacheCount {
            guildAvatarHashByMemberKey.keys.prefix(200).forEach { guildAvatarHashByMemberKey.removeValue(forKey: $0) }
        }
    }
    
    @Published var mediaLibrarySettings = MediaLibrarySettings()
    @Published var mediaExportJobs: [MediaExportJob] = []
    var lastSlashRegistrationAt: Date?
    var lastSlashGuildRegistrationAt: [String: Date] = [:]
    var clearedGlobalSlashCommands = false
    var lastSlashCommandsEnabledState: Bool?
    var bugEntriesByMessageID: [String: BugEntry] = [:]
    var activeBugAutoFixMessageIDs: Set<String> = []
    var pendingBugAutoFixStarts: [String: BugAutoFixPendingStart] = [:]
    var pendingBugAutoFixApprovals: [String: BugAutoFixPendingApproval] = [:]

    var botAvatarURL: URL? {
        guard let userId = botUserId, let hash = botAvatarHash else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(hash).\(ext)?size=128")
    }

    func avatarURL(forUserId userId: String, guildId: String? = nil) -> URL? {
        if let guildId,
           let guildHash = guildAvatarHashByMemberKey["\(guildId)-\(userId)"],
           !guildHash.isEmpty {
            let ext = guildHash.hasPrefix("a_") ? "gif" : "png"
            return URL(string: "https://cdn.discordapp.com/guilds/\(guildId)/users/\(userId)/avatars/\(guildHash).\(ext)?size=96")
        }
        guard let hash = userAvatarHashById[userId], !hash.isEmpty else { return nil }
        let ext = hash.hasPrefix("a_") ? "gif" : "png"
        return URL(string: "https://cdn.discordapp.com/avatars/\(userId)/\(hash).\(ext)?size=96")
    }

    func fallbackAvatarURL(forUserId userId: String) -> URL? {
        guard let numericID = UInt64(userId) else {
            return URL(string: "https://cdn.discordapp.com/embed/avatars/0.png")
        }
        let index = Int(numericID % 6)
        return URL(string: "https://cdn.discordapp.com/embed/avatars/\(index).png")
    }

    var isRemoteLaunchMode: Bool {
        settings.launchMode == .remoteControl
    }

    var remoteControlFeatureEnabled: Bool {
        isBetaBuild && settings.devFeaturesEnabled
    }

    var canSwitchDashboardViewMode: Bool {
        !isRemoteLaunchMode && !isFailoverManagedNode
    }

    var canOpenRemoteDashboardFromLocalApp: Bool {
        remoteControlFeatureEnabled && canSwitchDashboardViewMode
    }

    var usesLocalRuntime: Bool {
        settings.launchMode != .remoteControl
    }

    private func onboardingCompleted(for settings: BotSettings) -> Bool {
        switch settings.launchMode {
        case .remoteControl:
            return settings.remoteMode.isConfigured
        case .standaloneBot, .swiftMeshClusterNode:
            return !settings.token.isEmpty
        }
    }

    init() {
        self.ruleEngine = RuleEngine(store: ruleStore)
        self.pluginManager = PluginManager(bus: eventBus)
        if let store = try? JSONVersionStore(fileURL: PatchyRuntime.checkerStoreURL()) {
            self.patchyChecker = UpdateChecker(store: store)
        } else {
            self.patchyChecker = nil
        }
        self.ruleStore.onPersisted = { [weak self] in
            await self?.handleRuleStorePersisted()
        }
        Task { [weak self] in
            await self?.mediaExportCoordinator.setOnJobFinished { [weak self] (_: MediaExportJob) in
                await self?.mediaLibraryIndexer.invalidate()
            }
        }

        Task {
            await startRateLimitCleanupTask()

            var loadedSettings = await store.load()
            let loadedMeshSettings = await swiftMeshConfigStore.load()
            let loadedMediaSettings = await mediaLibraryConfigStore.load()
            if let loadedMeshSettings {
                loadedSettings.swiftMeshSettings = loadedMeshSettings
            } else {
                // Seed dedicated mesh config once so later synced settings imports can't drift mesh identity.
                try? await swiftMeshConfigStore.save(loadedSettings.swiftMeshSettings)
            }
            mediaLibrarySettings = loadedMediaSettings
            var migrated = false

            if loadedSettings.localAIEndpoint.contains("mac-studio.local") {
                loadedSettings.localAIEndpoint = "http://127.0.0.1:1234/v1/chat/completions"
                migrated = true
            }
            if loadedSettings.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.ollamaBaseURL = "http://localhost:11434"
                migrated = true
            }
            if migrateLegacyPatchySettingsIfNeeded(&loadedSettings) {
                migrated = true
            }
            if migrateLegacyWikiBridgeSettingsIfNeeded(&loadedSettings) {
                migrated = true
            }
            // Worker mode is deprecated in UI — migrate to Fail Over for existing users.
            if loadedSettings.clusterMode == .worker {
                loadedSettings.clusterMode = .standby
                workerModeMigrated = true
                migrated = true
            }
            loadedSettings.remoteMode.normalize()
            if loadedSettings.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadedSettings.remoteAccessToken = generatedRemoteAccessToken()
                migrated = true
            }

            settings = loadedSettings
            isOnboardingComplete = onboardingCompleted(for: loadedSettings)
            
            // Initialize the appropriate data provider
            await MainActor.run {
                self.updateProvider()
            }
            if let cachedDiscord = await discordCacheStore.load() {
                await discordCache.replace(with: cachedDiscord)
                await syncPublishedDiscordCacheFromService()
                logs.append("Loaded cached Discord metadata (\(cachedDiscord.connectedServers.count) servers)")
            }
            if settings.localAIProvider == .ollama {
                detectOllamaModel()
            }
            await refreshAIStatus()
            for target in settings.patchy.sourceTargets where target.source == .steam {
                resolveSteamNameIfNeeded(for: target)
            }

            if migrated {
                try? await store.save(loadedSettings)
                try? await swiftMeshConfigStore.save(loadedSettings.swiftMeshSettings)
            }

            guard loadedSettings.launchMode != .remoteControl else {
                await cluster.stopAll()
                await adminWebServer.stop()
                await service.setOutputAllowed(false)
                return
            }

            await service.setRuleEngine(ruleEngine)
            await service.setHistoryProvider { [weak self] scope in
                guard let self else { return [] }
                let (messages, _) = await self.aiMessagesForScope(
                    scope: scope,
                    currentUserID: "",
                    currentContent: ""
                )
                return messages
            }
            await cluster.configureHandlers(
                aiHandler: { [weak self] messages, serverName, channelName, wikiContext in
                    guard let self else { return nil }
                    return await self.aiService.generateSmartDMReply(
                        messages: messages,
                        serverName: serverName,
                        channelName: channelName,
                        wikiContext: wikiContext
                    )
                },
                wikiHandler: { [weak self] query, source in
                    guard let self else { return nil }
                    return await self.wikiLookupService.lookupWiki(query: query, source: source)
                },
                onSnapshot: { [weak self] snapshot in
                    let model = self
                    await MainActor.run {
                        model?.clusterSnapshot = snapshot
                        model?.scheduleClusterNodesRefresh()
                    }
                },
                onJobLog: { [weak self] entry in
                    let model = self
                    await MainActor.run {
                        model?.commandLog.insert(entry, at: 0)
                    }
                },
                onSync: { [weak self] payload in
                    guard let self else { return }
                    await self.handleMeshSync(payload)
                },
                meshHandler: { [weak self] type in
                    guard let self else { return nil }
                    return await self.handleMeshRequest(type: type)
                },
                mediaLibraryProvider: { [weak self] in
                    guard let self else { return MediaLibraryPayload(nodeName: "SwiftBot", configFilePath: "", sources: [], items: [], generatedAt: Date()) }
                    return await self.localMediaLibrarySnapshot()
                },
                mediaStreamHandler: { [weak self] itemID, rangeHeader in
                    guard let self else { return nil }
                    return await self.localMediaStreamResponse(itemID: itemID, rangeHeader: rangeHeader)
                },
                mediaThumbnailHandler: { [weak self] itemID, _ in
                    guard let self else { return nil }
                    return await self.localMediaThumbnailResponse(itemID: itemID)
                },
                mediaClipHandler: { [weak self] request in
                    guard let self else { return nil }
                    return await self.localMediaClipExport(request: request)
                },
            mediaMultiViewHandler: { [weak self] request in
                guard let self else { return nil }
                return await self.localMediaMultiViewExport(request: request)
            },
            mediaFrameHandler: { [weak self] itemID, seconds in
                guard let self else { return nil }
                return await self.localMediaFrameResponse(itemID: itemID, atSeconds: seconds)
            },
                conversationFetcher: { [weak self] fromRecordID, limit in
                    guard let self, let fromRecordID else { return ([], false) }
                    return await self.conversationStore.recordsSince(fromRecordID: fromRecordID, limit: limit)
                },
                onPromotion: { [weak self] in
                    guard let self else { return }
                    // Promoted to Primary — enable Discord output. If already connected
                    // in passive standby mode, no reconnect is needed; output gate flips instantly.
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        logs.append("🚀 Promoted to Primary.")
                        Task { await self.connectDiscordAfterPromotion() }
                    }
                }
            )
            await aiService.configureLocalAIDMReplies(
                enabled: settings.localAIDMReplyEnabled,
                provider: settings.localAIProvider,
                preferredProvider: settings.preferredAIProvider,
                endpoint: localAIEndpointForService(),
                model: settings.localAIModel,
                openAIAPIKey: effectiveOpenAIAPIKey(),
                openAIModel: settings.openAIModel,
                systemPrompt: settings.localAISystemPrompt
            )
            await cluster.applySettings(
                mode: settings.clusterMode,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                leaderPort: settings.clusterLeaderPort,
                listenPort: settings.clusterListenPort,
                sharedSecret: settings.clusterSharedSecret,
                leaderTerm: settings.clusterLeaderTerm
            )
            await cluster.setOffloadPolicy(
                aiReplies: settings.clusterOffloadAIReplies,
                wikiLookups: settings.clusterOffloadWikiLookups
            )
            await cluster.setTermChangedHandler { [weak self] newTerm in
                guard let self else { return }
                await MainActor.run { [weak self] in
                    self?.settings.clusterLeaderTerm = newTerm
                    self?.saveSettings()
                }
            }
            await cluster.setCursorsChangedHandler { [weak self] cursors in
                Task { [weak self] in
                    await self?.saveMeshCursors(cursors)
                }
            }
            let restoredCursors = await meshCursorStore.load()
            await cluster.applyRestoredCursors(restoredCursors)
            await configureAdminWebServer()
            configureMeshSync()
            setupBackgroundRefreshScheduler()
            await pollClusterStatus()
            await configureServiceCallbacks()
            configurePatchyMonitoring()
            if settings.autoStart, !settings.token.isEmpty {
                await startBot()
            }
        }
    }

    func saveSettings() {
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if normalizedToken != settings.token {
            settings.token = normalizedToken
            logs.append("⚠️ Token format normalized (removed surrounding whitespace or Bot prefix)")
        }

        let trimmedPrefix = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPrefix.isEmpty {
            settings.prefix = "/"
            logs.append("⚠️ Prefix cannot be empty. Reset to default.")
        } else if trimmedPrefix == "!" {
            settings.prefix = "/"
            logs.append("ℹ️ Legacy command prefix migrated to '/'.")
        } else {
            settings.prefix = trimmedPrefix
        }
        settings.wikiBot.normalizeSources()
        settings.adminWebUI.redirectPath = normalizedAdminRedirectPath(settings.adminWebUI.redirectPath)
        settings.adminWebUI.discordOAuth.clientID = settings.adminWebUI.discordOAuth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.discordOAuth.clientSecret = settings.adminWebUI.discordOAuth.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.localAuthUsername = settings.adminWebUI.localAuthUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.adminWebUI.localAuthUsername.isEmpty {
            settings.adminWebUI.localAuthUsername = "admin"
        }
        settings.adminWebUI.localAuthPassword = settings.adminWebUI.localAuthPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.hostname = settings.adminWebUI.normalizedHostname
        settings.adminWebUI.cloudflareAPIToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.hostname = settings.adminWebUI.normalizedHostname
        settings.adminWebUI.publicAccessTunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.importedCertificateFile = settings.adminWebUI.normalizedImportedCertificateFile
        settings.adminWebUI.importedPrivateKeyFile = settings.adminWebUI.normalizedImportedPrivateKeyFile
        settings.adminWebUI.importedCertificateChainFile = settings.adminWebUI.normalizedImportedCertificateChainFile
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.allowedUserIDs = settings.adminWebUI.normalizedAllowedUserIDs
        settings.remoteMode.normalize()
        settings.remoteAccessToken = settings.remoteAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.remoteAccessToken.isEmpty {
            settings.remoteAccessToken = generatedRemoteAccessToken()
        }
        isOnboardingComplete = onboardingCompleted(for: settings)

        Task {
            do {
                try await store.save(settings)
                try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
                try await mediaLibraryConfigStore.save(mediaLibrarySettings)
                await mediaLibraryIndexer.invalidate()
                logs.append("✅ Settings saved")
                await refreshAIStatus()
            } catch {
                stats.errors += 1
                logs.append("❌ Failed saving settings: \(error.localizedDescription)")
                return
            }

            if self.usesLocalRuntime {
                await aiService.configureLocalAIDMReplies(
                    enabled: settings.localAIDMReplyEnabled,
                    provider: settings.localAIProvider,
                    preferredProvider: settings.preferredAIProvider,
                    endpoint: localAIEndpointForService(),
                    model: settings.localAIModel,
                    openAIAPIKey: effectiveOpenAIAPIKey(),
                    openAIModel: settings.openAIModel,
                    systemPrompt: settings.localAISystemPrompt
                )
                await applyClusterSettingsRuntime(
                    mode: settings.clusterMode,
                    nodeName: settings.clusterNodeName,
                    leaderAddress: settings.clusterLeaderAddress,
                    leaderPort: settings.clusterLeaderPort,
                    listenPort: settings.clusterListenPort,
                    sharedSecret: settings.clusterSharedSecret
                )
                await configureAdminWebServer()
                configurePatchyMonitoring()
            } else {
                patchyMonitorTask?.cancel()
                patchyMonitorTask = nil
                await cluster.stopAll()
                await adminWebServer.stop()
                await service.setOutputAllowed(false)
                adminWebResolvedBaseURL = ""
                adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
            }

            await notifyConfigFilesChangedIfLeader()
        }
    }

    func handleRuleStorePersisted() async {
        await notifyConfigFilesChangedIfLeader()
    }

    func notifyConfigFilesChangedIfLeader() async {
        guard settings.clusterMode == .leader else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        let payload = MeshSyncPayload(
            conversations: [],
            configFilesChanged: true,
            leaderTerm: currentTerm
        )
        await cluster.pushSyncPayloadToNodes(payload)
    }

    func localMediaLibrarySnapshot(ownerBaseURL: String? = nil) async -> MediaLibraryPayload {
        await ensureExportSourceConfigured()
        let configURL = await mediaLibraryConfigStore.fileURL()
        let ownerNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let payload = await mediaLibraryIndexer.snapshot(
            sources: effectiveMediaSources(),
            ownerNodeName: ownerNodeName,
            ownerBaseURL: ownerBaseURL,
            configFilePath: configURL.path
        )
        if ownerBaseURL == nil {
            let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
            recentMediaCount24h = payload.items.filter { $0.modifiedAt >= cutoff }.count
        }
        return payload
    }

    private func effectiveMediaSources() -> [MediaLibrarySource] {
        var sources = mediaLibrarySettings.sources
        guard mediaLibrarySettings.exportIncludeInLibrary else { return sources }
        let exportPath = mediaExportRootURL().path
        if exportPath.isEmpty { return sources }
        let exportID = mediaLibrarySettings.exportSourceID ?? UUID()
        if !sources.contains(where: { $0.id == exportID }) {
            let exportSource = MediaLibrarySource(
                id: exportID,
                name: "Exports",
                rootPath: exportPath,
                isEnabled: true,
                allowedExtensions: ["mp4", "mov", "m4v"]
            )
            sources.append(exportSource)
        }
        return sources
    }

    private func ensureExportSourceConfigured() async {
        guard mediaLibrarySettings.exportIncludeInLibrary else { return }
        let exportPath = mediaExportRootURL().path
        guard !exportPath.isEmpty else { return }
        if mediaLibrarySettings.exportSourceID == nil {
            mediaLibrarySettings.exportSourceID = UUID()
        }
        let exportID = mediaLibrarySettings.exportSourceID!
        if !mediaLibrarySettings.sources.contains(where: { $0.id == exportID }) {
            mediaLibrarySettings.sources.append(
                MediaLibrarySource(
                    id: exportID,
                    name: "Exports",
                    rootPath: exportPath,
                    isEnabled: true,
                    allowedExtensions: ["mp4", "mov", "m4v"]
                )
            )
            try? await mediaLibraryConfigStore.save(mediaLibrarySettings)
        } else if let index = mediaLibrarySettings.sources.firstIndex(where: { $0.id == exportID }) {
            if mediaLibrarySettings.sources[index].rootPath != exportPath {
                mediaLibrarySettings.sources[index].rootPath = exportPath
                try? await mediaLibraryConfigStore.save(mediaLibrarySettings)
            }
        }
    }

    private func mediaExportRootURL() -> URL {
        let trimmed = mediaLibrarySettings.exportRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return SwiftBotStorage.folderURL()
                .appendingPathComponent("recordings", isDirectory: true)
                .appendingPathComponent("exports", isDirectory: true)
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private func encodedMediaStreamToken(itemID: String, ownerNodeName: String, ownerBaseURL: String?) -> String {
        let descriptor = MediaStreamDescriptor(itemID: itemID, ownerNodeName: ownerNodeName, ownerBaseURL: ownerBaseURL)
        guard let data = try? JSONEncoder().encode(descriptor) else { return "" }
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func decodedMediaStreamToken(_ token: String) -> MediaStreamDescriptor? {
        var base64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(MediaStreamDescriptor.self, from: data)
    }

    private func mediaContentType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "m4v": return "video/x-m4v"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "application/octet-stream"
        }
    }

    private func parseByteRange(_ header: String?, fileSize: UInt64) -> (offset: UInt64, length: UInt64)? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines),
              header.lowercased().hasPrefix("bytes="),
              fileSize > 0 else { return nil }

        let rawRange = String(header.dropFirst("bytes=".count))
        let parts = rawRange.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty, let suffixLength = UInt64(parts[1]) {
            let length = min(suffixLength, fileSize)
            return (offset: fileSize - length, length: length)
        }

        guard let start = UInt64(parts[0]), start < fileSize else { return nil }
        let end: UInt64
        if parts[1].isEmpty {
            end = fileSize - 1
        } else if let parsedEnd = UInt64(parts[1]) {
            end = min(parsedEnd, fileSize - 1)
        } else {
            return nil
        }

        guard end >= start else { return nil }
        return (offset: start, length: end - start + 1)
    }

    private func localMediaItem(for itemID: String) async -> MediaLibraryItem? {
        if let cached = await mediaLibraryIndexer.cachedItem(for: itemID) {
            return cached
        }
        let snapshot = await localMediaLibrarySnapshot()
        return snapshot.items.first(where: { $0.id == itemID })
    }

    private func localMediaStreamResponse(itemID: String, rangeHeader: String?) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }

        let fileURL = URL(fileURLWithPath: item.absolutePath)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }

        let fileSize = fileSizeNumber.uint64Value
        let contentType = mediaContentType(for: fileURL.path)
        let requestedRange = parseByteRange(rangeHeader, fileSize: fileSize)
        let initialChunkLength = min(fileSize, 5 * 1024 * 1024)
        let effectiveRange: (offset: UInt64, length: UInt64)
        if let requestedRange {
            effectiveRange = (offset: requestedRange.offset, length: min(requestedRange.length, initialChunkLength))
        } else {
            effectiveRange = (offset: 0, length: initialChunkLength)
        }

        return await Task.detached(priority: .utility) { [fileURL, fileSize, contentType] in
            do {
                let handle = try FileHandle(forReadingFrom: fileURL)
                defer { try? handle.close() }

                try handle.seek(toOffset: effectiveRange.offset)
                let data = try handle.read(upToCount: Int(effectiveRange.length)) ?? Data()
                let end = effectiveRange.offset + UInt64(data.count) - 1
                return BinaryHTTPResponse(
                    status: "206 Partial Content",
                    contentType: contentType,
                    headers: [
                        "Accept-Ranges": "bytes",
                        "Content-Range": "bytes \(effectiveRange.offset)-\(end)/\(fileSize)"
                    ],
                    body: data
                )
            } catch {
                return BinaryHTTPResponse(
                    status: "500 Internal Server Error",
                    contentType: "application/json",
                    headers: [:],
                    body: Data("{\"error\":\"media read failed\"}".utf8)
                )
            }
        }.value
    }

    private func localMediaThumbnailResponse(itemID: String) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        return await mediaThumbnailCache.thumbnailResponse(for: item)
    }

    private func localMediaFrameResponse(itemID: String, atSeconds: Double) async -> BinaryHTTPResponse? {
        guard let item = await localMediaItem(for: itemID) else { return nil }
        return await mediaThumbnailCache.frameResponse(for: item, atSeconds: atSeconds)
    }

    private func parsedPositiveInt(_ value: String?, default defaultValue: Int, max: Int) -> Int {
        guard let value,
              let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              parsed > 0 else {
            return defaultValue
        }
        return min(parsed, max)
    }

    private func filteredMediaItemPayloads(
        from payloads: [MediaLibraryPayload],
        selectedSourceID: String?,
        selectedDateRange: String,
        selectedGame: String?
    ) -> [AdminWebMediaItemPayload] {
        let normalizedSelectedGame = selectedGame?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let minimumModifiedDate: Date? = {
            switch selectedDateRange {
            case "7d":
                return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case "30d":
                return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case "90d":
                return Calendar.current.date(byAdding: .day, value: -90, to: Date())
            default:
                return nil
            }
        }()

        return payloads
            .flatMap { payload in
                payload.items.compactMap { item in
                    let sourceToken = "\(payload.nodeName)|\(item.sourceID.uuidString)"
                    if let selectedSourceID, !selectedSourceID.isEmpty, sourceToken != selectedSourceID {
                        return nil
                    }
                    if let minimumModifiedDate, item.modifiedAt < minimumModifiedDate {
                        return nil
                    }

                    let gameName = mediaGameName(for: item.fileName)
                    if let normalizedSelectedGame, !normalizedSelectedGame.isEmpty, normalizedGameKey(gameName) != normalizedSelectedGame {
                        return nil
                    }

                    let token = encodedMediaStreamToken(
                        itemID: item.id,
                        ownerNodeName: payload.nodeName,
                        ownerBaseURL: item.ownerBaseURL
                    )
                    return AdminWebMediaItemPayload(
                        id: "\(payload.nodeName)|\(item.id)",
                        nodeName: payload.nodeName,
                        sourceName: item.sourceName,
                        gameName: gameName,
                        fileName: item.fileName,
                        relativePath: item.relativePath,
                        fileExtension: item.fileExtension,
                        sizeBytes: item.sizeBytes,
                        modifiedAt: item.modifiedAt,
                        thumbnailURL: "/api/media/thumbnail?id=\(token)",
                        streamURL: "/api/media/stream?id=\(token)"
                    )
                }
            }
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending
            }
    }

    private func mediaGameName(for fileName: String) -> String {
        let baseName = (fileName as NSString).deletingPathExtension
        let normalized = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "Unlabeled" }

        let upper = normalized.uppercased()
        if upper.hasPrefix("THE_FINALS_") {
            return "THE FINALS"
        }

        if let range = normalized.range(of: "_replay_", options: [.caseInsensitive]) {
            let rawGame = String(normalized[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawGame.isEmpty {
                return "Unknown"
            }
            if rawGame.lowercased() == "unknown" {
                return "Unknown"
            }
            return rawGame.replacingOccurrences(of: "_", with: " ")
        }

        if normalized.lowercased().hasPrefix("replay_") {
            return "Unknown"
        }

        return "Unlabeled"
    }

    private func normalizedGameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func adminWebMediaLibrarySnapshot(query: [String: String] = [:]) async -> AdminWebMediaLibraryPayload {
        let local = await localMediaLibrarySnapshot()
        var payloads: [MediaLibraryPayload] = [local]

        if settings.clusterMode == .leader {
            let workers = await cluster.registeredNodeInfo()
            for (_, baseURL) in workers {
                if let remote = await cluster.fetchRemoteMediaLibrary(from: baseURL) {
                    payloads.append(
                        MediaLibraryPayload(
                            nodeName: remote.nodeName,
                            configFilePath: remote.configFilePath,
                            sources: remote.sources,
                            items: remote.items.map { item in
                                var copy = item
                                if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                                    copy.ownerBaseURL = baseURL
                                }
                                return copy
                            },
                            generatedAt: remote.generatedAt
                        )
                    )
                }
            }
        } else if settings.clusterMode == .standby,
                  let leaderBaseURL = await cluster.normalizedBaseURL(settings.clusterLeaderAddress, defaultPort: settings.clusterLeaderPort),
                  !leaderBaseURL.isEmpty,
                  let remote = await cluster.fetchRemoteMediaLibrary(from: leaderBaseURL) {
            payloads.append(
                MediaLibraryPayload(
                    nodeName: remote.nodeName,
                    configFilePath: remote.configFilePath,
                    sources: remote.sources,
                    items: remote.items.map { item in
                        var copy = item
                        if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                            copy.ownerBaseURL = leaderBaseURL
                        }
                        return copy
                    },
                    generatedAt: remote.generatedAt
                )
            )
        }

        let sourcePayloads: [AdminWebMediaSourcePayload] = payloads.flatMap { payload in
            payload.sources.map { source in
                AdminWebMediaSourcePayload(
                    id: "\(payload.nodeName)|\(source.id.uuidString)",
                    nodeName: payload.nodeName,
                    sourceName: source.name,
                    itemCount: payload.items.filter { $0.sourceID == source.id }.count
                )
            }
        }

        let rawSelectedSourceID = query["source"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedSourceID = rawSelectedSourceID.isEmpty ? nil : rawSelectedSourceID
        let rawSelectedDateRange = query["dateRange"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedDateRange = rawSelectedDateRange.isEmpty ? "all" : rawSelectedDateRange
        let rawSelectedGame = query["game"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedGame = rawSelectedGame.isEmpty ? nil : rawSelectedGame
        let pageSize = parsedPositiveInt(query["pageSize"], default: 24, max: 96)
        let page = parsedPositiveInt(query["page"], default: 1, max: 10_000)

        let unfilteredForGames = filteredMediaItemPayloads(
            from: payloads,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: nil
        )
        let availableGames = Array(Set(unfilteredForGames.map { $0.gameName }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        let filteredItems = filteredMediaItemPayloads(
            from: payloads,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame
        )
        let totalItems = filteredItems.count
        let totalPages = max(1, Int(ceil(Double(max(totalItems, 1)) / Double(pageSize))))
        let clampedPage = min(page, totalPages)
        let startIndex = max(0, (clampedPage - 1) * pageSize)
        let endIndex = min(filteredItems.count, startIndex + pageSize)
        let pagedItems = Array(filteredItems[startIndex..<endIndex])

        return AdminWebMediaLibraryPayload(
            generatedAt: Date(),
            sources: sourcePayloads.sorted { lhs, rhs in
                if lhs.nodeName != rhs.nodeName {
                    return lhs.nodeName.localizedCaseInsensitiveCompare(rhs.nodeName) == .orderedAscending
                }
                return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
            },
            items: pagedItems,
            games: availableGames,
            selectedSourceID: selectedSourceID,
            selectedDateRange: selectedDateRange,
            selectedGame: selectedGame,
            page: clampedPage,
            pageSize: pageSize,
            totalItems: totalItems,
            totalPages: totalPages
        )
    }

    func adminWebMediaStreamResponse(token: String, rangeHeader: String?) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaStream(from: ownerBaseURL, itemID: descriptor.itemID, rangeHeader: rangeHeader)
        }

        return await localMediaStreamResponse(itemID: descriptor.itemID, rangeHeader: rangeHeader)
    }

    func adminWebMediaThumbnailResponse(token: String) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaThumbnail(from: ownerBaseURL, itemID: descriptor.itemID)
        }

        return await localMediaThumbnailResponse(itemID: descriptor.itemID)
    }

    func adminWebMediaFrameResponse(token: String, atSeconds: Double) async -> BinaryHTTPResponse? {
        guard let descriptor = decodedMediaStreamToken(token) else { return nil }
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            return await cluster.fetchRemoteMediaFrame(from: ownerBaseURL, itemID: descriptor.itemID, seconds: atSeconds)
        }

        return await localMediaFrameResponse(itemID: descriptor.itemID, atSeconds: atSeconds)
    }

    func adminWebMediaExportStatus() async -> MediaExportStatus {
        await mediaExportCoordinator.ffmpegStatus()
    }

    func adminWebMediaExportJobs() async -> MediaExportJobsPayload {
        let jobs = await mediaExportCoordinator.listJobs()
        await MainActor.run { self.mediaExportJobs = jobs }
        return MediaExportJobsPayload(jobs: jobs)
    }

    func adminWebStartMediaClipExport(request: MediaExportClipRequest) async -> MediaExportJobResponse {
        guard request.endSeconds > request.startSeconds else {
            return MediaExportJobResponse(job: nil, error: "End time must be after start time.")
        }
        guard request.endSeconds - request.startSeconds <= maxMediaClipDurationSeconds else {
            return MediaExportJobResponse(job: nil, error: "Clip length exceeds 15 minutes.")
        }
        guard let descriptor = decodedMediaStreamToken(request.token) else {
            return MediaExportJobResponse(job: nil, error: "Invalid media token.")
        }

        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if descriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = descriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            let meshRequest = MeshMediaClipRequest(
                itemID: descriptor.itemID,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            )
            if let job = await cluster.startRemoteMediaClip(from: ownerBaseURL, request: meshRequest) {
                await mediaExportCoordinator.recordExternalJob(job)
                return MediaExportJobResponse(job: job, error: nil)
            }
            return MediaExportJobResponse(job: nil, error: "Failed to start export on remote node.")
        }

        let status = await mediaExportCoordinator.ffmpegStatus()
        guard status.installed else {
            return MediaExportJobResponse(job: nil, error: "FFmpeg is not installed on this node.")
        }

        guard let item = await localMediaItem(for: descriptor.itemID) else {
            return MediaExportJobResponse(job: nil, error: "Media item not found.")
        }

        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let job = await mediaExportCoordinator.startClip(
            item: item,
            request: request,
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return MediaExportJobResponse(job: job, error: nil)
    }

    func adminWebStartMediaMultiViewExport(request: MediaExportMultiViewRequest) async -> MediaExportJobResponse {
        guard let primaryDescriptor = decodedMediaStreamToken(request.primaryToken),
              let secondaryDescriptor = decodedMediaStreamToken(request.secondaryToken) else {
            return MediaExportJobResponse(job: nil, error: "Invalid media token.")
        }

        if primaryDescriptor.ownerNodeName != secondaryDescriptor.ownerNodeName ||
            primaryDescriptor.ownerBaseURL != secondaryDescriptor.ownerBaseURL {
            return MediaExportJobResponse(job: nil, error: "Multiview clips must be on the same node.")
        }
        if let start = request.startSeconds, let end = request.endSeconds {
            guard end > start else {
                return MediaExportJobResponse(job: nil, error: "End time must be after start time.")
            }
            guard end - start <= maxMediaClipDurationSeconds else {
                return MediaExportJobResponse(job: nil, error: "Clip length exceeds 15 minutes.")
            }
        }

        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName

        if primaryDescriptor.ownerNodeName != localNodeName,
           let ownerBaseURL = primaryDescriptor.ownerBaseURL,
           !ownerBaseURL.isEmpty {
            let meshRequest = MeshMediaMultiViewRequest(
                primaryID: primaryDescriptor.itemID,
                secondaryID: secondaryDescriptor.itemID,
                layout: request.layout,
                audioSource: request.audioSource,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            )
            if let job = await cluster.startRemoteMediaMultiView(from: ownerBaseURL, request: meshRequest) {
                await mediaExportCoordinator.recordExternalJob(job)
                return MediaExportJobResponse(job: job, error: nil)
            }
            return MediaExportJobResponse(job: nil, error: "Failed to start multiview export on remote node.")
        }

        let status = await mediaExportCoordinator.ffmpegStatus()
        guard status.installed else {
            return MediaExportJobResponse(job: nil, error: "FFmpeg is not installed on this node.")
        }

        guard let primary = await localMediaItem(for: primaryDescriptor.itemID),
              let secondary = await localMediaItem(for: secondaryDescriptor.itemID) else {
            return MediaExportJobResponse(job: nil, error: "Media item not found.")
        }

        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let job = await mediaExportCoordinator.startMultiView(
            primary: primary,
            secondary: secondary,
            request: request,
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return MediaExportJobResponse(job: job, error: nil)
    }

    func localMediaClipExport(request: MeshMediaClipRequest) async -> MediaExportJob? {
        guard request.endSeconds > request.startSeconds else { return nil }
        guard request.endSeconds - request.startSeconds <= maxMediaClipDurationSeconds else { return nil }
        let status = await mediaExportCoordinator.ffmpegStatus()
        guard status.installed else { return nil }
        guard let item = await localMediaItem(for: request.itemID) else { return nil }
        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let job = await mediaExportCoordinator.startClip(
            item: item,
            request: MediaExportClipRequest(
                token: "",
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            ),
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return job
    }

    func localMediaMultiViewExport(request: MeshMediaMultiViewRequest) async -> MediaExportJob? {
        let status = await mediaExportCoordinator.ffmpegStatus()
        guard status.installed else { return nil }
        if let start = request.startSeconds, let end = request.endSeconds {
            guard end > start, end - start <= maxMediaClipDurationSeconds else { return nil }
        }
        guard let primary = await localMediaItem(for: request.primaryID),
              let secondary = await localMediaItem(for: request.secondaryID) else { return nil }
        let exportRoot = mediaExportRootURL()
        try? FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName
        let job = await mediaExportCoordinator.startMultiView(
            primary: primary,
            secondary: secondary,
            request: MediaExportMultiViewRequest(
                primaryToken: "",
                secondaryToken: "",
                layout: request.layout,
                audioSource: request.audioSource,
                startSeconds: request.startSeconds,
                endSeconds: request.endSeconds,
                name: request.name
            ),
            exportRoot: exportRoot,
            nodeName: localNodeName
        )
        await mediaLibraryIndexer.invalidate()
        return job
    }

    private func startMediaMonitor() {
        guard mediaMonitorTask == nil else { return }
        mediaMonitorTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.scanMediaForNewItems()
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func stopMediaMonitor() {
        mediaMonitorTask?.cancel()
        mediaMonitorTask = nil
        lastSeenMediaItemIDs.removeAll()
    }

    private func scanMediaForNewItems() async {
        guard settings.clusterMode != .standby else { return }
        let shouldScan = ruleStore.rules.contains { $0.isEnabled && $0.trigger == .mediaAdded }
        guard shouldScan else {
            lastSeenMediaItemIDs.removeAll()
            return
        }
        let hasLocalSources = mediaLibrarySettings.sources.contains { $0.isEnabled && !$0.normalizedRootPath.isEmpty }
        if !hasLocalSources && settings.clusterMode != .leader {
            return
        }
        let payloads = await mediaPayloadsForTriggers()

        let allItems: [(payload: MediaLibraryPayload, item: MediaLibraryItem)] = payloads.flatMap { payload in
            payload.items.map { (payload, $0) }
        }
        let currentIDs = Set(allItems.map { "\($0.payload.nodeName)|\($0.item.id)" })

        if lastSeenMediaItemIDs.isEmpty {
            lastSeenMediaItemIDs = currentIDs
            return
        }

        let newItems = allItems.filter { !lastSeenMediaItemIDs.contains("\($0.payload.nodeName)|\($0.item.id)") }
        lastSeenMediaItemIDs = currentIDs

        guard !newItems.isEmpty else { return }
        for entry in newItems {
            await handleMediaAddedEvent(item: entry.item, nodeName: entry.payload.nodeName)
        }
    }

    private func mediaPayloadsForTriggers() async -> [MediaLibraryPayload] {
        var payloads: [MediaLibraryPayload] = [await localMediaLibrarySnapshot()]
        guard settings.clusterMode == .leader else { return payloads }

        let workers = await cluster.registeredNodeInfo()
        for (_, baseURL) in workers {
            if let remote = await cluster.fetchRemoteMediaLibrary(from: baseURL) {
                payloads.append(
                    MediaLibraryPayload(
                        nodeName: remote.nodeName,
                        configFilePath: remote.configFilePath,
                        sources: remote.sources,
                        items: remote.items.map { item in
                            var copy = item
                            if copy.ownerBaseURL == nil || copy.ownerBaseURL?.isEmpty == true {
                                copy.ownerBaseURL = baseURL
                            }
                            return copy
                        },
                        generatedAt: remote.generatedAt
                    )
                )
            }
        }
        return payloads
    }

    private func handleMediaAddedEvent(item: MediaLibraryItem, nodeName: String) async {
        let event = VoiceRuleEvent(
            kind: .mediaAdded,
            guildId: nodeName,
            userId: botUserId ?? "0",
            username: nodeName,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: item.fileName,
            messageId: item.id,
            mediaFileName: item.fileName,
            mediaRelativePath: item.relativePath,
            mediaSourceName: item.sourceName,
            mediaNodeName: nodeName,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: nodeName,
            triggerUserId: botUserId ?? "0",
            isDirectMessage: false,
            authorIsBot: nil,
            joinedAt: nil
        )

        let matchedRules = ruleEngine.evaluateRules(event: event)
        for rule in matchedRules {
            _ = await service.executeRulePipeline(actions: rule.processedActions, for: event, isDirectMessage: event.isDirectMessage)
        }
    }

    func saveMeshCursors(_ cursors: [String: ReplicationCursor]) async {
        do {
            try await meshCursorStore.save(cursors)
        } catch {
            logs.append("⚠️ Failed to save mesh cursors: \(error.localizedDescription)")
        }
    }

    func detectOllamaModel() {
        let base = normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        Task {
            guard let model = await aiService.detectOllamaModel(baseURL: base) else {
                await MainActor.run {
                    self.logs.append("⚠️ Ollama model auto-detect failed.")
                }
                await refreshAIStatus()
                return
            }

            await MainActor.run {
                if self.settings.localAIModel != model {
                    self.settings.localAIModel = model
                    self.saveSettings()
                }
                self.logs.append("✅ Ollama model detected: \(model)")
            }
            await refreshAIStatus()
        }
    }

    func refreshAIStatus() async {
        let status = await aiService.currentAIStatus(
            ollamaBaseURL: normalizedOllamaBaseURL(from: settings.ollamaBaseURL),
            ollamaModelHint: settings.localAIModel,
            openAIAPIKey: effectiveOpenAIAPIKey()
        )
        appleIntelligenceOnline = status.appleOnline
        ollamaOnline = status.ollamaOnline
        ollamaDetectedModel = status.ollamaModel
        openAIOnline = status.openAIOnline
    }

    func normalizedOllamaBaseURL(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "http://localhost:11434" }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "http://\(trimmed)"
    }

    func localAIEndpointForService() -> String {
        if settings.localAIProvider == .ollama {
            return normalizedOllamaBaseURL(from: settings.ollamaBaseURL)
        }
        return settings.localAIEndpoint
    }

    func effectiveOpenAIAPIKey() -> String {
        guard settings.openAIEnabled else { return "" }
        return settings.openAIAPIKey
    }

    func addPatchyTarget(_ target: PatchySourceTarget) {
        settings.patchy.sourceTargets.append(target)
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func addWikiBridgeSourceTarget(_ target: WikiSource) {
        settings.wikiBot.sources.append(target)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func updateWikiBridgeSourceTarget(_ target: WikiSource) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == target.id }) else { return }
        settings.wikiBot.sources[idx] = target
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func deleteWikiBridgeSourceTarget(_ targetID: UUID) {
        settings.wikiBot.sources.removeAll { $0.id == targetID }
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func toggleWikiBridgeSourceTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == targetID }) else { return }
        settings.wikiBot.sources[idx].enabled.toggle()
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func setWikiBridgePrimarySource(_ targetID: UUID) {
        settings.wikiBot.setPrimarySource(targetID)
        settings.wikiBot.normalizeSources()
        saveSettings()
    }

    func testWikiBridgeSource(targetID: UUID) {
        Task {
            guard let target = settings.wikiBot.sources.first(where: { $0.id == targetID }) else { return }
            let usesWeaponCommand = target.commands.contains { normalizedWikiCommandTrigger($0.trigger) == "weapon" }
            let testQuery = usesWeaponCommand ? "AKM" : "Main Page"
            let result = await wikiLookupService.lookupWiki(query: testQuery, source: target)
            updateWikiBridgeSourceRuntimeState(id: targetID) { entry in
                entry.lastLookupAt = Date()
                if let result {
                    entry.lastStatus = "Resolved: \(result.title)"
                } else {
                    entry.lastStatus = "No result for \"\(testQuery)\""
                }
            }
            persistSettingsQuietly()
        }
    }

    func runWikiBridgeSourceTestQuery(source: WikiSource, query: String) async -> FinalsWikiLookupResult? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return await wikiLookupService.lookupWiki(query: trimmed, source: source)
    }

    func updatePatchyTarget(_ target: PatchySourceTarget) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == target.id }) else { return }
        settings.patchy.sourceTargets[idx] = target
        saveSettings()
        resolveSteamNameIfNeeded(for: target)
    }

    func deletePatchyTarget(_ targetID: UUID) {
        settings.patchy.sourceTargets.removeAll { $0.id == targetID }
        saveSettings()
    }

    func togglePatchyTargetEnabled(_ targetID: UUID) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled.toggle()
        saveSettings()
    }

    func setPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == targetID }) else { return }
        settings.patchy.sourceTargets[idx].isEnabled = enabled
        saveSettings()
    }

    func runPatchyManualCheck() {
        Task {
            await runPatchyMonitoringCycle(trigger: "Manual")
        }
    }

    private func validatePatchyTarget(_ target: PatchySourceTarget, forceRefresh: Bool = false) async -> (isValid: Bool, detail: String) {
        let channelId = target.channelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelId.isEmpty else {
            return (false, "Target channel ID is empty.")
        }

        let now = Date()
        if !forceRefresh, let cached = patchyTargetValidationCache[channelId], now.timeIntervalSince(cached.validatedAt) < 3600 {
            return (cached.isValid, cached.detail)
        }

        do {
            _ = try await service.fetchChannel(channelId: channelId, token: settings.token)
            let result = (true, "Ready")
            patchyTargetValidationCache[channelId] = (result.0, result.1, now)
            return result
        } catch {
            let detail = patchyErrorDiagnostic(from: error)
            let result = (false, detail)
            patchyTargetValidationCache[channelId] = (result.0, result.1, now)
            return result
        }
    }

    func sendPatchyTest(targetID: UUID) {
        Task {
            guard let target = settings.patchy.sourceTargets.first(where: { $0.id == targetID }) else { return }
            guard !target.channelId.isEmpty else {
                appendPatchyLog("Test send skipped: target channel is empty.")
                return
            }

            let validation = await validatePatchyTarget(target, forceRefresh: true)
            guard validation.isValid else {
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = validation.detail
                }
                persistSettingsQuietly()
                appendPatchyLog("Patchy test skipped: \(validation.detail)")
                return
            }

            do {
                resolveSteamNameIfNeeded(for: target)
                let source = try PatchyRuntime.makeSource(from: target)
                let item = try await source.fetchLatest()
                let mapped = PatchyRuntime.map(item: item, change: .unchanged(identifier: item.identifier))
                let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                let delivery = await sendPatchyNotificationDetailed(
                    channelId: target.channelId,
                    message: fallback,
                    embedJSON: mapped.embedJSON,
                    roleIDs: target.roleIDs
                )

                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastRunAt = Date()
                    entry.lastStatus = delivery.detail
                }
                persistSettingsQuietly()
                appendPatchyLog("Test send [\(target.source.rawValue)] -> \(delivery.detail)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Patchy test failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                appendPatchyLog("Patchy test failed: \(diagnostic)")
            }
        }
    }

    func pullPatchyUpdate(targetID: UUID) {
        Task {
            guard let target = settings.patchy.sourceTargets.first(where: { $0.id == targetID }) else { return }
            
            do {
                resolveSteamNameIfNeeded(for: target)
                let source = try PatchyRuntime.makeSource(from: target)
                let item = try await source.fetchLatest()
                let mapped = PatchyRuntime.map(item: item, change: .unchanged(identifier: item.identifier))
                
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = mapped.statusSummary
                }
                persistSettingsQuietly()
                appendPatchyLog("Pull [\(target.source.rawValue)] -> \(mapped.statusSummary)")
            } catch {
                let diagnostic = patchyErrorDiagnostic(from: error)
                updatePatchyTargetRuntimeState(id: target.id) { entry in
                    entry.lastCheckedAt = Date()
                    entry.lastStatus = "Pull failed: \(diagnostic)"
                }
                persistSettingsQuietly()
                appendPatchyLog("Pull [\(target.source.rawValue)] failed: \(diagnostic)")
            }
        }
    }

    func configurePatchyMonitoring() {
        patchyMonitorTask?.cancel()
        patchyMonitorTask = nil

        guard settings.patchy.monitoringEnabled else {
            appendPatchyLog("Patchy monitoring paused.")
            return
        }

        patchyMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.runPatchyMonitoringCycle(trigger: "Startup")
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600_000_000_000)
                if Task.isCancelled { break }
                await self.runPatchyMonitoringCycle(trigger: "Scheduled")
            }
        }
        appendPatchyLog("Patchy monitoring started (hourly).")
    }

    struct PatchySourceGroupKey: Hashable {
        let source: PatchySourceKind
        let steamAppID: String
    }

    func runPatchyMonitoringCycle(trigger: String) async {
        guard !patchyIsCycleRunning else { return }
        guard let patchyChecker else {
            appendPatchyLog("Patchy checker unavailable. Cycle skipped.")
            return
        }

        let enabledTargets = settings.patchy.sourceTargets.filter { $0.isEnabled && !$0.channelId.isEmpty }
        guard !enabledTargets.isEmpty else {
            appendPatchyLog("Patchy cycle (\(trigger)) skipped: no enabled targets.")
            patchyLastCycleAt = Date()
            return
        }

        patchyIsCycleRunning = true
        defer {
            patchyIsCycleRunning = false
            patchyLastCycleAt = Date()
        }

        let grouped = Dictionary(grouping: enabledTargets) { target in
            PatchySourceGroupKey(
                source: target.source,
                steamAppID: target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        for (_, targets) in grouped {
            guard let referenceTarget = targets.first else { continue }

            do {
                resolveSteamNameIfNeeded(for: referenceTarget)
                let source = try PatchyRuntime.makeSource(from: referenceTarget)
                let item = try await source.fetchLatest()
                let mapped: PatchyFetchResult
                if let driverItem = item as? DriverUpdateItem {
                    let newestVersion = driverItem.version.trimmingCharacters(in: .whitespacesAndNewlines)
                    let versionKey = PatchyRuntime.lastPostedDriverVersionKey(for: item.sourceKey)
                    let versionCheck = try await patchyChecker.check(identifier: newestVersion, for: versionKey)
                    mapped = PatchyRuntime.map(item: item, change: versionCheck)
                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch versionCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                        appendPatchyLog("Patchy driver baseline initialized [\(referenceTarget.source.rawValue)] version=\(newestVersion)")
                    case .unchanged:
                        break
                    case .changed(let oldVersion, _):
                        guard let comparison = PatchyRuntime.compareDriverVersions(newestVersion, oldVersion) else {
                            try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            appendPatchyLog("Patchy migrated legacy driver baseline [\(referenceTarget.source.rawValue)] old=\(oldVersion) new=\(newestVersion)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer driver [\(referenceTarget.source.rawValue)] latest=\(newestVersion) lastPosted=\(oldVersion)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestVersion, for: versionKey)
                            }
                        }
                    }
                } else if let steamItem = item as? SteamUpdateItem {
                    let newestStamp = PatchyRuntime.makeSteamOrderingStamp(item: steamItem)
                    let steamKey = PatchyRuntime.lastPostedSteamIdentifierKey(for: item.sourceKey)
                    let steamCheck = try await patchyChecker.check(identifier: newestStamp, for: steamKey)
                    mapped = PatchyRuntime.map(item: item, change: steamCheck)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    switch steamCheck {
                    case .firstSeen:
                        try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                        appendPatchyLog("Patchy Steam baseline initialized [\(referenceTarget.steamAppID)] stamp=\(newestStamp)")
                    case .unchanged:
                        break
                    case .changed(let oldStamp, _):
                        guard let comparison = PatchyRuntime.compareSteamOrderingStamp(newestStamp, oldStamp) else {
                            try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            appendPatchyLog("Patchy migrated legacy Steam baseline [\(referenceTarget.steamAppID)] old=\(oldStamp) new=\(newestStamp)")
                            break
                        }

                        guard comparison > 0 else {
                            appendPatchyLog("Patchy ignored non-newer Steam item [\(referenceTarget.steamAppID)] latest=\(newestStamp) lastPosted=\(oldStamp)")
                            break
                        }

                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                            if delivery.ok {
                                try await patchyChecker.save(identifier: newestStamp, for: steamKey)
                            }
                        }
                    }
                } else {
                    let change = try await patchyChecker.check(item: item)
                    try await patchyChecker.save(item: item)
                    mapped = PatchyRuntime.map(item: item, change: change)

                    for target in targets {
                        updatePatchyTargetRuntimeState(id: target.id) { entry in
                            entry.lastCheckedAt = Date()
                            entry.lastStatus = mapped.statusSummary
                        }
                    }

                    if change.isNewItem {
                        let fallback = PatchyRuntime.fallbackMessage(for: mapped)
                        for target in targets {
                            let validation = await validatePatchyTarget(target)
                            guard validation.isValid else {
                                updatePatchyTargetRuntimeState(id: target.id) { entry in
                                    entry.lastCheckedAt = Date()
                                    entry.lastStatus = validation.detail
                                }
                                appendPatchyLog("Patchy cycle [\(target.source.rawValue)] skipped target \(target.channelId): \(validation.detail)")
                                continue
                            }

                            let delivery = await sendPatchyNotificationDetailed(
                                channelId: target.channelId,
                                message: fallback,
                                embedJSON: mapped.embedJSON,
                                roleIDs: target.roleIDs
                            )
                            updatePatchyTargetRuntimeState(id: target.id) { entry in
                                entry.lastRunAt = Date()
                                entry.lastStatus = delivery.detail
                            }
                        }
                    }
                }
            } catch {
                for target in targets {
                    updatePatchyTargetRuntimeState(id: target.id) { entry in
                        entry.lastCheckedAt = Date()
                        entry.lastStatus = "Patchy check failed: \(error.localizedDescription)"
                    }
                }
                appendPatchyLog("Patchy cycle \(referenceTarget.source.rawValue) failed: \(error.localizedDescription)")
            }
        }

        persistSettingsQuietly()
    }

    func updatePatchyTargetRuntimeState(id: UUID, apply: (inout PatchySourceTarget) -> Void) {
        guard let idx = settings.patchy.sourceTargets.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.patchy.sourceTargets[idx]
        apply(&target)
        settings.patchy.sourceTargets[idx] = target
    }

    func updateWikiBridgeSourceRuntimeState(id: UUID, apply: (inout WikiSource) -> Void) {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == id }) else { return }
        var target = settings.wikiBot.sources[idx]
        apply(&target)
        settings.wikiBot.sources[idx] = target
    }

    func appendPatchyLog(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let final = "[\(stamp)] \(line)"
        patchyDebugLogs.insert(final, at: 0)
        if patchyDebugLogs.count > 200 {
            patchyDebugLogs.removeLast(patchyDebugLogs.count - 200)
        }
        logs.append("Patchy: \(line)")
    }

    func persistSettingsQuietly() {
        let snapshot = settings
        Task {
            do {
                try await store.save(snapshot)
                try await swiftMeshConfigStore.save(snapshot.swiftMeshSettings)
            } catch {
                await MainActor.run {
                    self.logs.append("❌ Failed saving settings: \(error.localizedDescription)")
                }
            }
        }
    }

    func migrateLegacyPatchySettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        guard loaded.patchy.sourceTargets.isEmpty, !loaded.patchy.targets.isEmpty else {
            return false
        }

        let migratedTargets = loaded.patchy.targets.map { legacy in
            PatchySourceTarget(
                isEnabled: legacy.isEnabled,
                source: loaded.patchy.source,
                steamAppID: loaded.patchy.steamAppID,
                serverId: legacy.serverId,
                channelId: legacy.channelId,
                roleIDs: legacy.roleIDs
            )
        }

        loaded.patchy.sourceTargets = migratedTargets
        return true
    }

    func migrateLegacyWikiBridgeSettingsIfNeeded(_ loaded: inout BotSettings) -> Bool {
        let previousTargets = loaded.wikiBot.sources.count
        let previousPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        loaded.wikiBot.normalizeSources()
        let currentPrimary = loaded.wikiBot.sources.first(where: { $0.isPrimary })?.id
        return previousTargets != loaded.wikiBot.sources.count || previousPrimary != currentPrimary
    }

    func startBot() async {
        if isRemoteLaunchMode {
            await MainActor.run {
                logs.append("⚠️ Remote Control Mode does not start a local Discord bot.")
            }
            return
        }

        // Worker mode is temporarily disabled pending UX redesign.
        // The underlying code is preserved; re-enable by removing this guard when ready.
        if settings.clusterMode == .worker {
            await MainActor.run {
                logs.append("⚠️ Worker mode is temporarily unavailable. Select Standalone, Primary, or Fail Over in Settings.")
            }
            return
        }

        await cluster.applySettings(
            mode: settings.clusterMode,
            nodeName: settings.clusterNodeName,
            leaderAddress: settings.clusterLeaderAddress,
            leaderPort: settings.clusterLeaderPort,
            listenPort: settings.clusterListenPort,
            sharedSecret: settings.clusterSharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )
        await cluster.setOffloadPolicy(
            aiReplies: settings.clusterOffloadAIReplies,
            wikiLookups: settings.clusterOffloadWikiLookups
        )
        configureMeshSync()

        let runtimeMode = await cluster.currentSnapshot().mode
        if runtimeMode == .standby {
            // Block all Discord output — standby observes events for live dashboard
            // but must not respond until promoted to Primary.
            await service.setOutputAllowed(false)
            logs.append("Fail Over mode active. Connecting to Discord in passive mode; live work remains delegated/primary-only.")
        }

        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }

        guard !normalizedToken.isEmpty else {
            logs.append("⚠️ Token is empty; cannot start bot")
            return
        }

        await connectDiscordInternal()
        startMediaMonitor()
    }

    func connectDiscordAfterPromotion() async {
        // Allow output immediately — the gateway connection is already live if this
        // node was running in standby (passive) mode. Avoid reconnecting if already
        // connected to prevent the brief downtime a disconnect/reconnect would cause.
        await service.setOutputAllowed(true)

        if status == .running {
            // Already connected and receiving events — just flip the output gate.
            logs.append("✅ Output enabled. Now responding as Primary.")
            return
        }

        // Not yet connected (e.g. fresh start without prior standby connection).
        let normalizedToken = normalizedDiscordToken(from: settings.token)
        if settings.token != normalizedToken {
            settings.token = normalizedToken
        }
        guard !normalizedToken.isEmpty else { return }
        await connectDiscordInternal()
    }

    func connectDiscordInternal() async {
        if !serviceCallbacksConfigured {
            await configureServiceCallbacks()
        }

        let token = normalizedDiscordToken(from: settings.token)
        if settings.token != token {
            settings.token = token
        }
        guard !token.isEmpty else {
            logs.append("⚠️ Token is empty; cannot connect")
            status = .stopped
            return
        }

        let tokenValidation = await identityRESTClient.validateBotTokenRich(token)
        lastTokenValidationResult = tokenValidation
        guard tokenValidation.isValid else {
            status = .stopped
            logs.append("❌ Token validation failed: \(tokenValidation.errorMessage)")
            return
        }
        applyBotIdentity(from: tokenValidation)

        status = .connecting
        uptime = UptimeInfo(startedAt: Date())
        await clearVoicePresence()
        patchyTargetValidationCache.removeAll()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        gatewayEventCount = 0
        voiceStateEventCount = 0
        readyEventCount = 0
        guildCreateEventCount = 0
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        startUptimeTicker()

        let weekly = WeeklySummaryPlugin()
        self.weeklyPlugin = weekly
        Task { await pluginManager.add(weekly) }

        await service.connect(token: token)
        logs.append("Connecting to Discord Gateway")
    }

    private func applyBotIdentity(from validation: DiscordService.TokenValidationResult) {
        if let userId = validation.userId, !userId.isEmpty {
            botUserId = userId
        }
        if let username = validation.username, !username.isEmpty {
            botUsername = username
        }
        if let discriminator = validation.discriminator,
           !discriminator.isEmpty,
           discriminator != "0" {
            botDiscriminator = discriminator
        } else {
            botDiscriminator = nil
        }
        if let avatarURL = validation.avatarURL {
            let filename = avatarURL.deletingPathExtension().lastPathComponent
            botAvatarHash = filename.isEmpty ? nil : filename
        } else {
            botAvatarHash = nil
        }
    }

    // MARK: - Onboarding integration

    /// Validates the current token, resolves the OAuth2 client ID, and stores results for
    /// the onboarding UI. Returns `true` on success. Does NOT flip `isOnboardingComplete` —
    /// call `completeOnboarding()` after the user gives explicit confirmation.
    @discardableResult
    func validateAndOnboard() async -> Bool {
        settings.launchMode = .standaloneBot
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else { return false }
        let result = await identityRESTClient.validateBotTokenRich(token)
        lastTokenValidationResult = result
        guard result.isValid else { return false }
        let cid = await resolveClientID(token: token, fallbackUserID: result.userId)
        resolvedClientID = cid
        return true
    }

    /// Flips the onboarding gate after the user has explicitly confirmed they want to proceed.
    /// Persists settings through the Keychain path, then flips `isOnboardingComplete`.
    /// Must only be called after a successful `validateAndOnboard()`.
    func completeOnboarding() {
        viewMode = .local
        saveSettings()
        isOnboardingComplete = true
    }

    func completeRemoteModeOnboarding(primaryNodeAddress: String, accessToken: String) {
        settings.launchMode = .remoteControl
        settings.remoteMode = RemoteModeSettings(
            primaryNodeAddress: primaryNodeAddress,
            accessToken: accessToken
        )
        settings.remoteMode.normalize()
        viewMode = .remote
        saveSettings()
        isOnboardingComplete = true
    }

    /// Handles OAuth session token received via deep link for remote authentication.
    /// Stores the session token in Keychain and updates remote mode settings.
    func handleRemoteAuthSession(_ sessionToken: String) {
        // Store session token in Keychain for secure persistence
        KeychainHelper.save(sessionToken, account: "remote-session-token")
        
        // Update the remote mode settings with the session token
        var currentMode = settings.remoteMode
        currentMode.accessToken = sessionToken
        settings.remoteMode = currentMode
        saveSettings()
        
        // Post notification so UI can react to successful auth
        NotificationCenter.default.post(name: .remoteAuthSessionReceived, object: sessionToken)
    }

    func updateRemoteModeConnection(primaryNodeAddress: String, accessToken: String) {
        settings.remoteMode = RemoteModeSettings(
            primaryNodeAddress: primaryNodeAddress,
            accessToken: accessToken
        )
        settings.remoteMode.normalize()
        saveSettings()
    }

    /// Performs a safe API key reset with deterministic ordering:
    /// 1. Awaits gateway disconnect (cancels reconnect task, sets userInitiatedDisconnect).
    /// 2. Clears all bot runtime state.
    /// 3. Clears the token and persists via the Keychain-backed path (disk settings.json stays redacted).
    /// 4. Clears invite/token validation cache so setup can be run again on demand.
    func clearAPIKey() async {
        // Step 1: deterministic gateway disconnect — awaited before any state mutation.
        await service.disconnect()
        // Step 2: clear runtime state (mirrors stopBot without fire-and-forget disconnect).
        uptimeTask?.cancel()
        uptime = nil
        await clearVoicePresence()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        Task { await pluginManager.removeAll() }
        Task { await cluster.stopAll() }
        status = .stopped
        // Step 3: secure token erase — empty token triggers KeychainHelper.deleteToken() in ConfigStore.
        settings.token = ""
        saveSettings()
        // Step 4: clear onboarding caches; caller decides whether to reopen setup flow.
        resolvedClientID = nil
        lastTokenValidationResult = nil
        logs.append("API key cleared. Please enter a new token to reconnect.")
    }

    /// Returns the app to the initial onboarding/setup screen.
    func runInitialSetup() {
        resolvedClientID = nil
        lastTokenValidationResult = nil
        viewMode = .local
        isOnboardingComplete = false
    }

    private func resolveClientID(token: String, fallbackUserID: String?) async -> String? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallbackUserID }

        if let appID = await identityRESTClient.resolveClientID(token: trimmed) {
            return appID
        }

        return fallbackUserID
    }

    /// Generates a Discord invite URL for the bot, resolving/storing client ID on demand.
    func generateInviteURL(includeSlashCommands: Bool? = nil) async -> String? {
        let cid: String
        if let existing = resolvedClientID {
            cid = existing
        } else {
            let token = normalizedDiscordToken(from: settings.token)
            guard !token.isEmpty else { return nil }
            let resolved = await resolveClientID(token: token, fallbackUserID: nil)
            if let resolved {
                resolvedClientID = resolved
                cid = resolved
            } else {
                let validation = await identityRESTClient.validateBotTokenRich(token)
                guard validation.isValid else {
                    lastTokenValidationResult = validation
                    return nil
                }
                lastTokenValidationResult = validation
                guard let fallback = await resolveClientID(token: token, fallbackUserID: validation.userId) else {
                    return nil
                }
                resolvedClientID = fallback
                cid = fallback
            }
        }
        let includeSlash = includeSlashCommands ?? (settings.commandsEnabled && settings.slashCommandsEnabled)
        return await service.generateInviteURL(clientId: cid, includeSlashCommands: includeSlash)
    }

    // MARK: - Diagnostics

    /// Whether the 10-second Test Connection UI cooldown has elapsed.
    var canRunTestConnection: Bool {
        guard let until = testConnectionCooldownUntil else { return true }
        return Date() >= until
    }

    /// Derived: gateway intents were accepted when Discord sent READY.
    var intentsAccepted: Bool? {
        switch status {
        case .running where readyEventCount > 0: return true
        case .stopped: return nil
        default: return nil
        }
    }

    /// Runs an on-demand REST health probe and updates `connectionDiagnostics`.
    /// Enforces a 10-second UI rate limit — callers must check `canRunTestConnection` first.
    func runTestConnection() async {
        guard canRunTestConnection else { return }
        testConnectionCooldownUntil = Date().addingTimeInterval(10)
        let token = normalizedDiscordToken(from: settings.token)
        guard !token.isEmpty else {
            connectionDiagnostics.lastTestAt = Date()
            connectionDiagnostics.lastTestMessage = "No token configured."
            connectionDiagnostics.restHealth = .error(0, "No token")
            return
        }
        let (isOK, httpStatus, remaining) = await identityRESTClient.restHealthProbe(token: token)
        let now = Date()
        connectionDiagnostics.lastTestAt = now
        connectionDiagnostics.rateLimitRemaining = remaining
        if isOK {
            connectionDiagnostics.restHealth = .ok
            connectionDiagnostics.lastTestMessage = "REST probe OK."
        } else {
            let code = httpStatus ?? 0
            let message = diagnosticsRemediationMessage(httpStatus: code)
            connectionDiagnostics.restHealth = .error(code, message)
            connectionDiagnostics.lastTestMessage = message
        }
    }

    func diagnosticsRemediationMessage(httpStatus: Int) -> String {
        switch httpStatus {
        case 401: return "401 Unauthorized — Token is invalid or revoked. Use Clear API Key to reset."
        case 403: return "403 Forbidden — Bot lacks required permissions. Re-invite with correct permissions."
        case 429: return "429 Rate Limited — Reduce request frequency. Discord will reset the limit automatically."
        case 0:   return "Network failure — Check your internet connection."
        default:  return "HTTP \(httpStatus) — Unexpected error from Discord REST API."
        }
    }

    func gatewayCloseRemediationMessage(code: Int) -> String {
        switch code {
        case 4004: return "Close 4004 — Authentication failed. Token is invalid. Use Clear API Key to reset."
        case 4014: return "Close 4014 — Privileged intent not enabled. Enable SERVER MEMBERS INTENT and MESSAGE CONTENT INTENT in the Discord Developer Portal → Bot tab."
        case 4013: return "Close 4013 — Invalid intents specified. Check the gateway intents bitmask (required: 37507)."
        case 4009: return "Close 4009 — Session timed out. The bot will reconnect automatically."
        case 4000: return "Close 4000 — Unknown gateway error. The bot will attempt to reconnect."
        default:   return "Close \(code) — Gateway closed with error. The bot will attempt to reconnect."
        }
    }

    func normalizedDiscordToken(from raw: String) -> String {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.lowercased().hasPrefix("bot ") {
            token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return token
    }

    func normalizedAdminRedirectPath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/auth/discord/callback" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    func adminWebStatusSnapshot() -> AdminWebStatusPayload {
        AdminWebStatusPayload(
            botStatus: status.rawValue,
            botUsername: botUsername,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIEnabled: settings.adminWebUI.enabled,
            webUIBaseURL: adminWebBaseURL()
        )
    }

    /// Creates a complete snapshot of current configuration for change detection in the UI.
    func createPreferencesSnapshot() -> AppPreferencesSnapshot {
        AppPreferencesSnapshot(
            token: settings.token,
            prefix: settings.prefix,
            autoStart: settings.autoStart,
            clusterMode: settings.clusterMode,
            clusterNodeName: settings.clusterNodeName,
            clusterLeaderAddress: settings.clusterLeaderAddress,
            clusterLeaderPort: settings.clusterLeaderPort,
            clusterListenPort: settings.clusterListenPort,
            clusterSharedSecret: settings.clusterSharedSecret,
            clusterWorkerOffloadEnabled: settings.clusterWorkerOffloadEnabled,
            clusterOffloadAIReplies: settings.clusterOffloadAIReplies,
            clusterOffloadWikiLookups: settings.clusterOffloadWikiLookups,
            mediaSourcesJSON: mediaSourcesSnapshotJSON(),
            adminWebEnabled: settings.adminWebUI.enabled,
            adminWebHost: settings.adminWebUI.bindHost,
            adminWebPort: settings.adminWebUI.port,
            adminWebBaseURL: settings.adminWebUI.publicBaseURL,
            adminWebHTTPSEnabled: settings.adminWebUI.httpsEnabled,
            adminWebCertificateMode: settings.adminWebUI.certificateMode,
            adminWebHostname: settings.adminWebUI.hostname,
            adminWebCloudflareToken: settings.adminWebUI.cloudflareAPIToken,
            adminWebPublicAccessEnabled: settings.adminWebUI.publicAccessEnabled,
            adminWebImportedCertificateFile: settings.adminWebUI.importedCertificateFile,
            adminWebImportedPrivateKeyFile: settings.adminWebUI.importedPrivateKeyFile,
            adminWebImportedCertificateChainFile: settings.adminWebUI.importedCertificateChainFile,
            adminLocalAuthEnabled: settings.adminWebUI.localAuthEnabled,
            adminLocalAuthUsername: settings.adminWebUI.localAuthUsername,
            adminLocalAuthPassword: settings.adminWebUI.localAuthPassword,
            adminRestrictSpecificUsers: settings.adminWebUI.restrictAccessToSpecificUsers,
            adminDiscordClientID: settings.adminWebUI.discordClientID,
            adminDiscordClientSecret: settings.adminWebUI.discordClientSecret,
            adminAllowedUserIDs: settings.adminWebUI.allowedUserIDs.joined(separator: ", "),
            adminRedirectPath: settings.adminWebUI.redirectPath,
            localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
            useAIInGuildChannels: settings.behavior.useAIInGuildChannels,
            allowDMs: settings.behavior.allowDMs,
            preferredAIProvider: settings.preferredAIProvider,
            ollamaBaseURL: settings.ollamaBaseURL,
            ollamaModel: settings.localAIModel,
            ollamaEnabled: settings.ollamaEnabled,
            openAIEnabled: settings.openAIEnabled,
            openAIAPIKey: settings.openAIAPIKey,
            openAIModel: settings.openAIModel,
            openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
            openAIImageModel: settings.openAIImageModel,
            openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser,
            localAISystemPrompt: settings.localAISystemPrompt,
            devFeaturesEnabled: settings.devFeaturesEnabled,
            bugAutoFixEnabled: settings.bugAutoFixEnabled,
            bugAutoFixTriggerEmoji: settings.bugAutoFixTriggerEmoji,
            bugAutoFixCommandTemplate: settings.bugAutoFixCommandTemplate,
            bugAutoFixRepoPath: settings.bugAutoFixRepoPath,
            bugAutoFixGitBranch: settings.bugAutoFixGitBranch,
            bugAutoFixVersionBumpEnabled: settings.bugAutoFixVersionBumpEnabled,
            bugAutoFixPushEnabled: settings.bugAutoFixPushEnabled,
            bugAutoFixRequireApproval: settings.bugAutoFixRequireApproval,
            bugAutoFixApproveEmoji: settings.bugAutoFixApproveEmoji,
            bugAutoFixRejectEmoji: settings.bugAutoFixRejectEmoji,
            bugAutoFixAllowedUsernames: settings.bugAutoFixAllowedUsernames.joined(separator: ", ")
        )
    }

    private func mediaSourcesSnapshotJSON() -> String {
        guard let data = try? JSONEncoder().encode(mediaLibrarySettings.sources),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }

    func adminWebOverviewSnapshot() -> AdminWebOverviewPayload {
        let enabledWikiSourceCount = settings.wikiBot.sources.filter(\.enabled).count
        let patchyTargetCount = settings.patchy.sourceTargets.count
        let patchyEnabledTargetCount = settings.patchy.sourceTargets.filter(\.isEnabled).count
        let actionRuleCount = ruleStore.rules.count
        let enabledActionRuleCount = ruleStore.rules.filter(\.isEnabled).count
        let aiProviderSummary = settings.preferredAIProvider.rawValue
        let clusterLeader = clusterNodes.first(where: { $0.role == .leader })?.hostname
            ?? clusterNodes.first?.hostname
            ?? "Unavailable"
        let connectedNodes = clusterNodes.filter { $0.status != .disconnected }.count

        let metrics: [AdminWebMetricPayload] = [
            AdminWebMetricPayload(
                title: "Bot Status",
                value: status.rawValue.capitalized,
                subtitle: uptime?.text ?? "--"
            ),
            AdminWebMetricPayload(
                title: "Servers Connected",
                value: "\(connectedServers.count)",
                subtitle: settings.clusterMode == .standalone ? "Standalone" : settings.clusterMode.displayName
            ),
            AdminWebMetricPayload(
                title: "Users In Voice",
                value: "\(activeVoice.count)",
                subtitle: "users right now"
            ),
            AdminWebMetricPayload(
                title: "Commands Run",
                value: "\(stats.commandsRun)",
                subtitle: "this session"
            ),
            AdminWebMetricPayload(
                title: "New Recordings",
                value: "\(recentMediaCount24h)",
                subtitle: "last 24 hours"
            ),
            AdminWebMetricPayload(
                title: "WikiBridge Status",
                value: settings.wikiBot.isEnabled ? "Enabled" : "Disabled",
                subtitle: "\(enabledWikiSourceCount) sources"
            ),
            AdminWebMetricPayload(
                title: "Patchy Monitoring",
                value: settings.patchy.monitoringEnabled ? "Monitoring On" : "Monitoring Off",
                subtitle: "\(patchyEnabledTargetCount)/\(patchyTargetCount) targets"
            ),
            AdminWebMetricPayload(
                title: "Active Actions",
                value: "\(enabledActionRuleCount)",
                subtitle: "\(actionRuleCount) total rules"
            ),
            AdminWebMetricPayload(
                title: "AI Bots",
                value: aiProviderSummary,
                subtitle: settings.localAIDMReplyEnabled ? "DM replies enabled" : "DM replies disabled"
            )
        ]

        let recentVoice = Array(voiceLog.prefix(5)).map {
            AdminWebRecentVoicePayload(
                description: $0.description,
                timeText: $0.time.formatted(date: .omitted, time: .standard)
            )
        }

        let recentCommands = Array(commandLog.prefix(5)).map {
            AdminWebRecentCommandPayload(
                title: "\($0.user) @ \($0.server) • \($0.command)",
                timeText: $0.time.formatted(date: .omitted, time: .standard),
                ok: $0.ok
            )
        }

        let activeVoiceUsers = activeVoice
            .sorted { lhs, rhs in
                if lhs.guildId != rhs.guildId { return lhs.guildId < rhs.guildId }
                if lhs.channelName != rhs.channelName { return lhs.channelName.localizedCaseInsensitiveCompare(rhs.channelName) == .orderedAscending }
                return lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
            }
            .map { member in
                AdminWebActiveVoicePayload(
                    userId: member.userId,
                    username: member.username,
                    channelName: member.channelName,
                    serverName: connectedServers[member.guildId] ?? member.guildId,
                    joinedText: "Joined \(member.joinedAt.formatted(date: .omitted, time: .shortened))"
                )
            }

        let webClusterNodes = clusterNodes.map { node in
            AdminWebClusterNodePayload(
                id: node.id,
                displayName: node.displayName,
                role: node.role.rawValue,
                status: node.status.rawValue,
                hostname: node.hostname,
                hardwareModel: node.hardwareModel,
                jobsActive: node.jobsActive,
                latencyMs: node.latencyMs
            )
        }

        return AdminWebOverviewPayload(
            metrics: metrics,
            cluster: AdminWebClusterPayload(
                connectedNodes: connectedNodes,
                leader: clusterLeader,
                mode: clusterSnapshot.mode.rawValue
            ),
            clusterNodes: webClusterNodes,
            activeVoice: activeVoiceUsers,
            recentVoice: recentVoice,
            recentCommands: recentCommands,
            botInfo: AdminWebBotInfoPayload(
                uptime: uptime?.text ?? "--",
                errors: stats.errors,
                state: status.rawValue.capitalized,
                cluster: settings.clusterMode != .standalone ? clusterSnapshot.mode.rawValue : nil
            )
        )
    }

    func remoteStatusSnapshot() -> RemoteStatusPayload {
        let leaderName = clusterNodes.first(where: { $0.role == .leader })?.displayName
            ?? clusterNodes.first?.displayName
            ?? (settings.clusterMode == .standalone ? "Standalone" : "Unavailable")

        return RemoteStatusPayload(
            botStatus: status.rawValue,
            botUsername: botUsername,
            connectedServerCount: connectedServers.count,
            gatewayEventCount: gatewayEventCount,
            uptimeText: uptime?.text,
            webUIBaseURL: adminWebBaseURL(),
            clusterMode: settings.clusterMode.rawValue,
            nodeRole: clusterSnapshot.mode.rawValue,
            leaderName: leaderName,
            generatedAt: Date()
        )
    }

    func remoteRulesSnapshot() -> RemoteRulesPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }
        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableVoiceChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })

        return RemoteRulesPayload(
            rules: ruleStore.rules,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            voiceChannelsByServer: voiceChannelsByServer,
            fetchedAt: Date()
        )
    }

    func remoteEventsSnapshot() -> RemoteEventsPayload {
        let recentActivity = Array(events.suffix(40).reversed()).map { event in
            RemoteActivityEventPayload(
                id: event.id,
                timestamp: event.timestamp,
                kind: event.kind.rawValue,
                message: event.message
            )
        }

        return RemoteEventsPayload(
            activity: recentActivity,
            logs: Array(logs.lines.suffix(120).reversed()),
            fetchedAt: Date()
        )
    }

    func adminWebBaseURL() -> String {
        if adminWebPublicAccessStatus.isEnabled, !adminWebPublicAccessStatus.publicURL.isEmpty {
            return adminWebPublicAccessStatus.publicURL
        }
        if !adminWebResolvedBaseURL.isEmpty {
            return adminWebResolvedBaseURL
        }
        return desiredAdminWebBaseURL(preferHTTPS: settings.adminWebUI.httpsEnabled)
    }

    private func desiredAdminWebBaseURL(preferHTTPS: Bool) -> String {
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }

        let automaticHTTPSHost = settings.adminWebUI.normalizedHostname
        let importedHTTPS = settings.adminWebUI.certificateMode == .importCertificate
        let usesHTTPS = preferHTTPS && (importedHTTPS || !automaticHTTPSHost.isEmpty)
        let host = usesHTTPS && !automaticHTTPSHost.isEmpty ? automaticHTTPSHost : settings.adminWebUI.bindHost
        let scheme = usesHTTPS ? "https" : "http"
        let isDefaultPort = (usesHTTPS && settings.adminWebUI.port == 443) || (!usesHTTPS && settings.adminWebUI.port == 80)
        if isDefaultPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(settings.adminWebUI.port)"
    }

    func adminWebLaunchURL() -> URL? {
        if adminWebPublicAccessStatus.isEnabled,
           let publicURL = URL(string: adminWebPublicAccessStatus.publicURL) {
            return publicURL
        }

        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return URL(string: explicit)
        }

        return URL(string: desiredAdminWebBaseURL(preferHTTPS: settings.adminWebUI.httpsEnabled))
    }

    @discardableResult
    func launchAdminWebUI() -> Bool {
        guard let url = adminWebLaunchURL() else {
            logs.append("⚠️ Admin Web UI URL is invalid.")
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    func adminWebConfigSnapshot() -> AdminWebConfigPayload {
        AdminWebConfigPayload(
            commands: .init(
                enabled: settings.commandsEnabled,
                prefixEnabled: settings.prefixCommandsEnabled,
                slashEnabled: settings.slashCommandsEnabled,
                bugTrackingEnabled: settings.bugTrackingEnabled,
                prefix: settings.prefix
            ),
            aiBots: .init(
                localAIDMReplyEnabled: settings.localAIDMReplyEnabled,
                preferredProvider: settings.preferredAIProvider.rawValue,
                openAIEnabled: settings.openAIEnabled,
                openAIModel: settings.openAIModel,
                openAIImageGenerationEnabled: settings.openAIImageGenerationEnabled,
                openAIImageMonthlyLimitPerUser: settings.openAIImageMonthlyLimitPerUser
            ),
            wikiBridge: .init(
                enabled: settings.wikiBot.isEnabled,
                enabledSources: settings.wikiBot.sources.filter(\.enabled).count,
                totalSources: settings.wikiBot.sources.count
            ),
            patchy: .init(
                monitoringEnabled: settings.patchy.monitoringEnabled,
                enabledTargets: settings.patchy.sourceTargets.filter(\.isEnabled).count,
                totalTargets: settings.patchy.sourceTargets.count
            ),
            swiftMesh: .init(
                mode: settings.clusterMode.rawValue,
                nodeName: settings.clusterNodeName,
                leaderAddress: settings.clusterLeaderAddress,
                listenPort: settings.clusterListenPort,
                offloadAIReplies: settings.clusterOffloadAIReplies,
                offloadWikiLookups: settings.clusterOffloadWikiLookups
            ),
            general: .init(
                autoStart: settings.autoStart,
                webUIEnabled: settings.adminWebUI.enabled,
                webUIBaseURL: adminWebBaseURL()
            )
        )
    }

    func applyAdminWebConfigPatch(_ patch: AdminWebConfigPatch) -> Bool {
        if let value = patch.commandsEnabled { settings.commandsEnabled = value }
        if let value = patch.prefixCommandsEnabled { settings.prefixCommandsEnabled = value }
        if let value = patch.slashCommandsEnabled { settings.slashCommandsEnabled = value }
        if let value = patch.bugTrackingEnabled { settings.bugTrackingEnabled = value }
        if let value = patch.prefix { settings.prefix = value }
        if let value = patch.localAIDMReplyEnabled { settings.localAIDMReplyEnabled = value }
        if let value = patch.preferredAIProvider,
           let provider = AIProviderPreference(rawValue: value) {
            settings.preferredAIProvider = provider
        }
        if let value = patch.openAIEnabled { settings.openAIEnabled = value }
        if let value = patch.openAIModel { settings.openAIModel = value }
        if let value = patch.openAIImageGenerationEnabled { settings.openAIImageGenerationEnabled = value }
        if let value = patch.openAIImageMonthlyLimitPerUser { settings.openAIImageMonthlyLimitPerUser = max(0, value) }
        if let value = patch.wikiBridgeEnabled { settings.wikiBot.isEnabled = value }
        if let value = patch.patchyMonitoringEnabled { settings.patchy.monitoringEnabled = value }
        if let value = patch.clusterMode,
           let mode = ClusterMode(rawValue: value) {
            settings.clusterMode = mode
        }
        if let value = patch.clusterNodeName { settings.clusterNodeName = value }
        if let value = patch.clusterLeaderAddress { settings.clusterLeaderAddress = value }
        if let value = patch.clusterListenPort { settings.clusterListenPort = max(1, value) }
        if let value = patch.clusterOffloadAIReplies { settings.clusterOffloadAIReplies = value }
        if let value = patch.clusterOffloadWikiLookups { settings.clusterOffloadWikiLookups = value }
        if let value = patch.autoStart { settings.autoStart = value }
        saveSettings()
        return true
    }

    func adminWebCommandCatalogSnapshot() -> AdminWebCommandCatalogPayload {
        struct VisualCommand {
            let id: String
            let name: String
            let usage: String
            let description: String
            let category: String
            let surface: String
            let aliases: [String]
            let adminOnly: Bool
        }

        let prefixCatalog = buildFullHelpCatalog(prefix: effectivePrefix())
        let prefixCommands = prefixCatalog.entries.map { entry in
            VisualCommand(
                id: "prefix-\(entry.name)",
                name: entry.name,
                usage: entry.usage,
                description: entry.description,
                category: entry.category.rawValue,
                surface: "prefix",
                aliases: entry.aliases,
                adminOnly: entry.isAdminOnly
            )
        }
        let slashCommands = allSlashCommandDefinitions().compactMap { raw -> VisualCommand? in
            guard let name = raw["name"] as? String else { return nil }
            let description = (raw["description"] as? String) ?? "No description"
            let options = (raw["options"] as? [[String: Any]]) ?? []
            let usageSuffix = options.compactMap { option in
                guard let optionName = option["name"] as? String else { return nil }
                let required = (option["required"] as? Bool) ?? false
                return required ? " \(optionName):<value>" : " [\(optionName):<value>]"
            }.joined()
            return VisualCommand(
                id: "slash-\(name)",
                name: name,
                usage: "/\(name)\(usageSuffix)",
                description: description,
                category: "Slash",
                surface: "slash",
                aliases: [],
                adminOnly: name == "debug"
            )
        }

        var commands = prefixCommands + slashCommands
        commands.append(
            VisualCommand(
                id: "mention-bug",
                name: "bug",
                usage: "@swiftbot bug (reply to a message)",
                description: "Creates a tracked bug report in #swiftbot-dev and manages status via reactions.",
                category: "Server",
                surface: "mention",
                aliases: [],
                adminOnly: true
            )
        )

        let items = commands.sorted { lhs, rhs in
            if lhs.surface != rhs.surface {
                return lhs.surface < rhs.surface
            }
            if lhs.category != rhs.category {
                return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        .map { command in
            AdminWebCommandCatalogItem(
                id: command.id,
                name: command.name,
                usage: command.usage,
                description: command.description,
                category: command.category,
                surface: command.surface.capitalized,
                aliases: command.aliases,
                adminOnly: command.adminOnly,
                enabled: isCommandEnabled(name: command.name, surface: command.surface)
            )
        }

        return AdminWebCommandCatalogPayload(
            commandsEnabled: settings.commandsEnabled,
            prefixCommandsEnabled: settings.prefixCommandsEnabled,
            slashCommandsEnabled: settings.slashCommandsEnabled,
            items: items
        )
    }

    func updateAdminWebCommandEnabled(name: String, surface: String, enabled: Bool) -> Bool {
        setCommandEnabled(name: name, surface: surface, enabled: enabled)
        saveSettings()
        if surface.lowercased() == "slash" {
            Task { await registerSlashCommandsIfNeeded() }
        }
        return true
    }

    func adminWebActionsSnapshot() -> AdminWebActionsPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }

        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let voiceChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableVoiceChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })

        return AdminWebActionsPayload(
            rules: ruleStore.rules,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            voiceChannelsByServer: voiceChannelsByServer,
            builderMetadata: AdminWebBuilderMetadata.generateFromNativeModels(),
            conditionTypes: ConditionType.allCases.map(\.rawValue),
            actionTypes: ActionType.allCases.map(\.rawValue)
        )
    }

    func adminWebPatchySnapshot() -> AdminWebPatchyPayload {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let servers = serverIDs.map { AdminWebSimpleOption(id: $0, name: connectedServers[$0] ?? $0) }
        let textChannelsByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let channels = (availableTextChannelsByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, channels)
        })
        let rolesByServer = Dictionary(uniqueKeysWithValues: serverIDs.map { serverID in
            let roles = (availableRolesByServer[serverID] ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { AdminWebSimpleOption(id: $0.id, name: $0.name) }
            return (serverID, roles)
        })

        return AdminWebPatchyPayload(
            monitoringEnabled: settings.patchy.monitoringEnabled,
            showDebug: settings.patchy.showDebug,
            isCycleRunning: patchyIsCycleRunning,
            lastCycleAt: patchyLastCycleAt,
            debugLogs: Array(patchyDebugLogs.prefix(80)),
            sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
            targets: settings.patchy.sourceTargets,
            servers: servers,
            textChannelsByServer: textChannelsByServer,
            rolesByServer: rolesByServer,
            steamAppNames: settings.patchy.steamAppNames
        )
    }

    func adminWebWikiBridgeSnapshot() -> AdminWebWikiBridgePayload {
        AdminWebWikiBridgePayload(
            enabled: settings.wikiBot.isEnabled,
            sources: settings.wikiBot.sources.sorted { lhs, rhs in
                if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary && !rhs.isPrimary }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        )
    }

    func updateAdminWebWikiBridgeState(_ patch: AdminWebWikiBridgeStatePatch) -> Bool {
        if let enabled = patch.enabled {
            settings.wikiBot.isEnabled = enabled
        }
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func createAdminWebWikiSource() -> WikiSource? {
        let source = WikiSource.genericTemplate()
        addWikiBridgeSourceTarget(source)
        return source
    }

    func upsertAdminWebWikiSource(_ source: WikiSource) -> Bool {
        if settings.wikiBot.sources.contains(where: { $0.id == source.id }) {
            updateWikiBridgeSourceTarget(source)
        } else {
            addWikiBridgeSourceTarget(source)
        }
        return true
    }

    func setAdminWebWikiSourceEnabled(_ sourceID: UUID, enabled: Bool) -> Bool {
        guard let idx = settings.wikiBot.sources.firstIndex(where: { $0.id == sourceID }) else { return false }
        settings.wikiBot.sources[idx].enabled = enabled
        settings.wikiBot.normalizeSources()
        saveSettings()
        return true
    }

    func setAdminWebWikiSourcePrimary(_ sourceID: UUID) -> Bool {
        guard settings.wikiBot.sources.contains(where: { $0.id == sourceID }) else { return false }
        setWikiBridgePrimarySource(sourceID)
        return true
    }

    func testAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        testWikiBridgeSource(targetID: sourceID)
        return true
    }

    func deleteAdminWebWikiSource(_ sourceID: UUID) -> Bool {
        deleteWikiBridgeSourceTarget(sourceID)
        return true
    }

    func updateAdminWebPatchyState(_ patch: AdminWebPatchyStatePatch) -> Bool {
        if let value = patch.monitoringEnabled {
            settings.patchy.monitoringEnabled = value
        }
        if let value = patch.showDebug {
            settings.patchy.showDebug = value
        }
        saveSettings()
        return true
    }

    func createAdminWebPatchyTarget() -> PatchySourceTarget? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        let target = PatchySourceTarget(
            id: UUID(),
            isEnabled: true,
            source: .nvidia,
            steamAppID: "570",
            serverId: serverID,
            channelId: textChannelID,
            roleIDs: [],
            lastCheckedAt: nil,
            lastRunAt: nil,
            lastStatus: "Never checked"
        )
        addPatchyTarget(target)
        return target
    }

    func upsertAdminWebPatchyTarget(_ target: PatchySourceTarget) -> Bool {
        if settings.patchy.sourceTargets.contains(where: { $0.id == target.id }) {
            updatePatchyTarget(target)
        } else {
            addPatchyTarget(target)
        }
        return true
    }

    func deleteAdminWebPatchyTarget(_ targetID: UUID) -> Bool {
        deletePatchyTarget(targetID)
        return true
    }

    func setAdminWebPatchyTargetEnabled(_ targetID: UUID, enabled: Bool) -> Bool {
        setPatchyTargetEnabled(targetID, enabled: enabled)
        return true
    }

    func sendAdminWebPatchyTest(_ targetID: UUID) -> Bool {
        sendPatchyTest(targetID: targetID)
        return true
    }

    func runAdminWebPatchyCheckNow() -> Bool {
        runPatchyManualCheck()
        return true
    }

    func createAdminWebActionRule() -> Rule? {
        let serverIDs = connectedServers.keys.sorted {
            (connectedServers[$0] ?? $0).localizedCaseInsensitiveCompare(connectedServers[$1] ?? $1) == .orderedAscending
        }
        let serverID = serverIDs.first ?? ""
        let textChannelID = availableTextChannelsByServer[serverID]?.first?.id ?? ""
        ruleStore.addNewRule(serverId: serverID, channelId: textChannelID)
        return ruleStore.rules.last
    }

    func upsertAdminWebActionRule(_ rule: Rule) -> Bool {
        if let index = ruleStore.rules.firstIndex(where: { $0.id == rule.id }) {
            ruleStore.rules[index] = rule
        } else {
            ruleStore.rules.append(rule)
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func deleteAdminWebActionRule(_ ruleID: UUID) -> Bool {
        let before = ruleStore.rules.count
        ruleStore.rules.removeAll { $0.id == ruleID }
        if before == ruleStore.rules.count {
            return false
        }
        if ruleStore.selectedRuleID == ruleID {
            ruleStore.selectedRuleID = ruleStore.rules.first?.id
        }
        ruleStore.scheduleAutoSave()
        return true
    }

    func updatePrefixFromAdmin(_ prefix: String) -> Bool {
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        settings.prefix = trimmed
        saveSettings()
        return true
    }

    /// Returns the base URL that OAuth redirect URIs must be built from.
    ///
    /// Priority:
    /// 1. Explicit `publicBaseURL` override (user-configured) — always wins.
    /// 2. Internet Access enabled + hostname configured → `https://<hostname>` (Cloudflare tunnel path).
    /// 3. Dev mode (Internet Access off) → `http://localhost:<port>` — uses `localhost` rather
    ///    than the bind address (127.0.0.1) so redirect URIs match Discord developer portal
    ///    registrations, which typically list localhost not the loopback IP.
    private func oauthPublicBaseURL() -> String {
        let explicit = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit.contains("://") ? explicit : "https://" + explicit
        }

        let hostname = settings.adminWebUI.normalizedHostname
        if settings.adminWebUI.internetAccessEnabled, !hostname.isEmpty {
            return "https://\(hostname)"
        }

        // Dev mode: always use localhost (not bindHost / 127.0.0.1) so the redirect URI
        // matches standard Discord developer portal registrations.
        return "http://localhost:\(settings.adminWebUI.port)"
    }

    func configureAdminWebServer() async {
        let httpsConfiguration = usesLocalRuntime ? await resolveAdminWebHTTPSConfiguration() : nil
        let config = AdminWebServer.Configuration(
            enabled: usesLocalRuntime && settings.adminWebUI.enabled,
            bindHost: settings.adminWebUI.bindHost,
            port: settings.adminWebUI.port,
            publicBaseURL: oauthPublicBaseURL(),
            https: httpsConfiguration,
            discordOAuth: settings.adminWebUI.discordOAuth,
            localAuthEnabled: settings.adminWebUI.localAuthEnabled,
            localAuthUsername: settings.adminWebUI.localAuthUsername,
            localAuthPassword: settings.adminWebUI.localAuthPassword,
            redirectPath: normalizedAdminRedirectPath(settings.adminWebUI.redirectPath),
            allowedUserIDs: settings.adminWebUI.restrictAccessToSpecificUsers
                ? settings.adminWebUI.normalizedAllowedUserIDs
                : [],
            remoteAccessToken: settings.remoteAccessToken,
            devFeaturesEnabled: settings.devFeaturesEnabled
        )

        let runtimeState = await adminWebServer.configure(
            config: config,
            statusProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIEnabled: false,
                        webUIBaseURL: ""
                    )
                }
                return await MainActor.run { model.adminWebStatusSnapshot() }
            },
            remoteStatusProvider: { [weak self] in
                guard let model = self else {
                    return RemoteStatusPayload(
                        botStatus: "stopped",
                        botUsername: "SwiftBot",
                        connectedServerCount: 0,
                        gatewayEventCount: 0,
                        uptimeText: nil,
                        webUIBaseURL: "",
                        clusterMode: ClusterMode.standalone.rawValue,
                        nodeRole: ClusterMode.standalone.rawValue,
                        leaderName: "Unavailable",
                        generatedAt: Date()
                    )
                }
                return await MainActor.run { model.remoteStatusSnapshot() }
            },
            remoteRulesProvider: { [weak self] in
                guard let model = self else {
                    return RemoteRulesPayload(
                        rules: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        fetchedAt: Date()
                    )
                }
                return await MainActor.run { model.remoteRulesSnapshot() }
            },
            updateRemoteRule: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebActionRule(rule) }
            },
            remoteEventsProvider: { [weak self] in
                guard let model = self else {
                    return RemoteEventsPayload(activity: [], logs: [], fetchedAt: Date())
                }
                return await MainActor.run { model.remoteEventsSnapshot() }
            },
            remoteSettingsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        aiBots: .init(localAIDMReplyEnabled: false, preferredProvider: AIProviderPreference.apple.rawValue, openAIEnabled: false, openAIModel: "", openAIImageGenerationEnabled: false, openAIImageMonthlyLimitPerUser: 0),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", listenPort: 38787, offloadAIReplies: false, offloadWikiLookups: false),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: "")
                    )
                }
                return await MainActor.run { model.adminWebConfigSnapshot() }
            },
            updateRemoteSettings: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebConfigPatch(patch) }
            },
            overviewProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebOverviewPayload(
                        metrics: [],
                        cluster: AdminWebClusterPayload(connectedNodes: 0, leader: "Unavailable", mode: "standalone"),
                        clusterNodes: [],
                        activeVoice: [],
                        recentVoice: [],
                        recentCommands: [],
                        botInfo: AdminWebBotInfoPayload(uptime: "--", errors: 0, state: "Stopped", cluster: nil)
                    )
                }
                return await MainActor.run { model.adminWebOverviewSnapshot() }
            },
            connectedGuildIDsProvider: { [weak self] in
                guard let model = self else { return [] }
                return await MainActor.run { Set(model.connectedServers.keys) }
            },
            currentPrefixProvider: { [weak self] in
                guard let model = self else { return "/" }
                return await MainActor.run { model.settings.prefix }
            },
            updatePrefix: { [weak self] prefix in
                guard let model = self else { return false }
                return await MainActor.run { model.updatePrefixFromAdmin(prefix) }
            },
            configProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebConfigPayload(
                        commands: .init(enabled: true, prefixEnabled: true, slashEnabled: true, bugTrackingEnabled: true, prefix: "/"),
                        aiBots: .init(localAIDMReplyEnabled: false, preferredProvider: AIProviderPreference.apple.rawValue, openAIEnabled: false, openAIModel: "", openAIImageGenerationEnabled: false, openAIImageMonthlyLimitPerUser: 0),
                        wikiBridge: .init(enabled: false, enabledSources: 0, totalSources: 0),
                        patchy: .init(monitoringEnabled: false, enabledTargets: 0, totalTargets: 0),
                        swiftMesh: .init(mode: ClusterMode.standalone.rawValue, nodeName: "SwiftBot", leaderAddress: "", listenPort: 38787, offloadAIReplies: true, offloadWikiLookups: true),
                        general: .init(autoStart: false, webUIEnabled: false, webUIBaseURL: "")
                    )
                }
                return await MainActor.run { model.adminWebConfigSnapshot() }
            },
            updateConfig: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.applyAdminWebConfigPatch(patch) }
            },
            commandCatalogProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebCommandCatalogPayload(
                        commandsEnabled: true,
                        prefixCommandsEnabled: true,
                        slashCommandsEnabled: true,
                        items: []
                    )
                }
                return await MainActor.run { model.adminWebCommandCatalogSnapshot() }
            },
            updateCommandEnabled: { [weak self] name, surface, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebCommandEnabled(name: name, surface: surface, enabled: enabled) }
            },
            actionsProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebActionsPayload(
                        rules: [],
                        servers: [],
                        textChannelsByServer: [:],
                        voiceChannelsByServer: [:],
                        builderMetadata: AdminWebBuilderMetadata.generateFromNativeModels(),
                        conditionTypes: ConditionType.allCases.map(\.rawValue),
                        actionTypes: ActionType.allCases.map(\.rawValue)
                    )
                }
                return await MainActor.run { model.adminWebActionsSnapshot() }
            },
            createActionRule: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebActionRule() }
            },
            updateActionRule: { [weak self] rule in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebActionRule(rule) }
            },
            deleteActionRule: { [weak self] ruleID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebActionRule(ruleID) }
            },
            patchyProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebPatchyPayload(
                        monitoringEnabled: false,
                        showDebug: false,
                        isCycleRunning: false,
                        lastCycleAt: nil,
                        debugLogs: [],
                        sourceKinds: PatchySourceKind.allCases.map(\.rawValue),
                        targets: [],
                        servers: [],
                        textChannelsByServer: [:],
                        rolesByServer: [:],
                        steamAppNames: [:]
                    )
                }
                return await MainActor.run { model.adminWebPatchySnapshot() }
            },
            updatePatchyState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebPatchyState(patch) }
            },
            createPatchyTarget: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebPatchyTarget() }
            },
            updatePatchyTarget: { [weak self] target in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebPatchyTarget(target) }
            },
            setPatchyTargetEnabled: { [weak self] targetID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebPatchyTargetEnabled(targetID, enabled: enabled) }
            },
            deletePatchyTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebPatchyTarget(targetID) }
            },
            sendPatchyTestTarget: { [weak self] targetID in
                guard let model = self else { return false }
                return await MainActor.run { model.sendAdminWebPatchyTest(targetID) }
            },
            runPatchyCheckNow: { [weak self] in
                guard let model = self else { return false }
                return await MainActor.run { model.runAdminWebPatchyCheckNow() }
            },
            wikiBridgeProvider: { [weak self] in
                guard let model = self else {
                    return AdminWebWikiBridgePayload(enabled: false, sources: [])
                }
                return await MainActor.run { model.adminWebWikiBridgeSnapshot() }
            },
            updateWikiBridgeState: { [weak self] patch in
                guard let model = self else { return false }
                return await MainActor.run { model.updateAdminWebWikiBridgeState(patch) }
            },
            createWikiSource: { [weak self] in
                guard let model = self else { return nil }
                return await MainActor.run { model.createAdminWebWikiSource() }
            },
            updateWikiSource: { [weak self] source in
                guard let model = self else { return false }
                return await MainActor.run { model.upsertAdminWebWikiSource(source) }
            },
            setWikiSourceEnabled: { [weak self] sourceID, enabled in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourceEnabled(sourceID, enabled: enabled) }
            },
            setWikiSourcePrimary: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.setAdminWebWikiSourcePrimary(sourceID) }
            },
            testWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.testAdminWebWikiSource(sourceID) }
            },
            deleteWikiSource: { [weak self] sourceID in
                guard let model = self else { return false }
                return await MainActor.run { model.deleteAdminWebWikiSource(sourceID) }
            },
            mediaLibraryProvider: { [weak self] query in
                guard let model = self else {
                    return AdminWebMediaLibraryPayload(
                        generatedAt: Date(),
                        sources: [],
                        items: [],
                        games: [],
                        selectedSourceID: nil,
                        selectedDateRange: "all",
                        selectedGame: nil,
                        page: 1,
                        pageSize: 24,
                        totalItems: 0,
                        totalPages: 1
                    )
                }
                return await model.adminWebMediaLibrarySnapshot(query: query)
            },
            mediaStreamProvider: { [weak self] token, rangeHeader in
                guard let model = self else { return nil }
                return await model.adminWebMediaStreamResponse(token: token, rangeHeader: rangeHeader)
            },
            mediaThumbnailProvider: { [weak self] token in
                guard let model = self else { return nil }
                return await model.adminWebMediaThumbnailResponse(token: token)
            },
            mediaFrameProvider: { [weak self] token, seconds in
                guard let model = self else { return nil }
                return await model.adminWebMediaFrameResponse(token: token, atSeconds: seconds)
            },
            mediaExportStatusProvider: { [weak self] in
                guard let model = self else { return MediaExportStatus(installed: false, version: nil, path: nil) }
                return await model.adminWebMediaExportStatus()
            },
            mediaExportJobsProvider: { [weak self] in
                guard let model = self else { return MediaExportJobsPayload(jobs: []) }
                return await model.adminWebMediaExportJobs()
            },
            mediaClipExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaClipExport(request: request)
            },
            mediaMultiViewExportStarter: { [weak self] request in
                guard let model = self else { return MediaExportJobResponse(job: nil, error: "Unavailable") }
                return await model.adminWebStartMediaMultiViewExport(request: request)
            },
            startBot: { [weak self] in
                guard let model = self else { return false }
                await model.startBot()
                return true
            },
            stopBot: { [weak self] in
                guard let model = self else { return false }
                await model.stopBot()
                return true
            },
            refreshSwiftMesh: { [weak self] in
                guard let model = self else { return false }
                _ = await MainActor.run { model.refreshClusterStatus() }
                return true
            },
            log: { [weak self] message in
                guard let model = self else { return }
                await MainActor.run { model.logs.append(message) }
            }
        )
        adminWebResolvedBaseURL = runtimeState.publicBaseURL
        updateAdminWebCertificateRenewalTask()
        await updateAdminWebPublicAccessRuntime()
    }

    private func resolveAdminWebHTTPSConfiguration() async -> AdminWebServer.Configuration.HTTPSConfiguration? {
        guard settings.adminWebUI.enabled, settings.adminWebUI.httpsEnabled else {
            return nil
        }

        do {
            switch settings.adminWebUI.certificateMode {
            case .automatic:
                let domain = settings.adminWebUI.normalizedHostname
                guard !domain.isEmpty else {
                    logs.append("⚠️ Admin Web UI HTTPS is enabled, but no hostname is configured. Falling back to HTTP.")
                    return nil
                }

                let logStore = logs
                let certificate = try await certificateManager.ensureCertificate(
                    for: domain,
                    cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken
                ) { message in
                    logStore.append(message)
                }

                return AdminWebServer.Configuration.HTTPSConfiguration(
                    certificatePath: certificate.certificateURL.path,
                    privateKeyPath: certificate.privateKeyURL.path,
                    hostOverride: domain,
                    reloadToken: domain
                )
            case .importCertificate:
                let imported = try await certificateManager.prepareImportedCertificate(
                    certificateFilePath: settings.adminWebUI.importedCertificateFile,
                    privateKeyFilePath: settings.adminWebUI.importedPrivateKeyFile,
                    certificateChainFilePath: settings.adminWebUI.importedCertificateChainFile
                )

                logs.append("📥 Using imported TLS certificate for the Admin Web UI.")
                return AdminWebServer.Configuration.HTTPSConfiguration(
                    certificatePath: imported.certificateURL.path,
                    privateKeyPath: imported.privateKeyURL.path,
                    hostOverride: nil,
                    reloadToken: imported.reloadToken
                )
            }
        } catch {
            logs.append("⚠️ Admin Web UI HTTPS unavailable: \(error.localizedDescription). Falling back to HTTP.")
            return nil
        }
    }

    func validateAdminWebAutomaticHTTPSConfiguration() async -> CertificateManager.AutomaticHTTPSValidation {
        await certificateManager.validateAutomaticHTTPSConfiguration(
            for: settings.adminWebUI.normalizedHostname,
            cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken
        )
    }

    func createAdminWebAutomaticHTTPSDNSRecord() async throws -> CertificateManager.DNSRecordCreation {
        let creation = try await certificateManager.createAutomaticHTTPSDNSRecord(
            for: settings.adminWebUI.normalizedHostname,
            cloudflareAPIToken: settings.adminWebUI.cloudflareAPIToken,
            publicBaseURL: settings.adminWebUI.publicBaseURL,
            bindHost: settings.adminWebUI.bindHost
        )

        logs.append("🌐 Created Cloudflare \(creation.type) record \(creation.name) -> \(creation.content) in \(creation.zoneName).")
        return creation
    }

    func startAdminWebAutomaticHTTPSProvisioning(
        progress: @escaping @MainActor @Sendable (AdminWebAutomaticHTTPSSetupEvent) -> Void
    ) async throws -> String {
        let normalizedDomain = settings.adminWebUI.normalizedHostname
        guard !normalizedDomain.isEmpty else {
            throw CertificateManager.Error.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CertificateManager.Error.missingCloudflareToken
        }

        settings.adminWebUI.hostname = normalizedDomain
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.publicBaseURL = settings.adminWebUI.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.adminWebUI.enabled = true

        let logStore = logs
        let result = try await certificateManager.setupAutomaticHTTPS(
            for: normalizedDomain,
            cloudflareAPIToken: trimmedToken,
            progress: progress
        ) { message in
            logStore.append(message)
        }

        progress(.enablingHTTPSListener)
        await configureAdminWebServer()

        if settings.adminWebUI.enabled,
           !adminWebResolvedBaseURL.lowercased().hasPrefix("https://") {
            throw AdminWebHTTPSProvisioningError.tlsActivationFailed
        }
        progress(.httpsListenerEnabled(url: adminWebResolvedBaseURL))

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Settings saved")

        if result.alreadyConfigured || !result.certificate.wasRenewed {
            logs.append("🔒 Admin Web UI HTTPS already configured.")
            return "HTTPS already configured"
        }

        logs.append("🔒 Admin Web UI HTTPS enabled.")
        return "HTTPS enabled"
    }

    func userFacingAdminWebHTTPSSetupMessage(for error: Error) -> String {
        switch error {
        case let error as CertificateManager.Error:
            return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
        case let error as CloudflareDNSProvider.Error:
            switch error {
            case .identicalRecordAlreadyExists:
                return "DNS challenge record verified. Existing DNS record will be reused for certificate provisioning."
            default:
                return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
            }
        case let error as ACMEClient.Error:
            switch error {
            case .invalidResponse,
                 .missingReplayNonce,
                 .missingAccountLocation,
                 .missingAuthorizations:
                return genericAdminWebHTTPSSetupFailureMessage
            case .dnsChallengeUnavailable,
                 .dnsPropagationTimedOut:
                return error.errorDescription ?? genericAdminWebHTTPSSetupFailureMessage
            case .orderFailed(let message),
                 .challengeFailed(let message):
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !trimmed.localizedCaseInsensitiveContains("data couldn")
                else {
                    return genericAdminWebHTTPSSetupFailureMessage
                }
                return trimmed
            }
        case let error as LocalizedError:
            let message = error.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? genericAdminWebHTTPSSetupFailureMessage : message
        default:
            return genericAdminWebHTTPSSetupFailureMessage
        }
    }

    func adminWebPublicAccessURL() -> URL? {
        if !adminWebPublicAccessStatus.publicURL.isEmpty {
            return URL(string: adminWebPublicAccessStatus.publicURL)
        }

        let hostname = effectiveAdminWebHostname()
        guard !hostname.isEmpty else { return nil }
        return URL(string: "https://\(hostname)")
    }

    func startAdminWebPublicAccessSetup(
        progress: @escaping @MainActor @Sendable (AdminWebPublicAccessSetupEvent) -> Void,
        forceReplaceDNS: Bool = false
    ) async throws -> String {
        logs.append("=== Public Access Setup Started ===")
        
        let hostname = effectiveAdminWebHostname()
        logs.append("Hostname: \(hostname)")
        guard !hostname.isEmpty else {
            logs.append("❌ Missing hostname")
            throw AdminWebPublicAccessError.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            logs.append("❌ Missing Cloudflare API token")
            throw CertificateManager.Error.missingCloudflareToken
        }
        logs.append("✅ API token present")

        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.enabled = true

        logs.append("Proceeding to Cloudflare tunnel detection...")
        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        let tunnelClient = CloudflareTunnelClient(apiToken: trimmedToken)

        // Verify token in background (non-blocking, warning-level logging only)
        progress(.verifyingCloudflareAccess)
        Task.detached(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                await self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                await self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
            }
        }

        // Continue without waiting for verification result
        logs.append("Cloudflare tunnel detection proceeding (verification in background)...")

        progress(.detectingCloudflareZone(domain: hostname))
        guard let zone = try await dnsProvider.findZone(for: hostname) else {
            throw CloudflareDNSProvider.Error.zoneNotFound(hostname)
        }
        logs.append("Cloudflare zone detected")
        progress(.cloudflareZoneDetected(zone: zone.name))

        guard let originURL = adminWebPublicAccessOriginURL() else {
            throw AdminWebPublicAccessError.invalidOriginURL
        }

        progress(.creatingTunnel(hostname: hostname))
        let (tunnel, alreadyExists) = try await tunnelClient.createTunnel(hostname: hostname, zone: zone)
        if alreadyExists {
            logs.append("Cloudflare tunnel detected")
            logs.append("Using existing tunnel: \(tunnel.name)")
            progress(.tunnelDetected(name: tunnel.name))
        } else {
            progress(.tunnelCreated(name: tunnel.name))
        }

        logs.append("Configuring tunnel ingress...")
        do {
            try await tunnelClient.configureTunnel(tunnel, hostname: hostname, originURL: originURL)
            logs.append("Tunnel ingress configured")
        } catch let tunnelError as CloudflareTunnelClient.Error {
            logs.append("Tunnel configuration error: \(tunnelError.localizedDescription)")
            if alreadyExists && isTunnelConfigurationAuthError(tunnelError) {
                logs.append("⚠️ Tunnel configuration skipped (existing tunnel may already be configured)")
            } else {
                throw tunnelError
            }
        }

        logs.append("Configuring Cloudflare DNS route...")
        logs.append("Tunnel: \(tunnel.name)")
        logs.append("Hostname: \(hostname)")
        progress(.creatingTunnelDNSRecord(hostname: hostname))
        let tunnelTarget = CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id)
        logs.append("Tunnel target: \(tunnelTarget)")

        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS
        )

        switch dnsResult {
        case .created:
            logs.append("DNS route created for \(hostname)")
        case .alreadyConfigured:
            logs.append("DNS route already configured for \(hostname)")
        case .replaced(let previousType):
            logs.append("Replaced existing \(previousType) record with Cloudflare Tunnel route for \(hostname)")
        }
        progress(.tunnelDNSRecordCreated(hostname: hostname))

        progress(.storingTunnelCredentials)
        settings.adminWebUI.internetAccessEnabled = true
        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.publicAccessTunnelID = tunnel.id
        settings.adminWebUI.publicAccessTunnelName = tunnel.name
        settings.adminWebUI.publicAccessTunnelAccountID = tunnel.accountID
        settings.adminWebUI.publicAccessTunnelToken = tunnel.token

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Settings saved")

        progress(.startingTunnelProcess)
        await configureAdminWebServer()

        if adminWebPublicAccessStatus.state == .error {
            throw AdminWebPublicAccessError.tunnelStartupFailed(adminWebPublicAccessStatus.detail)
        }

        let publicURL = "https://\(hostname)"
        logs.append("Public access available at \(publicURL)")
        progress(.publicAccessEnabled(url: publicURL))
        return "Public access enabled"
    }

    /// Stops the Cloudflare tunnel and disables Internet Access at runtime,
    /// but keeps all configuration (token, zone, hostname, tunnel credentials)
    /// so the user can re-enable without re-running setup.
    func stopInternetAccess() async {
        settings.adminWebUI.internetAccessEnabled = false
        await configureAdminWebServer()
        do {
            try await store.save(settings)
            try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        } catch {
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
        }
    }

    /// Performs a destructive reset of Internet Access:
    /// deletes the DNS record and Cloudflare Tunnel, then clears all stored
    /// configuration (token, zone, hostname, tunnel credentials).
    func resetInternetAccess() async {
        let hostname = effectiveAdminWebHostname()
        let tunnelID = settings.adminWebUI.publicAccessTunnelID
        let accountID = settings.adminWebUI.publicAccessTunnelAccountID
        let apiToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)

        // Stop the tunnel first
        settings.adminWebUI.internetAccessEnabled = false
        settings.adminWebUI.publicAccessTunnelID = ""
        settings.adminWebUI.publicAccessTunnelName = ""
        settings.adminWebUI.publicAccessTunnelAccountID = ""
        settings.adminWebUI.publicAccessTunnelToken = ""
        await configureAdminWebServer()

        // Clean up the Cloudflare-side resources
        if !apiToken.isEmpty, !tunnelID.isEmpty, !accountID.isEmpty, !hostname.isEmpty {
            let dnsProvider = CloudflareDNSProvider(apiToken: apiToken)
            let tunnelClient = CloudflareTunnelClient(apiToken: apiToken)
            do {
                if let zone = try await dnsProvider.findZone(for: hostname),
                   let record = try await dnsProvider.findDNSRecord(
                        zoneID: zone.id,
                        hostname: hostname,
                        allowedTypes: ["CNAME"],
                        expectedContent: CloudflareTunnelClient.tunnelTargetHostname(for: tunnelID)
                   ) {
                    try? await dnsProvider.deleteDNSRecord(record)
                }
                try? await tunnelClient.deleteTunnel(accountID: accountID, tunnelID: tunnelID)
            } catch {
                logs.append("⚠️ Internet Access reset cleanup warning: \(error.localizedDescription)")
            }
        }

        // Clear all configuration to return to initial state
        settings.adminWebUI.cloudflareAPIToken = ""
        settings.adminWebUI.selectedZoneID = ""
        settings.adminWebUI.selectedZoneName = ""
        settings.adminWebUI.subdomain = ""
        settings.adminWebUI.hostname = ""

        do {
            try await store.save(settings)
            try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
            logs.append("✅ Internet Access reset complete")
        } catch {
            logs.append("❌ Failed saving settings: \(error.localizedDescription)")
        }
    }

    @available(*, deprecated, renamed: "resetInternetAccess")
    func disableAdminWebPublicAccess() async {
        await resetInternetAccess()
    }

    // MARK: - Unified Internet Access Setup

    /// Verifies the Cloudflare API token and returns available zones.
    /// - Parameter token: The Cloudflare API token to verify
    /// - Returns: Array of zones available to this token
    func verifyCloudflareTokenAndListZones(token: String) async throws -> [CloudflareDNSProvider.ZoneSummary] {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw CertificateManager.Error.missingCloudflareToken
        }
        
        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        
        // First verify the token is valid by checking user info
        let isValid = await dnsProvider.verifyAPIToken()
        guard isValid else {
            throw CertificateManager.Error.inactiveCloudflareToken
        }
        
        // Then list all available zones
        return try await dnsProvider.listZones()
    }

    func startInternetAccessSetup(
        progress: @escaping @MainActor @Sendable (InternetAccessSetupEvent) -> Void,
        forceReplaceDNS: Bool = false
    ) async throws -> String {
        logs.append("=== Internet Access Setup Started ===")
        
        let hostname = effectiveAdminWebHostname()
        logs.append("Hostname: \(hostname)")
        guard !hostname.isEmpty else {
            logs.append("❌ Missing hostname")
            throw AdminWebPublicAccessError.missingHostname
        }

        let trimmedToken = settings.adminWebUI.cloudflareAPIToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            logs.append("❌ Missing Cloudflare API token")
            throw CertificateManager.Error.missingCloudflareToken
        }
        logs.append("✅ API token present")

        settings.adminWebUI.hostname = hostname
        settings.adminWebUI.cloudflareAPIToken = trimmedToken
        settings.adminWebUI.enabled = true

        let dnsProvider = CloudflareDNSProvider(apiToken: trimmedToken)
        let tunnelClient = CloudflareTunnelClient(apiToken: trimmedToken)

        // Step 1: Verify Cloudflare API (non-blocking, background task)
        progress(.verifyingCloudflareAccess)
        Task.detached(priority: .background) {
            let tokenIsValid = await dnsProvider.verifyAPIToken()
            if tokenIsValid {
                await self.logs.append("✅ Cloudflare API verified (background)")
                await MainActor.run {
                    progress(.cloudflareAccessVerified)
                }
            } else {
                await self.logs.append("⚠️ Cloudflare API verification failed (token may be invalid or timed out)")
            }
        }

        // Continue without waiting for verification result
        logs.append("Cloudflare tunnel detection proceeding (verification in background)...")

        // Step 2: Detect Cloudflare zone
        progress(.detectingCloudflareZone(domain: hostname))
        guard let zone = try await dnsProvider.findZone(for: hostname) else {
            throw CloudflareDNSProvider.Error.zoneNotFound(hostname)
        }
        logs.append("Cloudflare zone detected: \(zone.name)")
        progress(.cloudflareZoneDetected(zone: zone.name))

        // Step 3: Detect or create tunnel
        progress(.creatingTunnel(hostname: hostname))
        let (tunnel, alreadyExists) = try await tunnelClient.createTunnel(hostname: hostname, zone: zone)
        if alreadyExists {
            logs.append("Cloudflare tunnel detected")
            logs.append("Using existing tunnel: \(tunnel.name)")
            progress(.tunnelDetected(name: tunnel.name))
        } else {
            logs.append("Created tunnel: \(tunnel.name)")
            progress(.tunnelCreated(name: tunnel.name))
        }

        // Configure tunnel ingress
        logs.append("Configuring tunnel ingress...")
        do {
            try await tunnelClient.configureTunnel(tunnel, hostname: hostname, originURL: "http://localhost:\(settings.adminWebUI.port)")
            logs.append("Tunnel ingress configured")
        } catch let tunnelError as CloudflareTunnelClient.Error {
            logs.append("Tunnel configuration error: \(tunnelError.localizedDescription)")
            if alreadyExists && isTunnelConfigurationAuthError(tunnelError) {
                logs.append("⚠️ Tunnel configuration skipped (existing tunnel may already be configured)")
            } else {
                throw tunnelError
            }
        }

        // Step 4: Configure DNS route
        progress(.creatingTunnelDNSRecord(hostname: hostname))
        let tunnelTarget = CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id)
        logs.append("Tunnel target: \(tunnelTarget)")

        let dnsResult = try await dnsProvider.configureTunnelDNSRoute(
            hostname: hostname,
            tunnelTarget: tunnelTarget,
            zoneID: zone.id,
            force: forceReplaceDNS
        )

        switch dnsResult {
        case .created:
            logs.append("DNS route created for \(hostname)")
        case .alreadyConfigured:
            logs.append("DNS route already configured for \(hostname)")
        case .replaced(let previousType):
            logs.append("Replaced existing \(previousType) record with Cloudflare Tunnel route for \(hostname)")
        }
        progress(.tunnelDNSRecordCreated(hostname: hostname))

        // Step 5: Issue HTTPS certificate (handled automatically by Cloudflare)
        progress(.issuingHTTPSCertificate(hostname: hostname))
        logs.append("HTTPS certificate provisioned by Cloudflare")
        progress(.httpsCertificateIssued(hostname: hostname))

        // Step 6: Save tunnel credentials and start Cloudflare Tunnel
        progress(.startingCloudflareTunnel)
        settings.adminWebUI.internetAccessEnabled = true
        settings.adminWebUI.publicAccessTunnelID = tunnel.id
        settings.adminWebUI.publicAccessTunnelName = tunnel.name
        settings.adminWebUI.publicAccessTunnelAccountID = tunnel.accountID
        settings.adminWebUI.publicAccessTunnelToken = tunnel.token

        try await store.save(settings)
        try await swiftMeshConfigStore.save(settings.swiftMeshSettings)
        logs.append("✅ Tunnel credentials saved")

        // Start the tunnel (local HTTP server is already running via configureAdminWebServer)
        await configureAdminWebServer()

        if adminWebPublicAccessStatus.state == .error {
            throw AdminWebPublicAccessError.tunnelStartupFailed(adminWebPublicAccessStatus.detail)
        }
        logs.append("Cloudflare tunnel started")
        progress(.cloudflareTunnelStarted)

        // Step 6: Internet Access enabled
        let publicURL = "https://\(hostname)"
        logs.append("Internet Access enabled at \(publicURL)")
        progress(.internetAccessEnabled(url: publicURL))
        return "Internet Access enabled"
    }

    private func isTunnelConfigurationAuthError(_ error: CloudflareTunnelClient.Error) -> Bool {
        guard case .apiFailed(let message) = error else { return false }
        return message.localizedCaseInsensitiveContains("auth")
            || message.localizedCaseInsensitiveContains("permission")
            || message.localizedCaseInsensitiveContains("forbidden")
            || message.localizedCaseInsensitiveContains("10000")
    }

    func userFacingAdminWebPublicAccessMessage(for error: Error) -> String {
        switch error {
        case let error as AdminWebPublicAccessError:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CertificateManager.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CloudflareDNSProvider.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as CloudflareTunnelClient.Error:
            let message = error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
            if message.localizedCaseInsensitiveContains("authentication") || 
               message.localizedCaseInsensitiveContains("access denied") ||
               message.localizedCaseInsensitiveContains("permission") {
                return "Cloudflare authentication failed. Ensure your API token has 'Cloudflare Tunnel: Edit' permissions."
            }
            return message
        case let error as TunnelManager.Error:
            return error.errorDescription ?? genericAdminWebPublicAccessFailureMessage
        case let error as LocalizedError:
            let message = error.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return message.isEmpty ? genericAdminWebPublicAccessFailureMessage : message
        default:
            return genericAdminWebPublicAccessFailureMessage
        }
    }

    private func updateAdminWebPublicAccessRuntime() async {
        let logger: @MainActor @Sendable (String) -> Void = { [weak self] message in
            self?.logs.append(message)
        }
        let statusHandler: @MainActor @Sendable (AdminWebPublicAccessRuntimeStatus) -> Void = { [weak self] status in
            self?.adminWebPublicAccessStatus = status
        }

        guard settings.adminWebUI.enabled,
              settings.adminWebUI.publicAccessEnabled
        else {
            await tunnelProvider.configure(nil, logger: logger, statusHandler: statusHandler)
            return
        }

        let hostname = effectiveAdminWebHostname()
        let tunnelToken = settings.adminWebUI.publicAccessTunnelToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnelID = settings.adminWebUI.publicAccessTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !hostname.isEmpty, !tunnelToken.isEmpty, !tunnelID.isEmpty,
              let originURL = adminWebPublicAccessOriginURL() else {
            await tunnelProvider.configure(nil, logger: logger, statusHandler: statusHandler)
            adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus(
                state: .error,
                publicURL: hostname.isEmpty ? "" : "https://\(hostname)",
                detail: "Public Access is enabled but the stored tunnel configuration is incomplete."
            )
            return
        }

        await tunnelProvider.configure(
            .init(
                hostname: hostname,
                publicURL: "https://\(hostname)",
                originURL: originURL,
                tunnelToken: tunnelToken
            ),
            logger: logger,
            statusHandler: statusHandler
        )
    }

    private func effectiveAdminWebHostname() -> String {
        let explicit = settings.adminWebUI.normalizedHostname
        if !explicit.isEmpty {
            return explicit
        }
        return settings.adminWebUI.normalizedHostname
    }

    private func adminWebPublicAccessOriginURL() -> String? {
        let trimmedHost = settings.adminWebUI.bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = trimmedHost.lowercased()

        let originHost: String
        switch normalizedHost {
        case "", "0.0.0.0", "::", "[::]", "localhost":
            originHost = "127.0.0.1"
        default:
            originHost = trimmedHost
        }

        guard !originHost.isEmpty else {
            return nil
        }

        if originHost.contains(":") && !originHost.hasPrefix("[") {
            return "http://[\(originHost)]:\(settings.adminWebUI.port)"
        }

        return "http://\(originHost):\(settings.adminWebUI.port)"
    }

    private func updateAdminWebCertificateRenewalTask() {
        let configuration = AdminWebCertificateRenewalConfiguration(
            enabled: settings.adminWebUI.enabled
                && settings.adminWebUI.httpsEnabled
                && settings.adminWebUI.certificateMode == .automatic,
            domain: settings.adminWebUI.normalizedHostname,
            cloudflareToken: settings.adminWebUI.cloudflareAPIToken
        )

        if adminWebCertificateRenewalConfiguration == configuration, adminWebCertificateRenewalTask != nil {
            return
        }

        adminWebCertificateRenewalTask?.cancel()
        adminWebCertificateRenewalTask = nil
        adminWebCertificateRenewalConfiguration = configuration

        guard configuration.enabled, !configuration.domain.isEmpty else {
            return
        }

        adminWebCertificateRenewalTask = Task { [weak self] in
            guard let self else { return }
            await self.runAdminWebCertificateRenewalLoop(configuration)
        }
    }

    private func runAdminWebCertificateRenewalLoop(_ configuration: AdminWebCertificateRenewalConfiguration) async {
        while !Task.isCancelled {
            do {
                let logStore = logs
                let certificate = try await certificateManager.ensureCertificate(
                    for: configuration.domain,
                    cloudflareAPIToken: configuration.cloudflareToken
                ) { message in
                    logStore.append(message)
                }

                if certificate.wasRenewed {
                    let runtimeState = await adminWebServer.restartListener()
                    await MainActor.run {
                        self.adminWebResolvedBaseURL = runtimeState.publicBaseURL
                        self.logs.append("♻️ Reloaded Admin Web UI TLS listener with the renewed certificate.")
                    }
                }
            } catch {
                await MainActor.run {
                    self.logs.append("⚠️ Admin Web UI certificate renewal check failed: \(error.localizedDescription)")
                }
            }

            do {
                try await Task.sleep(nanoseconds: 12 * 60 * 60 * 1_000_000_000)
            } catch {
                break
            }
        }
    }

    func stopBot() async {
        stopMediaMonitor()
        await service.disconnect()
        await cluster.stopAll()
        meshSyncTask?.cancel()
        meshSyncTask = nil
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = nil
        uptimeTask?.cancel()
        uptime = nil
        await clearVoicePresence()
        userAvatarHashById.removeAll()
        guildAvatarHashByMemberKey.removeAll()
        lastGatewayEventName = "-"
        lastVoiceStateAt = nil
        lastVoiceStateSummary = "-"
        botUserId = nil
        botUsername = "OnlineBot"
        botDiscriminator = nil
        botAvatarHash = nil
        clusterNodes = []
        lastGoodClusterNodes = []
        lastClusterStatusSuccessAt = nil
        clusterSnapshot = await cluster.currentSnapshot()
        await pluginManager.removeAll()
        status = .stopped
        logs.append("Bot stopped (SwiftMesh listener stopped)")
    }

    func refreshClusterStatus() {
        print("[DEBUG] AppModel.refreshClusterStatus() called")
        Task {
            print("[DEBUG] AppModel.refreshClusterStatus() Task started")
            await pollClusterStatus()
            let snapshot = await cluster.currentSnapshot()
            await MainActor.run {
                print("[DEBUG] AppModel.refreshClusterStatus() UI update")
                self.clusterSnapshot = snapshot
                self.lastClusterStatusRefreshAt = Date()
                self.logSwiftMeshStatus(snapshot, context: "Refresh")
            }
        }
    }

    func testWorkerLeaderConnection(leaderAddress: String? = nil, leaderPort: Int? = nil) {
        let address = leaderAddress ?? settings.clusterLeaderAddress
        let port = leaderPort ?? settings.clusterLeaderPort

        print("[DEBUG] AppModel.testWorkerLeaderConnection() called with address=\(address), port=\(port)")
        Task {
            print("[DEBUG] AppModel.testWorkerLeaderConnection() Task started")
            await MainActor.run {
                self.workerConnectionTestInProgress = true
                self.workerConnectionTestIsSuccess = false
                self.workerConnectionTestStatus = "Testing connection..."
                self.workerConnectionTestOutcome = nil
            }

            let outcome = await performWorkerConnectionTest(
                leaderAddress: address,
                leaderPort: port
            )
            print("[DEBUG] AppModel.testWorkerLeaderConnection() outcome: \(outcome.isSuccess)")

            await MainActor.run {
                self.workerConnectionTestInProgress = false
                self.workerConnectionTestIsSuccess = outcome.isSuccess
                self.workerConnectionTestStatus = outcome.message
                self.workerConnectionTestOutcome = outcome
                self.lastClusterStatusRefreshAt = Date()
                self.logs.append("SwiftMesh worker connection test: \(outcome.message)")
            }
        }
    }

    func refreshClusterStatusNow() async -> ClusterSnapshot {
        await pollClusterStatus()
        let snapshot = await cluster.currentSnapshot()
        self.clusterSnapshot = snapshot
        logSwiftMeshStatus(snapshot, context: "Refresh")
        return snapshot
    }

    func scheduleClusterNodesRefresh() {
        clusterNodesRefreshTask?.cancel()
        clusterNodesRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self else { return }
            await self.pollClusterStatus()
        }
    }

    func configureMeshSync() {
        meshSyncTask?.cancel()
        meshSyncTask = nil

        guard settings.clusterMode == .leader || settings.clusterMode == .standby else { return }

        meshSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                // Leader pushes, Standby pulls
                // Sync every 10 seconds so failover config changes propagate quickly.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }

                guard let self else { break }

                if self.settings.clusterMode == .leader {
                    // 1. Push worker registry to all nodes
                    await self.cluster.pushWorkerRegistryToStandbys()
                    // 2. Push incremental conversation batches per node
                    await self.pushIncrementalConversationsToAllNodes()
                } else if self.settings.clusterMode == .standby {
                    // 3. Standby: Pull config files and wiki cache from Primary
                    await self.pullConfigFilesFromLeader()
                    await self.pullWikiCacheFromLeader()
                }
            }
        }
    }

    // MARK: - P1b: Off-peak background mesh refresh

    /// Schedules a low-priority background activity (15 min / 5 min tolerance) that fires
    /// existing standby/worker sync paths when the system is idle (NSBackgroundActivityScheduler).
    func setupBackgroundRefreshScheduler() {
        let scheduler = NSBackgroundActivityScheduler(identifier: "com.swiftbot.meshBackgroundRefresh")
        scheduler.repeats = true
        scheduler.interval = 15 * 60        // 15 minutes
        scheduler.tolerance = 5 * 60        // 5-minute tolerance window
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            guard let self else { completion(.finished); return }
            Task {
                await self.runBackgroundMeshRefresh()
                completion(.finished)
            }
        }
        backgroundRefreshScheduler = scheduler
    }

    func runBackgroundMeshRefresh() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        await pullConfigFilesFromLeader()
        await requestResyncFromLeader(fromRecordID: localLastMergedRecordID)
    }

    /// Leader: push incremental conversation batches to each registered node using per-node cursors.
    func pushIncrementalConversationsToAllNodes() async {
        let nodes = await cluster.registeredNodeInfo()
        guard !nodes.isEmpty else { return }
        let currentTerm = await cluster.currentLeaderTerm()
        for (nodeName, baseURL) in nodes {
            let cursor = await cluster.currentReplicationCursor(for: nodeName)
            let fromID = cursor?.lastSentRecordID ?? ""
            let (records, hasMore) = await conversationStore.recordsSince(fromRecordID: fromID, limit: 500)
            let lastID = records.last?.id
            let payload = MeshSyncPayload(
                conversations: records,
                commandLog: Array(commandLog.prefix(200)),
                voiceLog: Array(voiceLog.prefix(200)),
                activeVoice: activeVoice,
                leaderTerm: currentTerm,
                cursorRecordID: lastID,
                hasMore: hasMore,
                fromCursorRecordID: fromID
            )
            let ok = await cluster.pushConversationsToSingleNode(baseURL, payload)
            if ok, lastID != nil {
                await cluster.updateReplicationCursor(for: nodeName, lastSentRecordID: lastID, term: currentTerm)
            }
        }
    }

    func pullWikiCacheFromLeader() async {
        guard let data = await cluster.fetchWikiCache() else { return }
        if let entries = try? JSONDecoder().decode([WikiContextEntry].self, from: data) {
            for entry in entries {
                await wikiContextCache.upsertEntry(entry)
            }
            logs.append("SwiftMesh: pulled \(entries.count) wiki entry(s) from Primary")
        }
    }

    func pullConfigFilesFromLeader() async {
        guard settings.clusterMode == .standby || settings.clusterMode == .worker else { return }
        guard let data = await cluster.fetchConfigFiles() else { return }
        let imported = await store.importMeshSyncedFiles(
            data,
            excludingFileNames: Set([
                SwiftBotStorage.swiftMeshConfigFileName,
                SwiftBotStorage.clusterStateFileName
            ])
        )
        guard imported > 0 else { return }

        logs.append("SwiftMesh: pulled \(imported) config file(s) from Primary")
        await reloadSyncedConfigFromDisk()
    }

    func reloadSyncedConfigFromDisk() async {
        // Keep local mesh identity authoritative on this node.
        let currentLocalMesh = settings.swiftMeshSettings
        let currentLocalMedia = mediaLibrarySettings
        let currentLocalAdminWebUI = settings.adminWebUI
        let currentLocalRemoteAccessToken = settings.remoteAccessToken
        var reloaded = await store.load()
        let meshFromFile = await swiftMeshConfigStore.load()
        let effectiveLocalMesh = meshFromFile ?? currentLocalMesh
        reloaded.swiftMeshSettings = effectiveLocalMesh
        if meshFromFile == nil {
            // Self-heal missing mesh file so future reloads remain stable.
            try? await swiftMeshConfigStore.save(effectiveLocalMesh)
        }
        if effectiveLocalMesh.mode == .standby || effectiveLocalMesh.mode == .worker {
            reloaded.adminWebUI = currentLocalAdminWebUI
            reloaded.remoteAccessToken = currentLocalRemoteAccessToken
        }
        reloaded.wikiBot.normalizeSources()
        settings = reloaded
        mediaLibrarySettings = currentLocalMedia
        await mediaLibraryIndexer.invalidate()
        await ruleStore.reloadFromDisk()
        await aiService.configureLocalAIDMReplies(
            enabled: settings.localAIDMReplyEnabled,
            provider: settings.localAIProvider,
            preferredProvider: settings.preferredAIProvider,
            endpoint: localAIEndpointForService(),
            model: settings.localAIModel,
            openAIAPIKey: effectiveOpenAIAPIKey(),
            openAIModel: settings.openAIModel,
            systemPrompt: settings.localAISystemPrompt
        )
        configurePatchyMonitoring()
        await configureAdminWebServer()
        await refreshAIStatus()
    }

    func applyClusterSettingsRuntime(mode: ClusterMode, nodeName: String, leaderAddress: String, leaderPort: Int, listenPort: Int, sharedSecret: String) async {
        // Phase 5 Safety Guard: Prevent invalid mesh ports from being used.
        guard listenPort > 0 && listenPort <= 65535 else {
            logs.append("❌ [SwiftMesh] Invalid port '\(listenPort)' — aborting mesh connection.")
            return
        }

        await cluster.applySettings(
            mode: mode,
            nodeName: nodeName,
            leaderAddress: leaderAddress,
            leaderPort: leaderPort,
            listenPort: listenPort,
            sharedSecret: sharedSecret,
            leaderTerm: settings.clusterLeaderTerm
        )

        // Phase 4: Configuration Consistency - log final mesh endpoint
        if mode != .standalone {
            let host = ProcessInfo.processInfo.hostName
            logs.append("SwiftMesh listening on \(host):\(listenPort)")
        }

        await cluster.setOffloadPolicy(
            aiReplies: settings.clusterOffloadAIReplies,
            wikiLookups: settings.clusterOffloadWikiLookups
        )
        // Sync secondary safety guard: only Primary nodes may send Discord output.
        let isPrimary = mode == .standalone || mode == .leader
        await service.setOutputAllowed(isPrimary)
        configureMeshSync()
        if mode == .standby {
            await pullConfigFilesFromLeader()
        }
        await pollClusterStatus()
    }

    func pollClusterStatus() async {
        guard settings.clusterMode != .standalone else {
            clusterNodes = []
            await refreshRegisteredWorkersDebugInfo()
            return
        }

        let emptyBody = Data()
        let localStatusHeaders = await meshStatusAuthHeaders(path: "/cluster/status", method: "GET", body: emptyBody)
        let localURL = URL(string: "http://127.0.0.1:\(settings.clusterListenPort)/cluster/status")

        if settings.clusterMode == .standby,
           let remoteNodes = await fetchRemoteLeaderNodesIfAvailable() {
            await applyClusterNodes(remoteNodes)
            return
        }

        if let localURL,
           let response = await clusterStatusService.fetchStatus(from: localURL, headers: localStatusHeaders) {
            let resolvedNodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
            await applyClusterNodes(resolvedNodes)
            return
        }

        if (settings.clusterMode == .worker || settings.clusterMode == .standby),
           let remoteNodes = await fetchRemoteLeaderNodesIfAvailable() {
            await applyClusterNodes(remoteNodes)
            return
        }

        let graceWindow: TimeInterval = 12
        if let lastSuccess = lastClusterStatusSuccessAt,
           Date().timeIntervalSince(lastSuccess) <= graceWindow,
           !lastGoodClusterNodes.isEmpty {
            clusterNodes = lastGoodClusterNodes
        } else {
            clusterNodes = fallbackClusterNodes()
        }
        await refreshRegisteredWorkersDebugInfo()
    }

    private func applyClusterNodes(_ nodes: [ClusterNodeStatus]) async {
        clusterNodes = nodes
        lastGoodClusterNodes = nodes
        lastClusterStatusSuccessAt = Date()
        await refreshRegisteredWorkersDebugInfo()
    }

    private func refreshRegisteredWorkersDebugInfo() async {
        let info = await cluster.registeredWorkersDebugInfo()
        registeredWorkersDebugCount = info.count
        registeredWorkersDebugSummary = info.summary
    }

    private func fetchRemoteLeaderNodesIfAvailable() async -> [ClusterNodeStatus]? {
        guard let baseURL = normalizedSwiftMeshBaseURL(from: settings.clusterLeaderAddress, defaultPort: settings.clusterLeaderPort),
              let statusURL = URL(string: baseURL.absoluteString + "/cluster/status"),
              let host = baseURL.host else {
            return nil
        }

        let emptyBody = Data()
        let statusHeaders = await meshStatusAuthHeaders(path: "/cluster/status", method: "GET", body: emptyBody)
        if let response = await clusterStatusService.fetchStatus(from: statusURL, headers: statusHeaders) {
            let nodes = response.nodes.isEmpty ? fallbackClusterNodes() : response.nodes
            if settings.clusterMode == .standby {
                return ensureLocalStandbyNodePresent(in: nodes)
            }
            return nodes
        }

        guard let pingURL = URL(string: baseURL.absoluteString + "/cluster/ping") else {
            return nil
        }
        let pingHeaders = await meshStatusAuthHeaders(path: "/cluster/ping", method: "GET", body: emptyBody)
        guard let ping = await clusterStatusService.fetchPing(from: pingURL, headers: pingHeaders),
              ping.response.status.caseInsensitiveCompare("ok") == .orderedSame,
              ping.response.role.caseInsensitiveCompare("leader") == .orderedSame else {
            return nil
        }

        var nodes = fallbackClusterNodes()
        if let leaderIndex = nodes.firstIndex(where: { $0.role == .leader }) {
            nodes[leaderIndex].status = .healthy
            nodes[leaderIndex].latencyMs = ping.latencyMs
            nodes[leaderIndex].displayName = ping.response.node
            nodes[leaderIndex].hostname = host
            return nodes
        }

        nodes.append(
            ClusterNodeStatus(
                id: "leader-\(host.lowercased())",
                hostname: host,
                displayName: ping.response.node,
                role: .leader,
                hardwareModel: "Unknown",
                cpu: 0,
                mem: 0,
                cpuName: "Unknown CPU",
                physicalMemoryBytes: 0,
                uptime: 0,
                latencyMs: ping.latencyMs,
                status: .healthy,
                jobsActive: 0
            )
        )
        if settings.clusterMode == .standby {
            return ensureLocalStandbyNodePresent(in: nodes)
        }
        return nodes
    }

    private func ensureLocalStandbyNodePresent(in nodes: [ClusterNodeStatus]) -> [ClusterNodeStatus] {
        guard settings.clusterMode == .standby else { return nodes }
        guard let localWorker = fallbackClusterNodes().first(where: { $0.role == .worker }) else {
            return nodes
        }

        let hasLocal = nodes.contains { node in
            guard node.role == .worker else { return false }
            if node.displayName.caseInsensitiveCompare(localWorker.displayName) == .orderedSame {
                return true
            }
            return node.hostname.caseInsensitiveCompare(localWorker.hostname) == .orderedSame
        }
        guard !hasLocal else { return nodes }

        var merged = nodes
        merged.append(localWorker)
        return merged
    }

    private func meshStatusAuthHeaders(path: String, method: String, body: Data) async -> [String: String] {
        let secret = settings.clusterSharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return [:] }

        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = await cluster.meshSignature(
            method: method,
            nonce: nonce,
            timestamp: timestamp,
            path: path,
            body: body
        )
        return [
            "X-Mesh-Nonce": nonce,
            "X-Mesh-Timestamp": String(timestamp),
            "X-Mesh-Signature": signature
        ]
    }

    func fallbackClusterNodes() -> [ClusterNodeStatus] {
        let localNodeName = settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : settings.clusterNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole = settings.clusterMode == .leader ? .leader : .worker
        let uptime = max(0, Date().timeIntervalSince(launchedAt))
        let hardwareInfo = HardwareInfo.current()
        var nodes: [ClusterNodeStatus] = [
            ClusterNodeStatus(
                id: "\(role.rawValue)-\(hostname.lowercased())-\(settings.clusterListenPort)",
                hostname: hostname,
                displayName: localNodeName,
                role: role,
                hardwareModel: hardwareInfo.modelIdentifier,
                cpu: 0,
                mem: 0,
                cpuName: hardwareInfo.cpuName,
                physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
                uptime: uptime,
                latencyMs: nil,
                status: clusterSnapshot.serverState.nodeHealthStatus,
                jobsActive: 0
            )
        ]

        if (settings.clusterMode == .worker || settings.clusterMode == .standby),
           !settings.clusterLeaderAddress.isEmpty {
            let host = URL(string: settings.clusterLeaderAddress)?.host ?? "Primary"
            nodes.append(
                ClusterNodeStatus(
                    id: "leader-\(host.lowercased())",
                    hostname: host,
                    displayName: host,
                    role: .leader,
                    hardwareModel: "Unknown",
                    cpu: 0,
                    mem: 0,
                    cpuName: "Unknown CPU",
                    physicalMemoryBytes: 0,
                    uptime: 0,
                    latencyMs: nil,
                    status: .disconnected,
                    jobsActive: 0
                )
            )
        }

        return nodes
    }

    var isWorkerServiceRunning: Bool {
        guard settings.clusterMode == .worker else { return false }
        switch clusterSnapshot.serverState {
        case .starting, .listening, .connected:
            return true
        default:
            return false
        }
    }

    var primaryServiceStatusText: String {
        settings.clusterMode == .worker
            ? (isWorkerServiceRunning ? "Worker Online" : "Worker Offline")
            : (status == .running ? "Online" : "Offline")
    }

    var primaryServiceIsOnline: Bool {
        settings.clusterMode == .worker ? isWorkerServiceRunning : status == .running
    }

    var isFailoverManagedNode: Bool {
        settings.clusterMode == .worker || settings.clusterMode == .standby
    }

    var shouldProcessPrimaryGatewayActions: Bool {
        settings.clusterMode == .standalone || settings.clusterMode == .leader
    }

    func configureServiceCallbacks() async {
        if serviceCallbacksConfigured { return }

        await service.setOnConnectionState { [weak self] state in
            await MainActor.run {
                self?.status = state
                self?.logs.append("Connection state: \(state.rawValue)")
            }
        }

        await service.setOnPayload { [weak self] payload in
            await self?.handlePayload(payload)
        }

        await service.setOnHeartbeatLatency { [weak self] latencyMs in
            await MainActor.run {
                self?.connectionDiagnostics.heartbeatLatencyMs = latencyMs
            }
        }

        await service.setOnGatewayClose { [weak self] code in
            await MainActor.run {
                self?.connectionDiagnostics.lastGatewayCloseCode = code
            }
        }

        serviceCallbacksConfigured = true
    }

    func startUptimeTicker() {
        uptimeTask?.cancel()
        uptimeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self = self else { return }
                await MainActor.run {
                    if let startedAt = self.uptime?.startedAt {
                        self.uptime = UptimeInfo(startedAt: startedAt)
                    }
                }
            }
        }
    }

    func addEvent(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events.removeLast(events.count - 20) }
    }

    // MARK: - P0.5: Member join welcome

    func handleMemberJoin(_ event: GatewayMemberJoinEvent) async {
        // Legacy settings path still active for backward compatibility.
        // New config: use a "Member Joined" trigger rule in Actions instead.
        let legacyEnabled = settings.behavior.memberJoinWelcomeEnabled &&
            !settings.behavior.memberJoinWelcomeChannelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRules = ruleStore.rules.contains { $0.isEnabled && $0.trigger == .memberJoined }
        guard legacyEnabled || hasRules else { return }

        let now = Date()
        let guildId = event.guildID
        let userId = event.userID

        // Increment member count for this guild (best-effort; sourced from GUILD_CREATE).
        let memberCount = (guildMemberCounts[guildId] ?? 0) + 1
        guildMemberCounts[guildId] = memberCount

        // Burst-guard: track join timestamps per guild; cap array to 50 entries.
        var timestamps = guildJoinTimestamps[guildId] ?? []
        timestamps = timestamps.filter { now.timeIntervalSince($0) < 5 }
        timestamps.append(now)
        if timestamps.count > 50 { timestamps = Array(timestamps.suffix(50)) }
        guildJoinTimestamps[guildId] = timestamps

        let burstThreshold = 10
        if timestamps.count > burstThreshold {
            // Raid-safe: summarize instead of individual welcome.
            if timestamps.count == burstThreshold + 1 {
                // Post once at the threshold crossing, not on every subsequent join.
                let channelId = settings.behavior.memberJoinWelcomeChannelId
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let serverName = connectedServers[guildId] ?? "the server"
                _ = await send(channelId, "👥 Multiple members joined \(serverName) — welcome everyone!")
                logs.append("Member join burst detected in \(guildId); switched to summary mode.")
            }
            return
        }

        // Dedupe: skip if same user joined this guild within 10 seconds.
        let dedupeKey = "\(guildId):\(userId)"
        if let last = recentMemberJoins[dedupeKey], now.timeIntervalSince(last) < 10 { return }
        recentMemberJoins[dedupeKey] = now
        // Bounded cleanup: cap at 500 entries, remove entries older than 60s.
        if recentMemberJoins.count > 500 {
            let pruned = recentMemberJoins.filter { now.timeIntervalSince($0.value) < 60 }
            recentMemberJoins = Dictionary(uniqueKeysWithValues: Array(pruned.prefix(500)))
        }

        // Template sanitization: neutralize @everyone and @here to prevent mass-ping abuse.
        let safeUsername = event.rawUsername
            .replacingOccurrences(of: "@everyone", with: "@​everyone")
            .replacingOccurrences(of: "@here", with: "@​here")

        let serverName = connectedServers[guildId] ?? "the server"
        let message = settings.behavior.memberJoinWelcomeTemplate
            .replacingOccurrences(of: "{username}", with: safeUsername)
            .replacingOccurrences(of: "{server}", with: serverName)
            .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")

        if legacyEnabled {
            let channelId = settings.behavior.memberJoinWelcomeChannelId
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = await send(channelId, message)
        }

        // Rule-based execution: evaluate any enabled "Member Joined" trigger rules.
        let ruleEvent = VoiceRuleEvent(
            kind: .memberJoin,
            guildId: guildId,
            userId: userId,
            username: safeUsername,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: guildId,
            triggerUserId: userId,
            isDirectMessage: false,
            authorIsBot: nil,
            joinedAt: event.joinedAt
        )
        let matchedRules = ruleEngine.evaluateRules(event: ruleEvent)
        for rule in matchedRules {
            _ = PipelineContext()
            for action in rule.processedActions where action.type == .sendMessage {
                let ruleMessage = action.message
                    .replacingOccurrences(of: "{username}", with: safeUsername)
                    .replacingOccurrences(of: "{server}", with: serverName)
                    .replacingOccurrences(of: "{memberCount}", with: "\(memberCount)")
                    .replacingOccurrences(of: "{userId}", with: userId)
                let targetChannel = action.channelId.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                guard !targetChannel.isEmpty else { continue }
                _ = await send(targetChannel, ruleMessage)
            }
        }

        // Log username only — no internal IDs or metadata.
        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "👋 \(safeUsername) joined \(serverName)"))
        logs.append("Member join welcome sent for \(safeUsername) in \(serverName)")
    }

    func handleMemberLeave(_ event: GatewayMemberLeaveEvent) async {
        let now = Date()
        let guildId = event.guildID
        let userId = event.userID
        
        // Best-effort member count decrement
        if let count = guildMemberCounts[guildId] {
            guildMemberCounts[guildId] = max(0, count - 1)
        }

        let username = event.username

        let ruleEvent = VoiceRuleEvent(
            kind: .memberLeave,
            guildId: guildId,
            userId: userId,
            username: username,
            channelId: "",
            fromChannelId: nil,
            toChannelId: nil,
            durationSeconds: nil,
            messageContent: nil,
            messageId: nil,
            mediaFileName: nil,
            mediaRelativePath: nil,
            mediaSourceName: nil,
            mediaNodeName: nil,
            triggerMessageId: nil,
            triggerChannelId: nil,
            triggerGuildId: guildId,
            triggerUserId: userId,
            isDirectMessage: false,
            authorIsBot: nil,
            joinedAt: nil
        )

        let matchedRules = ruleEngine.evaluateRules(event: ruleEvent)
        for rule in matchedRules {
            _ = await service.executeRulePipeline(actions: rule.processedActions, for: ruleEvent, isDirectMessage: ruleEvent.isDirectMessage)
        }

        addEvent(ActivityEvent(timestamp: now, kind: .info, message: "🚪 \(username) left the server"))
        logs.append("Member leave handled for \(username)")
    }

    func handleGuildCreate(_ event: GatewayGuildCreateEvent) async {
        guildCreateEventCount += 1
        if let memberCount = event.memberCount {
            guildMemberCounts[event.guildID] = memberCount
        }

        await discordCache.upsertGuild(id: event.guildID, name: event.guildName)
        await discordCache.setGuildVoiceChannels(guildID: event.guildID, channels: parseVoiceChannels(from: event.rawMap))
        await discordCache.setGuildTextChannels(guildID: event.guildID, channels: parseTextChannels(from: event.rawMap))
        await discordCache.setGuildRoles(guildID: event.guildID, roles: parseRoles(from: event.rawMap))
        await discordCache.mergeChannelTypes(parseChannelTypes(from: event.rawMap))
        await cacheGuildMembers(from: event.rawMap)
        await syncPublishedDiscordCacheFromService()
        await syncVoicePresenceFromGuildSnapshot(guildId: event.guildID, guildMap: event.rawMap)
        scheduleDiscordCacheSave()
        await registerSlashCommandsIfNeeded()
    }

    func handleChannelCreate(_ event: GatewayChannelCreateEvent) async {
        await discordCache.setChannelType(channelID: event.channelID, type: event.type)
        await discordCache.upsertChannel(
            guildID: event.guildID,
            channelID: event.channelID,
            name: event.name,
            type: event.type
        )
        await syncPublishedDiscordCacheFromService()
        scheduleDiscordCacheSave()
    }

    func handleGuildDelete(_ event: GatewayGuildDeleteEvent) async {
        await discordCache.removeGuild(id: event.guildID)
        await syncPublishedDiscordCacheFromService()
        await clearVoicePresence(guildID: event.guildID)
        scheduleDiscordCacheSave()
    }

    func patchyErrorDiagnostic(from error: Error) -> String {
        let ns = error as NSError
        let statusCode = ns.userInfo["statusCode"] as? Int ?? ns.code
        let body = (ns.userInfo["responseBody"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Try to parse Discord's specific error code from the JSON body
        var discordCode: Int? = nil
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let code = json["code"] as? Int {
            discordCode = code
        }

        // Map to HIG-aligned, actionable messages
        switch (statusCode, discordCode) {
        case (403, 50001?):
            return "SwiftBot cannot view this channel. Check permissions in the Discord server."
        case (403, 50013?):
            return "SwiftBot lacks 'Embed Links' or 'Mention' permissions in this channel."
        case (404, 10003?):
            return "Channel not found. It may have been deleted — please remove or update this target."
        case (401, _):
            return "Invalid Bot Token. Please check your token in General Settings."
        case (429, _):
            return "Sending too fast. Discord is temporarily limiting requests."
        default:
            if !body.isEmpty && body != "-" {
                let trimmedBody = body.count > 120 ? String(body.prefix(117)) + "..." : body
                return "Failed to send (HTTP \(statusCode)). Details: \(trimmedBody)"
            }
            return "Failed to send (HTTP \(statusCode)). Check Patchy logs for details."
        }
    }

    func syncVoicePresenceFromGuildSnapshot(guildId: String, guildMap: [String: DiscordJSON]) async {
        guard case let .array(voiceStates)? = guildMap["voice_states"] else { return }

        let now = Date()
        var snapshot: [VoiceMemberPresence] = []
        for state in voiceStates {
            guard case let .object(stateMap) = state,
                  case let .string(userId)? = stateMap["user_id"],
                  case let .string(channelId)? = stateMap["channel_id"]
            else { continue }

            if case let .object(member)? = stateMap["member"],
               case let .object(user)? = member["user"],
               case let .string(avatarHash)? = user["avatar"],
               !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
                if case let .string(guildAvatarHash)? = member["avatar"], !guildAvatarHash.isEmpty {
                    cacheGuildAvatar(guildAvatarHash, for: "\(guildId)-\(userId)")
                }
            } else if case let .object(user)? = stateMap["user"],
                      case let .string(avatarHash)? = user["avatar"],
                      !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
            }

            let username = await voiceDisplayName(from: stateMap, userId: userId)
            let key = "\(guildId)-\(userId)"
            let joinedAt = now

            snapshot.append(
                VoiceMemberPresence(
                    id: key,
                    userId: userId,
                    username: username,
                    guildId: guildId,
                    channelId: channelId,
                    channelName: channelDisplayName(guildId: guildId, channelId: channelId),
                    joinedAt: joinedAt
                )
            )
        }

        activeVoice = await voicePresenceStore.syncGuildSnapshot(guildId, members: snapshot)
    }

    func cacheGuildMembers(from guildMap: [String: DiscordJSON]) async {
        guard case let .array(members)? = guildMap["members"] else { return }

        for member in members {
            guard case let .object(memberMap) = member else { continue }
            if case let .string(nick)? = memberMap["nick"], !nick.isEmpty,
               case let .object(user)? = memberMap["user"],
               case let .string(userId)? = user["id"] {
                await discordCache.upsertUser(id: userId, preferredName: nick)
                continue
            }

            guard case let .object(user)? = memberMap["user"],
                  case let .string(userId)? = user["id"] else { continue }

            if case let .string(avatarHash)? = user["avatar"], !avatarHash.isEmpty {
                cacheUserAvatar(avatarHash, for: userId)
            }

            if case let .string(globalName)? = user["global_name"], !globalName.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: globalName)
            } else if case let .string(username)? = user["username"], !username.isEmpty {
                await discordCache.upsertUser(id: userId, preferredName: username)
            }
        }
    }

    func syncPublishedDiscordCacheFromService() async {
        let snapshot = await discordCache.currentSnapshot()
        connectedServers = snapshot.connectedServers
        availableVoiceChannelsByServer = snapshot.availableVoiceChannelsByServer
        availableTextChannelsByServer = snapshot.availableTextChannelsByServer
        availableRolesByServer = snapshot.availableRolesByServer
        knownUsersById = snapshot.usernamesById
    }

    func scheduleDiscordCacheSave() {
        discordCacheSaveTask?.cancel()
        discordCacheSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self = self else { return }
            do {
                let snapshot = await self.discordCache.currentSnapshot()
                try await discordCacheStore.save(snapshot)
            } catch {
                await MainActor.run {
                    self.logs.append("❌ Failed saving Discord cache: \(error.localizedDescription)")
                }
            }
        }
    }

    func resolveSteamNameIfNeeded(for target: PatchySourceTarget) {
        guard target.source == .steam else { return }
        let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appID.isEmpty else { return }
        if let existing = settings.patchy.steamAppNames[appID], !existing.isEmpty {
            return
        }

        Task {
            if let name = await fetchSteamAppName(appID: appID) {
                await MainActor.run {
                    self.settings.patchy.steamAppNames[appID] = name
                    self.persistSettingsQuietly()
                }
            }
        }
    }

    func fetchSteamAppName(appID: String) async -> String? {
        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&l=english") else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            guard
                let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let appNode = root[appID] as? [String: Any],
                let success = appNode["success"] as? Bool, success,
                let dataNode = appNode["data"] as? [String: Any],
                let name = dataNode["name"] as? String
            else {
                return nil
            }

            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }

    func commandServerName(from map: [String: DiscordJSON]) -> String {
        guard case let .string(guildId)? = map["guild_id"] else {
            return "Direct Message"
        }
        return connectedServers[guildId] ?? "Server \(guildId.suffix(4))"
    }

    func effectivePrefix() -> String {
        let trimmed = settings.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "/" : trimmed
    }

    func formatDuration(from: Date, to: Date) -> String {
        let interval = Int(to.timeIntervalSince(from))
        let m = interval / 60
        let s = interval % 60
        return "\(m)m \(s)s"
    }
}

@MainActor
final class MemoryViewModel: ObservableObject {
    @Published private(set) var summaries: [MemorySummary] = []
    @Published private(set) var scopeDisplayNames: [MemoryScope: String] = [:]

    let store: ConversationStore
    let discordCache: DiscordCache
    var storeUpdatesTask: Task<Void, Never>?
    var cacheUpdatesTask: Task<Void, Never>?

    init(store: ConversationStore, discordCache: DiscordCache) {
        self.store = store
        self.discordCache = discordCache

        storeUpdatesTask = Task { [weak self] in
            guard let self else { return }
            await self.reloadSummaries()
            let updates = await store.updates
            for await _ in updates {
                if Task.isCancelled { break }
                await self.reloadSummaries()
            }
        }

        cacheUpdatesTask = Task { [weak self] in
            guard let self else { return }
            let updates = await discordCache.updates
            for await _ in updates {
                if Task.isCancelled { break }
                await self.refreshDisplayNames()
            }
        }
    }

    deinit {
        storeUpdatesTask?.cancel()
        cacheUpdatesTask?.cancel()
    }

    var totalMessages: Int {
        summaries.reduce(0) { $0 + $1.messageCount }
    }

    func clearAll() {
        Task { await store.clearAll() }
    }

    func clear(scope: MemoryScope) {
        Task { await store.clear(scope: scope) }
    }

    func clear(channelID: String) {
        clear(scope: .guildTextChannel(channelID))
    }

    func displayName(for summary: MemorySummary) -> String {
        if let cached = scopeDisplayNames[summary.scope], !cached.isEmpty {
            return cached
        }
        return fallbackTitle(for: summary.scope)
    }

    func reloadSummaries() async {
        summaries = await store.summaries()
        await refreshDisplayNames()
    }

    func refreshDisplayNames() async {
        let current = summaries
        var updated: [MemoryScope: String] = [:]
        for summary in current {
            updated[summary.scope] = await resolvedTitle(for: summary.scope)
        }
        scopeDisplayNames = updated
    }

    func resolvedTitle(for scope: MemoryScope) async -> String {
        switch scope.type {
        case .guildTextChannel:
            if let channelName = await discordCache.channelName(for: scope.id),
               !channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "#\(channelName)"
            }
            return fallbackTitle(for: scope)
        case .directMessageUser:
            if let userName = await discordCache.userName(for: scope.id),
               !userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "DM: \(userName)"
            }
            return fallbackTitle(for: scope)
        }
    }

    func fallbackTitle(for scope: MemoryScope) -> String {
        switch scope.type {
        case .guildTextChannel:
            return "Channel \(scope.id)"
        case .directMessageUser:
            return "DM User \(scope.id.suffix(4))"
        }
    }
}

struct WorkerConnectionTestOutcome {
    let message: String
    let isSuccess: Bool
    var latencyMs: Double? = nil
    var nodeName: String? = nil
}

enum WorkerReachabilityResult {
    case reachable
    case hostUnreachable(reason: String)
}

struct SwiftMeshPingResponse: Decodable {
    let status: String
    let role: String
    let node: String
}

actor ClusterStatusPollingService {
    let decoder = JSONDecoder()

    func fetchStatus(from endpoint: URL, headers: [String: String] = [:]) async -> ClusterStatusResponse? {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            for (header, value) in headers {
                request.setValue(value, forHTTPHeaderField: header)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try decoder.decode(ClusterStatusResponse.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchPing(from endpoint: URL, headers: [String: String] = [:]) async -> (response: SwiftMeshPingResponse, latencyMs: Double)? {
        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            for (header, value) in headers {
                request.setValue(value, forHTTPHeaderField: header)
            }

            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let latencyMs = max(0, Date().timeIntervalSince(startedAt) * 1000)

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let payload = try decoder.decode(SwiftMeshPingResponse.self, from: data)
            return (payload, latencyMs)
        } catch {
            return nil
        }
    }
}


// MARK: - Notification Names

extension Notification.Name {
    /// Posted when a remote authentication session token is received via deep link.
    static let remoteAuthSessionReceived = Notification.Name("remoteAuthSessionReceived")
}
