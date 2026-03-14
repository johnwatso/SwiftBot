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

struct AdminWebCertificateRenewalConfiguration: Equatable {
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

enum AdminWebHTTPSProvisioningError: LocalizedError {
    case tlsActivationFailed

    var errorDescription: String? {
        switch self {
        case .tlsActivationFailed:
            return "The certificate was issued, but SwiftBot could not start the Admin Web UI over HTTPS. Check the logs and TLS files, then try again."
        }
    }
}

enum AdminWebPublicAccessError: LocalizedError {
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

let genericAdminWebHTTPSSetupFailureMessage = "HTTPS setup couldn’t be completed. Verify Cloudflare access and DNS propagation, then try again."
let genericAdminWebPublicAccessFailureMessage = "Public Access couldn’t be completed. Verify the hostname, Cloudflare access, and tunnel configuration, then try again."

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
    var patchyTargetValidationCache: [String: (isValid: Bool, detail: String, validatedAt: Date)] = [:]
    @Published var bugAutoFixStatusText: String = "Idle"
    @Published var bugAutoFixConsoleText: String = ""
    @Published var adminWebResolvedBaseURL: String = ""
    @Published var adminWebPublicAccessStatus = AdminWebPublicAccessRuntimeStatus()
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
    var adminWebCertificateRenewalConfiguration: AdminWebCertificateRenewalConfiguration?
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


    // MARK: - Media (see AppModel+Media.swift)

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


    // MARK: - Bot Lifecycle (see AppModel+BotLifecycle.swift)



    // MARK: - Admin Web Server (see AppModel+AdminWeb.swift)


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
