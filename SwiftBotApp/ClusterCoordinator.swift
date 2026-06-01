import Foundation
import Network
import Darwin
import OSLog
import CryptoKit

struct HardwareInfo: Sendable, Hashable {
    let modelIdentifier: String
    let cpuName: String
    let physicalMemoryBytes: UInt64

    static func current() -> HardwareInfo {
        HardwareInfo(
            modelIdentifier: readSysctlString("hw.model") ?? "Mac",
            cpuName: readSysctlString("machdep.cpu.brand_string") ?? "Unknown CPU",
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
        )
    }

    private static func readSysctlString(_ key: String) -> String? {
        var length: Int = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 1 else {
            return nil
        }

        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &value, &length, nil, 0) == 0 else {
            return nil
        }

        let string = String(decoding: value.map { UInt8(bitPattern: $0) }.dropLast(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }
}

actor ClusterCoordinator {
    private let meshLogger = Logger(subsystem: "com.swiftbot", category: "mesh")

    typealias AIHandler = @Sendable ([Message], String?, String?, String?) async -> String?
    typealias WikiHandler = @Sendable (String, WikiSource) async -> FinalsWikiLookupResult?
    typealias PlaylistImportHandler = @Sendable (URL, Int) async -> PlaylistImportResult?
    typealias JobLogHandler = @Sendable (CommandLogEntry) async -> Void
    typealias SyncHandler = @Sendable (MeshSyncPayload) async -> Void
    typealias MeshHandler = @Sendable (String) async -> Data?
    typealias MediaLibraryProvider = @Sendable () async -> MediaLibraryPayload
    typealias MediaStreamHandler = @Sendable (String, String?) async -> BinaryHTTPResponse?
    typealias MediaClipHandler = @Sendable (MeshMediaClipRequest) async -> MediaExportJob?
    typealias MediaMultiViewHandler = @Sendable (MeshMediaMultiViewRequest) async -> MediaExportJob?
    typealias MediaFrameHandler = @Sendable (String, Double) async -> BinaryHTTPResponse?
    /// Returns (records, hasMore) for the given cursor position and batch limit.
    typealias ConversationFetcher = @Sendable (String?, Int) async -> (records: [MemoryRecord], hasMore: Bool)
    /// Phase 3: each node implements this to report its current operational
    /// state so the primary can surface follower activity in its GUI.
    typealias FollowerStateProvider = @Sendable () async -> FollowerStateSummary

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    /// Dedicated session for all mesh HTTP traffic. Kept separate from
    /// `URLSession.shared` so mesh polling does not contend with app-wide URL
    /// loads, and so we can bound resource time (the shared session defaults to
    /// a 7-day resource timeout, which lets a stalled response body outlive the
    /// per-request `timeoutInterval`). `waitsForConnectivity = false` makes
    /// requests fail fast rather than parking when a peer is unreachable.
    private let meshSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()
    private let startedAt = Date()
    private let hardwareInfo = HardwareInfo.current()
    /// Registration heartbeat interval. 30s is sufficient for a healthy standby;
    /// the old 4s interval caused excessive load on the primary and overlapping
    /// requests that contributed to CFNetwork timer races.
    private let workerRegistrationIntervalNanoseconds: UInt64 = 30_000_000_000
    private let registrationStaleAfter: TimeInterval = 90
    static let maxHTTPRequestSize = 1_024 * 1024
    private static let httpReadTimeout: TimeInterval = 5.0
    /// Hard ceiling on simultaneously-serviced inbound mesh connections. Caps
    /// resource use if a peer (or a misbehaving scanner) opens many sockets.
    private static let maxConcurrentConnections = 64
    static let maxSyncBatchSize: Int = 500

    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var leaderAddress: String = ""
    var leaderPort: Int = 38787
    var listenPort: Int = 38787
    var sharedSecret: String = ""
    var offloadAIReplies: Bool = true
    var offloadWikiLookups: Bool = true
    var offloadPlaylistImports: Bool = true
    /// Nonce replay cache: maps nonce → expiry time. Swept opportunistically on each auth check.
    private var usedNonces: [String: Date] = [:]
    private var activeJobs = 0
    private var registeredWorkers: [String: RegisteredWorker] = [:]
    /// Sticky cache of every worker we have ever seen this session. Never
    /// pruned. Used to keep previously-known nodes visible in the SwiftMesh
    /// cluster map even after they go offline, with status derived from the
    /// stored `lastSeen` timestamp.
    private var everKnownWorkers: [String: RegisteredWorker] = [:]
    private var workerRegistrationTask: Task<Void, Never>?
    /// Tracks an in-flight handover test so the button doesn't double-fire
    /// and so the auto-reclaim timer can be cancelled if mode changes.
    private var handoverTestTask: Task<Void, Never>?
    /// Sleep-until-T0 task for a *scheduled* (not yet running) handover test.
    /// Distinct from `handoverTestTask`, which is the watchdog that runs
    /// during/after the test itself.
    private var scheduledHandoverTask: Task<Void, Never>?
    /// Standby-side: the T0 we've armed for. Prevents re-arming on every
    /// snapshot tick (which would reset the timer constantly). Cleared after
    /// promotion fires or when the schedule is withdrawn.
    private var localHandoverArmedFor: Date?
    /// Latest leader node name we've heard from the current Primary in a
    /// registration ack. Lets the temp-Primary log meaningful messages when
    /// it signals reclaim — the URL is what matters for the call but the
    /// name makes the audit trail human-readable.
    private var currentLeaderNodeName: String?
    /// Captured at promotion time so the temporary-Primary Standby knows
    /// where to send the "end" signal when its window elapses. Reset on
    /// demotion.
    private var previousLeaderAddressBeforePromotion: String?
    private var previousLeaderNameBeforePromotion: String?

    // SwiftMesh failover state
    var leaderTerm: Int = 0
    private var standbyMonitorTask: Task<Void, Never>?
    var standbyHealthMisses: Int = 0
    /// Standby health probe interval. 15s balances fast failover detection with
    /// avoiding request storms on the primary.
    static let standbyHealthInterval: TimeInterval = 15.0
    static let standbyPromotionThreshold: Int = 3
    /// Phase 4: auto-reclaim by configured-primary.
    /// Whether THIS node was configured as Primary in settings (set by AppModel).
    /// Only originally-configured Primary nodes are allowed to auto-reclaim.
    private var isConfiguredPrimary: Bool = false
    /// Auto-reclaim threshold in seconds. `0` disables auto-reclaim.
    private var autoReclaimAfterSeconds: TimeInterval = 0
    /// Timestamp of the first consecutive healthy probe of the current leader
    /// while we're a runtime-demoted Primary. Reset to nil on any miss or on
    /// settings/role changes.
    private var standbyHealthySince: Date?

    // Phase 2: per-node replication cursors (keyed by nodeName, persisted on leader)
    var replicationCursors: [String: ReplicationCursor] = [:]
    private var onCursorsChanged: (@Sendable ([String: ReplicationCursor]) async -> Void)?

    // P1b: LAN peer discovery via Bonjour/mDNS
    private var meshBrowser: NWBrowser?
    var discoveredPeers: [String: DiscoveredPeer] = [:]

    private var aiHandler: AIHandler?
    private var wikiHandler: WikiHandler?
    private var playlistImportHandler: PlaylistImportHandler?
    private var conversationFetcher: ConversationFetcher?
    private var listener: NWListener?
    private var listenerActivePort: Int?
    /// Number of inbound mesh connections currently being serviced. Bounded by
    /// `maxConcurrentConnections`.
    private var activeConnectionCount = 0
    private var onSnapshot: (@Sendable (ClusterSnapshot) async -> Void)?
    private var onJobLog: JobLogHandler?
    private var onSync: SyncHandler?
    private var meshHandler: MeshHandler?
    private var mediaLibraryProvider: MediaLibraryProvider?
    private var mediaStreamHandler: MediaStreamHandler?
    private var mediaThumbnailHandler: MediaStreamHandler?
    private var mediaClipHandler: MediaClipHandler?
    private var mediaMultiViewHandler: MediaMultiViewHandler?
    private var mediaFrameHandler: MediaFrameHandler?
    private var onTermChanged: (@Sendable (Int) async -> Void)?
    private var onPromotion: (@Sendable () async -> Void)?
    private var onDemotion: (@Sendable () async -> Void)?
    /// Fires when the original Primary successfully reclaims at the end of a
    /// Handover Test. Used by AppModel to persist a "last passed" timestamp.
    private var onHandoverTestPassed: (@Sendable () async -> Void)?
    /// Optional secondary probe that returns whether the Primary is publicly
    /// reachable via its Cloudflare-tunneled URL (`/live` HTTPS check). Used
    /// as a second opinion before promoting on direct-mesh failure — many
    /// real outages take down the whole Primary, so /live will also fail. If
    /// /live still reports the Primary online, the mesh failure is more
    /// likely a routing problem and we should NOT promote.
    /// Returns:
    /// - `true`  → Primary publicly reachable (abort promotion)
    /// - `false` → Primary not publicly reachable (proceed)
    /// - `nil`   → no public URL known (fall back to mesh-only behavior)
    private var onConfirmPrimaryPubliclyReachable: (@Sendable () async -> Bool?)?
    /// Fires for each meaningful step of a Handover Test on the local node
    /// (whichever role it currently plays — origin Primary or target Failover).
    /// AppModel wires this into the Activity Log so the user can watch the
    /// drill progress step-by-step under the SwiftMesh filter.
    private var onHandoverTestStep: (@Sendable (String) async -> Void)?
    /// Returns the Primary's currently-configured Discord token, if any.
    /// Used by the Primary to serve `/v1/mesh/discord-token` requests so a
    /// Standby can pull the token after registering.
    private var discordTokenProvider: (@Sendable () async -> String?)?
    /// Fires on the Standby side when a fresh Discord token has been pulled
    /// from the Primary. AppModel persists it via the Keychain-backed path.
    private var onDiscordTokenFetched: (@Sendable (String) async -> Void)?
    private var onLeaderRegistrationSyncNeeded: (@Sendable (String) async -> Void)?
    private var followerStateProvider: FollowerStateProvider?
    // Phase 3: primary stores the last polled state for each follower, keyed
    // by node baseURL. Published into ClusterSnapshot on each refresh.
    private var followerStates: [String: FollowerStateSummary] = [:]
    private var followerStatePollTask: Task<Void, Never>?
    private let followerStatePollIntervalNanoseconds: UInt64 = 4_000_000_000
    private var initialSyncCompletedLeaderBaseURL: String?
    var snapshot = ClusterSnapshot()

    func configureHandlers(
        aiHandler: @escaping AIHandler,
        wikiHandler: @escaping WikiHandler,
        playlistImportHandler: @escaping PlaylistImportHandler = { _, _ in nil },
        onSnapshot: @escaping @Sendable (ClusterSnapshot) async -> Void,
        onJobLog: @escaping JobLogHandler,
        onSync: @escaping SyncHandler,
        meshHandler: @escaping MeshHandler,
        mediaLibraryProvider: @escaping MediaLibraryProvider = {
            MediaLibraryPayload(nodeName: "", configFilePath: "", sources: [], items: [], generatedAt: Date())
        },
        mediaStreamHandler: @escaping MediaStreamHandler = { _, _ in nil },
        mediaThumbnailHandler: @escaping MediaStreamHandler = { _, _ in nil },
        mediaClipHandler: @escaping MediaClipHandler = { _ in nil },
        mediaMultiViewHandler: @escaping MediaMultiViewHandler = { _ in nil },
        mediaFrameHandler: @escaping MediaFrameHandler = { _, _ in nil },
        conversationFetcher: @escaping ConversationFetcher,
        onPromotion: @escaping @Sendable () async -> Void = {}
    ) {
        self.aiHandler = aiHandler
        self.wikiHandler = wikiHandler
        self.playlistImportHandler = playlistImportHandler
        self.onSnapshot = onSnapshot
        self.onJobLog = onJobLog
        self.onSync = onSync
        self.meshHandler = meshHandler
        self.mediaLibraryProvider = mediaLibraryProvider
        self.mediaStreamHandler = mediaStreamHandler
        self.mediaThumbnailHandler = mediaThumbnailHandler
        self.mediaClipHandler = mediaClipHandler
        self.mediaMultiViewHandler = mediaMultiViewHandler
        self.mediaFrameHandler = mediaFrameHandler
        self.conversationFetcher = conversationFetcher
        self.onPromotion = onPromotion
    }

    func setTermChangedHandler(_ handler: @escaping @Sendable (Int) async -> Void) {
        self.onTermChanged = handler
    }

    func setCursorsChangedHandler(_ handler: @escaping @Sendable ([String: ReplicationCursor]) async -> Void) {
        self.onCursorsChanged = handler
    }

    /// Invoked when a leader detects a higher-term peer and demotes itself to
    /// standby. AppModel uses this to mute Discord output and re-engage the
    /// passive-standby gating that normally happens at startup.
    func setDemotionHandler(_ handler: @escaping @Sendable () async -> Void) {
        self.onDemotion = handler
    }

    /// Wires the AppModel-side "last handover test passed" persistence.
    func setHandoverTestPassedHandler(_ handler: @escaping @Sendable () async -> Void) {
        self.onHandoverTestPassed = handler
    }

    func setConfirmPrimaryPubliclyReachableHandler(_ handler: @escaping @Sendable () async -> Bool?) {
        self.onConfirmPrimaryPubliclyReachable = handler
    }

    /// Wires a per-step observer for the Handover Test. AppModel forwards each
    /// step to the Activity Log so the SwiftMesh filter shows the full drill
    /// in real time instead of just "started" / "completed".
    func setHandoverTestStepHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        self.onHandoverTestStep = handler
    }

    /// Helper used by both the origin-Primary and Failover-target sides to
    /// emit a step event. Centralised so we can also stamp a `[step N/M]`
    /// prefix consistently and never forget to await.
    private func emitHandoverStep(_ stage: Int, of total: Int, _ message: String) async {
        let line = "step \(stage)/\(total) — \(message)"
        await onHandoverTestStep?(line)
    }

    /// Wires the Primary-side Discord-token provider.
    func setDiscordTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        self.discordTokenProvider = provider
    }

    /// Wires the Standby-side handler invoked when a pulled token arrives.
    func setDiscordTokenFetchedHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        self.onDiscordTokenFetched = handler
    }

    /// Fires once after the first successful registration with a given Primary.
    /// AppModel uses this to pull an immediate tail resync instead of waiting
    /// for the next scheduled Primary push.
    func setLeaderRegistrationSyncHandler(_ handler: @escaping @Sendable (String) async -> Void) {
        self.onLeaderRegistrationSyncNeeded = handler
    }

    /// Phase 3: AppModel provides a closure that builds the local node's
    /// follower-state summary on demand. Called by the local /v1/mesh/follower-state
    /// endpoint and used by the leader to seed its own slot in followerStates.
    func setFollowerStateProvider(_ provider: @escaping FollowerStateProvider) {
        self.followerStateProvider = provider
    }

    /// Phase 4: tells the coordinator whether THIS node was configured as the
    /// original Primary (from settings, not the runtime role) and how long
    /// it must be healthy as a standby before auto-reclaiming. `0` disables.
    func setAutoReclaimPolicy(isConfiguredPrimary: Bool, afterHours: Int) {
        self.isConfiguredPrimary = isConfiguredPrimary
        self.autoReclaimAfterSeconds = TimeInterval(max(0, afterHours)) * 3600
        // Any policy change resets the healthy clock — start clean.
        self.standbyHealthySince = nil
    }

    /// Phase 4: time remaining (seconds) until auto-reclaim, or `nil` if
    /// auto-reclaim is disabled / not eligible. Exposed for the GUI countdown.
    func autoReclaimCountdownSeconds() -> TimeInterval? {
        guard isConfiguredPrimary,
              autoReclaimAfterSeconds > 0,
              mode == .standby,
              let since = standbyHealthySince else { return nil }
        let elapsed = Date().timeIntervalSince(since)
        return max(0, autoReclaimAfterSeconds - elapsed)
    }

    /// Phase 4: user-initiated promote. Skips the death-confirmation probe
    /// because the user is explicitly asserting "take over now". Existing
    /// stale-term backstop in `detectStaleSelfFromResponse` will demote the
    /// previous primary on its next sync attempt.
    func manuallyPromote() async {
        guard mode == .standby else { return }
        meshLogger.notice("Manual promote requested by user")
        handoverTestTask?.cancel()
        handoverTestTask = nil
        scheduledHandoverTask?.cancel()
        scheduledHandoverTask = nil
        localHandoverArmedFor = nil
        snapshot.scheduledHandoverTestAt = nil
        snapshot.scheduledHandoverTargetNodeName = nil
        await promoteToLeader()
    }

    // MARK: - Handover Test (Primary ⇄ Failover round-trip)

    /// Schedules a Handover Test to start `leadTimeSeconds` from now. The
    /// scheduled time is published in the next snapshot tick so the Failover
    /// can render a heads-up banner via the regular pull-sync — no inbound
    /// callback needed, so this works across residential NAT.
    ///
    /// `leadTimeSeconds` should be ≥ the mesh-sync interval (~60s) so the
    /// Failover has at least one sync window to learn about the upcoming test.
    /// Returns a short message for the caller to log.
    func scheduleHandoverTest(leadTimeSeconds: Int = 90, durationSeconds: Int = 60) async -> String {
        guard mode == .leader else { return "Handover test requires this node to be Primary." }
        let workers = sortedRegisteredWorkers()
        guard let target = workers.first else {
            return "Handover test needs at least one registered Failover."
        }
        guard handoverTestTask == nil, scheduledHandoverTask == nil else {
            return "Handover test already in progress or scheduled."
        }
        // Pre-flight: the chosen Failover must have checked in recently enough
        // that we can trust it'll receive the snapshot announcing the test.
        // With the regular 60s sync cadence + ~30s worker re-registration, a
        // freshness window of 90s catches "has paged out / disconnected"
        // without being so tight that a single slow tick aborts the test.
        let staleSeconds = Date().timeIntervalSince(target.lastSeen)
        let freshnessLimit: TimeInterval = 90
        if staleSeconds > freshnessLimit {
            return "Handover test aborted: \(target.nodeName) hasn't reported in \(Int(staleSeconds))s (>\(Int(freshnessLimit))s). The Failover may have disconnected — fix the link before retrying."
        }

        let startAt = Date().addingTimeInterval(TimeInterval(leadTimeSeconds))
        let endsAt = startAt.addingTimeInterval(TimeInterval(durationSeconds))
        snapshot.scheduledHandoverTestAt = startAt
        // Publish ends-at at scheduling time too so the named Standby derives
        // the exact duration from the snapshot rather than guessing.
        snapshot.handoverTestEndsAt = endsAt
        snapshot.scheduledHandoverTargetNodeName = target.nodeName
        snapshot.diagnostics = "Handover test scheduled for \(formattedTimeOfDay(startAt)) (target: \(target.nodeName))"
        await publishSnapshot()
        await emitHandoverStep(0, of: 5, "Handover test scheduled for \(formattedTimeOfDay(startAt)) — \(target.nodeName) will promote autonomously at T0 from mesh sync")
        meshLogger.notice("Handover test scheduled for \(startAt, privacy: .public) with target \(target.nodeName, privacy: .public)")

        let durSeconds = durationSeconds
        scheduledHandoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(leadTimeSeconds) * 1_000_000_000)
            guard let self else { return }
            await self.handleScheduledHandoverFiring(durationSeconds: durSeconds, targetName: target.nodeName)
        }

        return "Handover test scheduled for \(formattedTimeOfDay(startAt)). \(target.nodeName) will promote autonomously at T0."
    }

    /// Cancels any scheduled (not yet started) handover test.
    func cancelScheduledHandoverTest() async {
        scheduledHandoverTask?.cancel()
        scheduledHandoverTask = nil
        localHandoverArmedFor = nil
        // If we're a Standby with an armed local trigger, cancel that too.
        if mode == .standby, handoverTestTask != nil, !snapshot.isHandoverTestActive {
            handoverTestTask?.cancel()
            handoverTestTask = nil
        }
        if snapshot.scheduledHandoverTestAt != nil || snapshot.scheduledHandoverTargetNodeName != nil {
            snapshot.scheduledHandoverTestAt = nil
            snapshot.scheduledHandoverTargetNodeName = nil
            await publishSnapshot()
            meshLogger.notice("Scheduled handover test cancelled")
        }
    }

    private func handleScheduledHandoverFiring(durationSeconds: Int, targetName: String) async {
        guard !Task.isCancelled else { return }
        scheduledHandoverTask = nil
        snapshot.scheduledHandoverTestAt = nil
        snapshot.scheduledHandoverTargetNodeName = nil
        await publishSnapshot()
        _ = await beginTimeBasedHandoverTest(durationSeconds: durationSeconds, targetName: targetName)
    }

    /// Time-based handover test trigger. Both sides act on their local clock
    /// at T0 — no Primary→Standby HTTP callback. The chosen Standby has
    /// already armed its own promotion task via `armLocalHandoverPromotion`
    /// when the snapshot reached it.
    private func beginTimeBasedHandoverTest(durationSeconds: Int, targetName: String) async -> String {
        guard mode == .leader else { return "Handover test requires this node to be Primary." }
        guard handoverTestTask == nil else { return "Handover test already in progress." }

        // T0 readiness check: never demote without confirming the chosen
        // Standby has registered recently enough that we can trust it'll act
        // on its locally-armed promotion. If it's gone quiet between
        // scheduling and T0, abort cleanly — staying Primary is always safer
        // than a leaderless cluster.
        let target = registeredWorkers.values.first(where: { $0.nodeName == targetName })
        if let target {
            let staleSeconds = Date().timeIntervalSince(target.lastSeen)
            if staleSeconds > 90 {
                meshLogger.warning("Handover test T0 aborted — \(targetName, privacy: .public) hasn't reported in \(staleSeconds, privacy: .public)s")
                snapshot.diagnostics = "Handover test aborted at T0 — \(targetName) has gone silent (\(Int(staleSeconds))s)"
                await publishSnapshot()
                await emitHandoverStep(0, of: 4, "T0 abort: \(targetName) hasn't reported in \(Int(staleSeconds))s — staying Primary")
                return "Handover test aborted at T0: \(targetName) appears to have disconnected."
            }
        } else {
            meshLogger.warning("Handover test T0 aborted — \(targetName, privacy: .public) is not currently registered")
            snapshot.diagnostics = "Handover test aborted at T0 — \(targetName) is no longer registered"
            await publishSnapshot()
            await emitHandoverStep(0, of: 4, "T0 abort: \(targetName) is no longer registered — staying Primary")
            return "Handover test aborted at T0: \(targetName) is no longer registered."
        }

        let graceSeconds = 15
        snapshot.isHandoverTestActive = true
        snapshot.handoverTestEndsAt = Date().addingTimeInterval(TimeInterval(durationSeconds))
        await publishSnapshot()

        // STEP 1: Demote self locally. The chosen Standby is independently
        // arming its own promotion at this same T0 from the snapshot it
        // received earlier.
        await emitHandoverStep(1, of: 4, "T0 reached: demoting self to Standby (target \(targetName) is promoting locally on its own clock)")
        // Synthesize the next-leader address from the registered worker entry
        // so split-brain detection points at the right peer.
        let targetBaseURL = registeredWorkers.values
            .first(where: { $0.nodeName == targetName })?.baseURL
            ?? sortedRegisteredWorkers().first?.baseURL
            ?? ""
        await demoteToStandby(observedTerm: leaderTerm, newLeaderAddress: targetBaseURL)
        meshLogger.notice("Handover test (time-based): demoted self; \(targetName, privacy: .public) takes over for \(durationSeconds, privacy: .public)s")

        // STEP 2: Arm watchdog — if Standby never sends the "end" signal by
        // T0 + duration + grace, reclaim Primary anyway so we don't leave
        // the cluster leaderless.
        await emitHandoverStep(2, of: 4, "Watchdog armed (\(durationSeconds + graceSeconds)s) — will force-reclaim if \(targetName) goes silent")
        handoverTestTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds + graceSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard mode == .standby else {
                snapshot.isHandoverTestActive = false
                snapshot.handoverTestEndsAt = nil
                handoverTestTask = nil
                return
            }
            meshLogger.warning("Handover test watchdog fired — \(targetName, privacy: .public) never signalled back; reclaiming Primary")
            snapshot.diagnostics = "Handover test watchdog — reclaiming Primary after timeout"
            snapshot.isHandoverTestActive = false
            snapshot.handoverTestEndsAt = nil
            await publishSnapshot()
            await emitHandoverStep(3, of: 4, "Watchdog fired — \(targetName) never signalled back; force-reclaiming Primary")
            await promoteToLeader()
            await emitHandoverStep(4, of: 4, "Reclaim complete after watchdog timeout")
            await onHandoverTestPassed?()
            handoverTestTask = nil
        }

        return "Handover test started (time-based). \(targetName) is promoting locally; auto-reclaim on completion or after \(durationSeconds + graceSeconds)s timeout."
    }

    private func formattedTimeOfDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter.string(from: date)
    }

    /// Coordinated test triggered from the Primary's SwiftMesh GUI. Steps:
    /// 1. Demote self to standby so the Failover can promote cleanly.
    /// 2. Ask the Failover to take over for `durationSeconds`.
    /// 3. Start a watchdog on this node that auto-reclaims if the Failover
    ///    never signals back (duration + 15s grace).
    /// Returns a short message for the caller to log.
    func startHandoverTest(durationSeconds: Int = 60) async -> String {
        guard mode == .leader else { return "Handover test requires this node to be Primary." }
        let workers = sortedRegisteredWorkers()
        guard let target = workers.first else {
            return "Handover test needs at least one registered worker."
        }
        guard handoverTestTask == nil else { return "Handover test already in progress." }

        let ownBaseURL = localWorkerAdvertisedBaseURL()
        let payload = MeshHandoverTestPayload(
            originPrimaryNodeName: nodeName,
            originPrimaryBaseURL: ownBaseURL,
            durationSeconds: durationSeconds,
            currentLeaderTerm: leaderTerm
        )

        // STEP 1: Demote self to standby FIRST so the Failover can promote
        // without creating a split-brain.
        await emitHandoverStep(1, of: 5, "Demoting self to Standby so \(target.nodeName) can promote without split-brain")
        await demoteToStandby(observedTerm: leaderTerm, newLeaderAddress: target.baseURL)
        meshLogger.notice("Handover test: demoted self; asking \(target.nodeName, privacy: .public) to take over for \(durationSeconds, privacy: .public)s")

        // STEP 2: Start a watchdog that reclaims if the Failover never signals back.
        let graceSeconds = 15
        snapshot.isHandoverTestActive = true
        snapshot.handoverTestEndsAt = Date().addingTimeInterval(TimeInterval(durationSeconds))
        await publishSnapshot()
        await emitHandoverStep(2, of: 5, "Watchdog armed (\(durationSeconds + graceSeconds)s) — will force-reclaim if \(target.nodeName) goes silent")
        
        handoverTestTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(durationSeconds + graceSeconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard mode == .standby else {
                snapshot.isHandoverTestActive = false
                snapshot.handoverTestEndsAt = nil
                handoverTestTask = nil
                return
            }
            meshLogger.warning("Handover test watchdog fired — Failover never signalled back; reclaiming Primary")
            snapshot.diagnostics = "Handover test watchdog — reclaiming Primary after timeout"
            snapshot.isHandoverTestActive = false
            snapshot.handoverTestEndsAt = nil
            await publishSnapshot()
            await emitHandoverStep(4, of: 5, "Watchdog fired — \(target.nodeName) never signalled back; force-reclaiming Primary")
            await promoteToLeader()
            await emitHandoverStep(5, of: 5, "Reclaim complete after watchdog timeout")
            await onHandoverTestPassed?()
            handoverTestTask = nil
        }

        guard let url = URL(string: target.baseURL + "/v1/mesh/handover-test/begin") else {
            // If the URL is bad, cancel the watchdog and reclaim immediately.
            handoverTestTask?.cancel()
            handoverTestTask = nil
            await promoteToLeader()
            return "Handover test: target URL is invalid; reclaimed immediately."
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/v1/mesh/handover-test/begin")
            request.timeoutInterval = 8
            let (_, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                await emitHandoverStep(3, of: 5, "\(target.nodeName) refused begin signal (HTTP \(code))")
                return "Handover test: Failover refused (HTTP \(code))."
            }
            await emitHandoverStep(3, of: 5, "Begin signal accepted by \(target.nodeName); awaiting reclaim signal")
            return "Handover test started. \(target.nodeName) will take over for \(durationSeconds)s; auto-reclaim on completion or after \(durationSeconds + graceSeconds)s timeout."
        } catch {
            await emitHandoverStep(3, of: 5, "Could not reach \(target.nodeName) — \(error.localizedDescription)")
            return "Handover test: could not reach \(target.nodeName) — \(error.localizedDescription)"
        }
    }

    /// Standby-side: arms a local task to self-promote at `startAt` for a
    /// fixed `durationSeconds`. Called from `AppModel.applyMeshLiveSnapshot`
    /// when this Standby is named as the target. Idempotent: re-arming with
    /// the same start time is a no-op; a different start time replaces the
    /// previous arming.
    /// Standby-side: clears a previously-armed local promotion (called when
    /// the Primary cancels the scheduled test). No-op if nothing was armed or
    /// if the test has already started.
    func disarmLocalHandoverPromotion() async {
        guard localHandoverArmedFor != nil else { return }
        localHandoverArmedFor = nil
        if !snapshot.isHandoverTestActive {
            handoverTestTask?.cancel()
            handoverTestTask = nil
            meshLogger.notice("Handover test (time-based): local promotion disarmed — Primary cancelled the schedule")
        }
    }

    func armLocalHandoverPromotion(at startAt: Date, durationSeconds: Int) async {
        guard mode == .standby else { return }
        // If we've already armed for this exact T0, don't restart the timer
        // (the snapshot will re-arrive every sync tick).
        if let existing = localHandoverArmedFor, existing == startAt { return }
        localHandoverArmedFor = startAt
        let delay = max(0, startAt.timeIntervalSinceNow)
        meshLogger.notice("Handover test (time-based): armed self-promotion in \(delay, privacy: .public)s for \(durationSeconds, privacy: .public)s")
        snapshot.diagnostics = "Handover test scheduled — will auto-promote at \(self.formattedTimeOfDay(startAt))"
        await publishSnapshot()

        handoverTestTask?.cancel()
        handoverTestTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard mode == .standby else { return }
            await self.runLocalHandoverPromotion(durationSeconds: durationSeconds)
        }
    }

    private func runLocalHandoverPromotion(durationSeconds: Int) async {
        meshLogger.notice("Handover test (time-based): T0 reached; promoting locally for \(durationSeconds, privacy: .public)s")
        snapshot.isHandoverTestActive = true
        snapshot.handoverTestEndsAt = Date().addingTimeInterval(TimeInterval(durationSeconds))
        snapshot.scheduledHandoverTestAt = nil
        snapshot.scheduledHandoverTargetNodeName = nil
        await publishSnapshot()
        await emitHandoverStep(1, of: 4, "T0 reached; promoting to temporary Primary (autonomous, no inbound signal)")
        await promoteToLeader()
        await emitHandoverStep(2, of: 4, "Promoted to temporary Primary; holding role for \(durationSeconds)s")

        try? await Task.sleep(nanoseconds: UInt64(durationSeconds) * 1_000_000_000)
        if Task.isCancelled { return }

        // Build the origin URL for the "end" signal from the cached leader
        // address we recorded at handshake — outbound from us to the Primary
        // is the direction that always works (it's how we registered in the
        // first place).
        let originBaseURL = previousLeaderAddressBeforePromotion ?? ""
        let originNodeName = previousLeaderNameBeforePromotion ?? "Primary"
        await emitHandoverStep(3, of: 4, "Test window elapsed; signalling \(originNodeName) to reclaim")
        await broadcastHandoverTestEnd(originPrimaryNodeName: originNodeName, originPrimaryBaseURL: originBaseURL, duration: durationSeconds)

        meshLogger.notice("Handover test window elapsed; demoting back to Standby")
        snapshot.isHandoverTestActive = false
        snapshot.handoverTestEndsAt = nil
        await demoteToStandby(observedTerm: leaderTerm, newLeaderAddress: originBaseURL)
        await emitHandoverStep(4, of: 4, "Demoted back to Standby")
        localHandoverArmedFor = nil
        handoverTestTask = nil
    }

    /// Failover-side handler. Schedules promotion after a brief delay (so the
    /// caller's HTTP response is sent before the role swap), then schedules
    /// the end-of-test notification after the requested duration.
    private func handleHandoverTestBegin(_ body: Data) async -> Data {
        guard let payload = try? decoder.decode(MeshHandoverTestPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }

        // Adopt newer term if provided
        if let term = payload.currentLeaderTerm {
            await updateLeaderTerm(term)
        }

        guard mode == .standby else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "standby_mode_required"))
        }
        guard handoverTestTask == nil else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "already_running"))
        }
        let duration = max(5, min(600, payload.durationSeconds))
        let origin = payload.originPrimaryNodeName
        let originBaseURL = payload.originPrimaryBaseURL
        meshLogger.notice("Handover test: signal received from \(origin, privacy: .public); promoting in 1s for \(duration, privacy: .public)s")
        snapshot.diagnostics = "Handover test starting — promoting in 1s, will reclaim \(origin) after \(duration)s"
        snapshot.isHandoverTestActive = true
        snapshot.handoverTestEndsAt = Date().addingTimeInterval(TimeInterval(duration + 1))
        await publishSnapshot()
        await emitHandoverStep(1, of: 4, "Begin signal received from \(origin); promoting to temporary Primary in 1s")

        handoverTestTask = Task {
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                meshLogger.debug("Handover test start sleep cancelled")
                snapshot.isHandoverTestActive = false
                snapshot.handoverTestEndsAt = nil
                return
            }
            await promoteToLeader()
            await emitHandoverStep(2, of: 4, "Promoted to temporary Primary; holding role for \(duration)s")
            do {
                try await Task.sleep(nanoseconds: UInt64(duration) * 1_000_000_000)
            } catch {
                meshLogger.debug("Handover test duration sleep cancelled")
                snapshot.isHandoverTestActive = false
                snapshot.handoverTestEndsAt = nil
                return
            }
            await emitHandoverStep(3, of: 4, "Test window elapsed; signalling \(origin) to reclaim")
            await broadcastHandoverTestEnd(originPrimaryNodeName: origin, originPrimaryBaseURL: originBaseURL, duration: duration)

            // Fix split-brain: temporary primary must demote self back to standby
            // now that its window has elapsed.
            meshLogger.notice("Handover test window elapsed; demoting back to Standby")
            snapshot.isHandoverTestActive = false
            snapshot.handoverTestEndsAt = nil
            await demoteToStandby(observedTerm: leaderTerm, newLeaderAddress: originBaseURL)
            await emitHandoverStep(4, of: 4, "Demoted back to Standby")

            handoverTestTask = nil
        }

        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Now-Primary-temporarily side: signals the original Primary directly
    /// that the test window has elapsed so it can reclaim.
    private func broadcastHandoverTestEnd(originPrimaryNodeName: String, originPrimaryBaseURL: String, duration: Int) async {
        guard mode == .leader else { return }
        let payload = MeshHandoverTestPayload(
            originPrimaryNodeName: originPrimaryNodeName,
            originPrimaryBaseURL: originPrimaryBaseURL,
            durationSeconds: duration,
            currentLeaderTerm: leaderTerm
        )
        guard let body = try? encoder.encode(payload) else { return }
        meshLogger.notice("Handover test: \(duration, privacy: .public)s elapsed; signalling \(originPrimaryNodeName, privacy: .public) to reclaim")
        snapshot.diagnostics = "Handover test ending; notifying \(originPrimaryNodeName) to reclaim"
        await publishSnapshot()

        guard let url = URL(string: originPrimaryBaseURL + "/v1/mesh/handover-test/end") else {
            meshLogger.error("Handover test: invalid origin primary URL \(originPrimaryBaseURL, privacy: .public)")
            return
        }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            applyMeshAuth(to: &request, path: "/v1/mesh/handover-test/end")
            request.timeoutInterval = 8
            _ = try await meshSession.data(for: request)
        } catch {
            meshLogger.warning("Handover test: failed to notify \(originPrimaryNodeName, privacy: .public) — \(error.localizedDescription)")
        }
    }

    /// Former-Primary side: original Primary is currently standby. Re-promote
    /// to reclaim. Stale-term backstop demotes the temporary Primary on its
    /// next sync push.
    private func handleHandoverTestEnd(_ body: Data) async -> Data {
        guard let payload = try? decoder.decode(MeshHandoverTestPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }

        // Adopt newer term if provided
        if let term = payload.currentLeaderTerm {
            await updateLeaderTerm(term)
        }

        guard mode == .standby else {
            // We may have already reclaimed via auto-reclaim, or never were
            // the origin Primary. Either way, no work to do.
            return httpResponse(status: "200 OK", body: Data(#"{"status":"noop"}"#.utf8))
        }
        meshLogger.notice("Handover test: end signal received; reclaiming Primary")
        snapshot.diagnostics = "Handover test complete; reclaiming Primary"
        snapshot.isHandoverTestActive = false
        snapshot.handoverTestEndsAt = nil
        await publishSnapshot()
        await emitHandoverStep(4, of: 5, "End signal received from Failover — reclaiming Primary")
        await promoteToLeader()
        await emitHandoverStep(5, of: 5, "Reclaim complete — handover test passed end-to-end")
        handoverTestTask?.cancel()
        handoverTestTask = nil
        await onHandoverTestPassed?()
        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    private func clearHandoverTestTask() {
        handoverTestTask = nil
    }

    /// Awaits the current handover test task so callers can serialize around it.
    private func awaitHandoverTestTaskIfNeeded() async {
        _ = await handoverTestTask?.value
    }

    // MARK: - Discord token auto-fetch

    /// Primary-side responder for `GET /v1/mesh/discord-token`. The route is
    /// already gated by the mesh HMAC, so any peer presenting a valid
    /// signature with the shared secret is allowed to read the token. The
    /// response sets `available=false` (rather than throwing) when the
    /// Primary itself doesn't have a token, so the Standby doesn't overwrite
    /// a previously-pulled value.
    private func handleDiscordTokenRequest() async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "leader_mode_required"))
        }
        let token = (await discordTokenProvider?())?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let payload = MeshDiscordTokenResponse(token: token, available: !token.isEmpty)
        let body = (try? encoder.encode(payload)) ?? Data()
        return httpResponse(status: "200 OK", body: body)
    }

    /// Standby/worker-side helper: called from `registerWithLeader` on each
    /// successful registration. AppModel only wires `onDiscordTokenFetched`
    /// when the local token is empty, so once a token has been pulled this
    /// becomes a no-op until the user clears the token again.
    private func pullDiscordTokenFromLeaderIfNeeded(leaderBaseURL: String) async {
        guard mode == .standby || mode == .worker else { return }
        guard let handler = onDiscordTokenFetched else { return }
        guard let url = URL(string: leaderBaseURL + "/v1/mesh/discord-token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMeshAuth(to: &request, path: "/v1/mesh/discord-token")
        request.timeoutInterval = 5
        do {
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard let payload = try? decoder.decode(MeshDiscordTokenResponse.self, from: data),
                  payload.available,
                  !payload.token.isEmpty else { return }
            await handler(payload.token)
            meshLogger.notice("Pulled Discord token from Primary after successful handshake")
        } catch {
            // best effort — next registration cycle will retry.
        }
    }

    #if DEBUG
    /// Test-only: insert a fake registered worker so failover/split-brain tests
    /// can drive the real push path without going through /cluster/register.
    func injectRegisteredWorkerForTesting(nodeName: String, baseURL: String, listenPort: Int) {
        let key = baseURL.lowercased()
        registeredWorkers[key] = RegisteredWorker(
            nodeName: nodeName,
            baseURL: baseURL,
            listenPort: listenPort,
            lastSeen: Date()
        )
    }
    #endif

    func applyRestoredCursors(_ cursors: [String: ReplicationCursor]) {
        // Only restore cursors from the current or newer term to avoid stale replay.
        for (nodeName, cursor) in cursors where cursor.leaderTerm >= leaderTerm {
            replicationCursors[nodeName] = cursor
        }
    }

    /// Returns (nodeName, baseURL) pairs for all currently registered workers/nodes.
    /// Evict a node from both the live registration table and the sticky
    /// `everKnownWorkers` cache so it no longer appears in the SwiftMesh
    /// cluster map. The node will reappear on its next successful
    /// `/cluster/register` call — this is "forget for now", not a permanent
    /// ban. Returns true if any entries were removed.
    @discardableResult
    func forgetNode(matching displayName: String) async -> Bool {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        let stickyKeys = everKnownWorkers.compactMap { (key, worker) -> String? in
            worker.nodeName.lowercased() == normalized ? key : nil
        }
        let liveKeys = registeredWorkers.compactMap { (key, worker) -> String? in
            worker.nodeName.lowercased() == normalized ? key : nil
        }
        for key in stickyKeys { everKnownWorkers.removeValue(forKey: key) }
        for key in liveKeys { registeredWorkers.removeValue(forKey: key) }

        // Also drop any follower-state snapshot keyed by the same baseURL so
        // the GUI's Follower Activity panel doesn't keep a ghost row.
        for key in stickyKeys + liveKeys {
            followerStates.removeValue(forKey: key.lowercased())
        }
        snapshot.followerStates = followerStates

        let removed = !stickyKeys.isEmpty || !liveKeys.isEmpty
        if removed {
            meshLogger.notice("Forgot cluster node \(displayName, privacy: .public) — removed from registration cache and sticky map")
            await publishSnapshot()
        }
        return removed
    }

    func registeredNodeInfo() -> [(nodeName: String, baseURL: String)] {
        registeredWorkers.values.map { ($0.nodeName, $0.baseURL) }
    }

    func registeredWorkersDebugInfo() -> (count: Int, summary: String) {
        pruneStaleRegistrations()
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else { return (0, "none") }
        let now = Date()
        let summary = workers.map { worker in
            let age = max(0, Int(now.timeIntervalSince(worker.lastSeen).rounded()))
            return "\(worker.nodeName) (\(age)s, \(worker.baseURL))"
        }.joined(separator: "; ")
        return (workers.count, summary)
    }

    func currentReplicationCursor(for nodeName: String) -> ReplicationCursor? {
        replicationCursors[nodeName]
    }

    func updateReplicationCursor(for nodeName: String, lastSentRecordID: String?, term: Int) async {
        if let existing = replicationCursors[nodeName] {
            if existing.leaderTerm > term {
                return
            }
            if existing.leaderTerm == term {
                switch (existing.lastSentRecordID, lastSentRecordID) {
                case let (existingID?, newID?):
                    guard newID > existingID else { return }
                case (_?, nil):
                    return
                default:
                    break
                }
            }
        }
        replicationCursors[nodeName] = ReplicationCursor(leaderTerm: term, lastSentRecordID: lastSentRecordID, updatedAt: Date())
        await onCursorsChanged?(replicationCursors)
    }

    func applySettings(
        mode: ClusterMode,
        nodeName: String,
        leaderAddress: String,
        leaderPort: Int? = nil,
        listenPort: Int,
        sharedSecret: String,
        leaderTerm: Int = 0
    ) async {
        let resolvedLeaderPort = leaderPort ?? listenPort
        // Restore persisted term; never go backwards.
        if leaderTerm > self.leaderTerm {
            self.leaderTerm = leaderTerm
            snapshot.leaderTerm = leaderTerm
        }
        self.nodeName = nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (Host.current().localizedName ?? "SwiftBot Node")
            : nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.listenPort = listenPort
        self.leaderPort = resolvedLeaderPort
        let previousLeaderAddress = self.leaderAddress
        self.leaderAddress = normalizedBaseURL(leaderAddress, defaultPort: resolvedLeaderPort) ?? leaderAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sharedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if previousLeaderAddress.lowercased() != self.leaderAddress.lowercased() {
            initialSyncCompletedLeaderBaseURL = nil
        }
        
        if handoverTestTask == nil {
            self.mode = await startupReconciledMode(requestedMode: mode)
        } else {
            meshLogger.debug("Handover test in progress; ignoring mode-change in applySettings (requested: \(mode.rawValue, privacy: .public), current: \(self.mode.rawValue, privacy: .public))")
        }

        snapshot.mode = self.mode
        snapshot.nodeName = self.nodeName
        snapshot.listenPort = listenPort
        snapshot.leaderAddress = self.leaderAddress
        snapshot.diagnostics = "Applied mode \(self.mode.rawValue)"
        snapshot.lastJobNode = self.nodeName

        if self.mode != .leader {
            registeredWorkers.removeAll()
        }

        await restartServerIfNeeded()
        await restartWorkerRegistrationIfNeeded()
        await restartStandbyMonitorIfNeeded()
        await restartFollowerStatePollIfNeeded()
        await refreshWorkerHealth()
        await publishSnapshot()
    }

    func setOffloadPolicy(workerOffloadEnabled: Bool, aiReplies: Bool, wikiLookups: Bool, playlistImports: Bool = true) async {
        offloadAIReplies = workerOffloadEnabled && aiReplies
        offloadWikiLookups = workerOffloadEnabled && wikiLookups
        offloadPlaylistImports = workerOffloadEnabled && playlistImports
        snapshot.diagnostics = "Offload policy updated (AI: \(offloadAIReplies ? "on" : "off"), Wiki: \(offloadWikiLookups ? "on" : "off"), Playlist: \(offloadPlaylistImports ? "on" : "off"))"
        await publishSnapshot()
    }

    func importPlaylist(from playlistURL: URL, limit: Int) async -> PlaylistImportResult? {
        let clampedLimit = max(1, min(limit, 100))

        if mode == .leader, offloadPlaylistImports,
           let remote = await performRemotePlaylistImport(playlistURL: playlistURL, limit: clampedLimit) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Playlist import via worker"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.result
        }

        let local = await playlistImportHandler?(playlistURL, clampedLimit)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "Playlist import unavailable" : "Playlist import local"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled playlist import locally on \(nodeName)"
        }
        await publishSnapshot()
        return local
    }

    /// Startup reconciliation to prevent split-brain:
    /// if this node is configured as leader but can reach a healthy existing leader
    /// at the configured leaderAddress, demote to standby and register with that leader.
    private func startupReconciledMode(requestedMode: ClusterMode) async -> ClusterMode {
        guard requestedMode == .leader else { return requestedMode }
        guard let configuredLeader = normalizedBaseURL(leaderAddress, defaultPort: leaderPort), !configuredLeader.isEmpty else {
            return requestedMode
        }
        guard !isSelfClusterEndpoint(configuredLeader) else { return requestedMode }
        guard let remoteStatus = await fetchRemoteClusterStatus(baseURL: configuredLeader) else {
            return requestedMode
        }

        let localLeaderID = "leader-\(ProcessInfo.processInfo.hostName.lowercased())-\(listenPort)"
        let remoteLeader = remoteStatus.response.nodes.first {
            $0.role == .leader && $0.status != .disconnected
        }
        if let remoteLeader, remoteLeader.id != localLeaderID {
            meshLogger.warning(
                "Startup reconciliation: discovered active leader \(remoteLeader.displayName, privacy: .public) at \(configuredLeader, privacy: .public); starting in standby mode"
            )
            leaderAddress = configuredLeader
            return .standby
        }

        return requestedMode
    }

    func stopAll() async {
        meshLogger.notice("Stopping all cluster services")
        stopMeshDiscovery()
        handoverTestTask?.cancel()
        _ = await handoverTestTask?.value
        handoverTestTask = nil
        workerRegistrationTask?.cancel()
        _ = await workerRegistrationTask?.value
        workerRegistrationTask = nil
        standbyMonitorTask?.cancel()
        _ = await standbyMonitorTask?.value
        standbyMonitorTask = nil
        followerStatePollTask?.cancel()
        _ = await followerStatePollTask?.value
        followerStatePollTask = nil
        followerStates.removeAll()
        listener?.cancel()
        listener = nil
        listenerActivePort = nil
        registeredWorkers.removeAll()
        standbyHealthMisses = 0
        snapshot.serverState = .stopped
        snapshot.serverStatusText = "Stopped"
        snapshot.workerState = .inactive
        snapshot.workerStatusText = "Stopped"
        snapshot.followerStates = [:]
        snapshot.diagnostics = "Cluster services stopped"
        await publishSnapshot()
    }

    func currentSnapshot() -> ClusterSnapshot {
        snapshot
    }

    func currentLeaderTerm() -> Int {
        leaderTerm
    }

    func normalizedLeaderBaseURL(_ raw: String) -> String? {
        normalizedBaseURL(raw)
    }

    func refreshWorkerHealth() async {
        switch mode {
        case .standby:
            guard let leaderBaseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort), !leaderBaseURL.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "Primary not configured"
                snapshot.diagnostics = "Fail Over requires a Primary Address"
                await publishSnapshot()
                return
            }
            snapshot.workerState = .connected
            snapshot.workerStatusText = "Monitoring Primary (term \(leaderTerm))"
            snapshot.diagnostics = "Fail Over — watching \(leaderBaseURL)"
            await publishSnapshot()
        case .standalone:
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Not applicable"
            snapshot.diagnostics = "Cluster mode is standalone"
            await publishSnapshot()
        case .leader:
            pruneStaleRegistrations()
            let workers = sortedRegisteredWorkers()
            guard !workers.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "No workers registered"
                snapshot.diagnostics = "Waiting for workers to register"
                await publishSnapshot()
                return
            }

            var reachable = 0
            for worker in workers {
                if await isWorkerReachable(worker.baseURL) {
                    reachable += 1
                }
            }

            if reachable == workers.count {
                snapshot.workerState = .connected
                snapshot.workerStatusText = "\(reachable) workers reachable"
            } else if reachable > 0 {
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "\(reachable)/\(workers.count) workers reachable"
            } else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "No workers reachable"
            }
            snapshot.diagnostics = "Registered workers: \(workers.count), reachable: \(reachable)"
            await publishSnapshot()
        case .worker:
            guard let leaderBaseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort), !leaderBaseURL.isEmpty else {
                snapshot.workerState = .inactive
                snapshot.workerStatusText = "Primary not configured"
                snapshot.diagnostics = "Worker requires a Primary Address"
                await publishSnapshot()
                return
            }

            guard let url = URL(string: leaderBaseURL + "/health") else {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Invalid Primary address"
                snapshot.diagnostics = "Primary Address is invalid: \(leaderAddress)"
                await publishSnapshot()
                return
            }

            do {
                let (_, response) = try await meshSession.data(from: url)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    snapshot.workerState = .connected
                    snapshot.workerStatusText = "Primary reachable"
                    snapshot.diagnostics = "Primary reachable via \(url.absoluteString)"
                } else {
                    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                    snapshot.workerState = .degraded
                    snapshot.workerStatusText = "Primary health check failed (\(status))"
                    snapshot.diagnostics = "Primary health returned HTTP \(status) via \(url.absoluteString)"
                }
            } catch {
                snapshot.workerState = .failed
                snapshot.workerStatusText = "Primary unavailable"
                snapshot.diagnostics = "Primary health request failed for \(url.absoluteString): \(error.localizedDescription)"
            }
            await publishSnapshot()
        }
    }

    func generateAIReply(
        messages: [Message],
        serverName: String? = nil,
        channelName: String? = nil,
        wikiContext: String? = nil
        ) async -> String? {
        // AI reply override for unit tests (compliant with March 2026 standards).
#if DEBUG
        if let override = AITestOverrides.replyOverride {
            if AITestOverrides.replyDelaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(AITestOverrides.replyDelaySeconds * 1_000_000_000))
            }
            return override.isEmpty ? nil : override
        }
#endif

        guard let aiHandler else { return nil }

        let job = AIJobRequest(
            messages: messages,
            serverName: serverName,
            channelName: channelName,
            wikiContext: wikiContext
        )
        if mode == .leader, offloadAIReplies, let remote = await performRemoteAI(job) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "AI reply via worker"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.reply
        }

        let local = await aiHandler(messages, serverName, channelName, wikiContext)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "AI reply unavailable" : "AI reply local"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled AI reply locally on \(nodeName)"
        }
        await publishSnapshot()
        return local
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        if mode == .leader, offloadWikiLookups, let remote = await performRemoteWikiLookup(query: query, source: source) {
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Wiki lookup via worker (\(source.name))"
            snapshot.lastJobNode = remote.nodeName
            await publishSnapshot()
            return remote.result
        }

        let local = await wikiHandler?(query, source)
        snapshot.lastJobRoute = local == nil ? .unavailable : .local
        snapshot.lastJobSummary = local == nil ? "Wiki lookup unavailable" : "Wiki lookup local (\(source.name))"
        snapshot.lastJobNode = nodeName
        if local != nil {
            snapshot.diagnostics = "Handled wiki lookup locally on \(nodeName) for \(source.name)"
        }
        await publishSnapshot()
        return local
    }

    func probeWorker() async -> ClusterProbeResponse? {
        guard mode == .leader else {
            snapshot.diagnostics = "Remote cluster worker probe is only available in Primary mode"
            await publishSnapshot()
            return nil
        }

        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No workers registered for probe"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/probe") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyMeshAuth(to: &request, path: "/v1/probe")
                let (data, response) = try await meshSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(ClusterProbeResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote probe OK"
                snapshot.lastJobRoute = .remote
                snapshot.lastJobSummary = "Remote cluster worker probe"
                snapshot.lastJobNode = decoded.nodeName
                snapshot.diagnostics = "Worker \(decoded.nodeName) responded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote probe unavailable"
        snapshot.diagnostics = "Remote probe failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    // MARK: - Mesh Auth (HMAC-SHA256)

    /// Computes HMAC-SHA256 over `METHOD:path:nonce:timestamp:` + body bytes using sharedSecret as key.
    /// Returns a lowercase hex string. Returns empty string if sharedSecret is empty.
    private func pruneNonces(now: Date) {
        usedNonces = usedNonces.filter { now.timeIntervalSince($0.value) < 60 }
    }

    func meshSignature(method: String, nonce: String, timestamp: Int, path: String, body: Data) -> String {
        let normalizedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSecret.isEmpty,
              let keyData = normalizedSecret.data(using: .utf8) else { return "" }
        let key = SymmetricKey(data: keyData)
        var input = Data("\(method.uppercased()):\(path):\(nonce):\(timestamp):".utf8)
        input.append(body)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Adds `X-Mesh-Nonce`, `X-Mesh-Timestamp`, `X-Mesh-Signature`, and (when
    /// the request has a non-empty body) `X-Mesh-Encrypted: v1` headers to a
    /// URLRequest. The body is encrypted via `MeshCrypto.seal` *before*
    /// signing so the receiver can verify HMAC over the wire ciphertext
    /// without decrypting first (textbook verify-then-decrypt).
    ///
    /// Only adds headers when sharedSecret is non-empty; otherwise leaves the
    /// request untouched (standalone mode makes no clustered calls so this
    /// is safe).
    private func applyMeshAuth(to request: inout URLRequest, path: String) {
        let normalizedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSecret.isEmpty else { return }
        let method = request.httpMethod ?? "GET"
        let nonce = UUID().uuidString
        let timestamp = Int(Date().timeIntervalSince1970)
        let plaintext = request.httpBody ?? Data()

        // Encrypt non-empty bodies. Empty-body calls (most GETs) go unencrypted
        // — they carry no secrets and the HMAC still authenticates the call.
        var wireBody = plaintext
        if !plaintext.isEmpty {
            do {
                let key = try MeshCrypto.deriveKey(from: normalizedSecret)
                wireBody = try MeshCrypto.seal(plaintext, using: key)
                request.setValue(MeshCrypto.headerValueV1, forHTTPHeaderField: MeshCrypto.headerName)
                request.httpBody = wireBody
            } catch {
                // Falling back to plaintext would silently weaken every call.
                // Better to fail closed so the receiver's HMAC rejects rather
                // than send unencrypted secrets across the WAN.
                meshLogger.error("Mesh body encryption failed; sending will likely 401: \(error.localizedDescription, privacy: .public)")
            }
        }

        let sig = meshSignature(method: method, nonce: nonce, timestamp: timestamp, path: path, body: wireBody)
        request.setValue(nonce, forHTTPHeaderField: "X-Mesh-Nonce")
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Mesh-Timestamp")
        request.setValue(sig, forHTTPHeaderField: "X-Mesh-Signature")
    }

    /// Verifies inbound mesh auth headers. Returns true only if:
    /// - All required headers present
    /// - Timestamp within ±300s skew window
    /// - Nonce has not been seen before (replay protection)
    /// - HMAC-SHA256 signature is valid (constant-time via CryptoKit)
    private func verifyMeshAuth(headers: [String: String], method: String, path: String, body: Data) -> Bool {
        let normalizedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSecret.isEmpty else { return false }
        guard let nonce = headers["x-mesh-nonce"],
              let tsStr = headers["x-mesh-timestamp"],
              let timestamp = Int(tsStr),
              let sigHex = headers["x-mesh-signature"] else { return false }

        // Opportunistic sweep of expired nonces (older than 60s).
        let now = Date()
        let nowEpoch = Int(now.timeIntervalSince1970)
        pruneNonces(now: now)

        // Timestamp skew check — fail-closed if outside ±60s window.
        let skew = abs(nowEpoch - timestamp)
        guard skew <= 60 else {
            meshLogger.warning("Mesh auth rejected: timestamp skew \(skew)s exceeds 60s window")
            return false
        }

        // Nonce replay check — reject if this nonce has been seen within the skew window.
        guard usedNonces[nonce] == nil else {
            meshLogger.warning("Mesh auth rejected: nonce replay detected")
            return false
        }

        guard let keyData = normalizedSecret.data(using: .utf8) else { return false }
        let key = SymmetricKey(data: keyData)
        var input = Data("\(method.uppercased()):\(path):\(nonce):\(timestamp):".utf8)
        input.append(body)

        // Convert hex signature back to bytes for constant-time comparison.
        guard sigHex.count % 2 == 0 else { return false }
        var expectedBytes = [UInt8]()
        var idx = sigHex.startIndex
        while idx < sigHex.endIndex {
            let nextIdx = sigHex.index(idx, offsetBy: 2)
            guard let byte = UInt8(sigHex[idx..<nextIdx], radix: 16) else { return false }
            expectedBytes.append(byte)
            idx = nextIdx
        }

        guard HMAC<SHA256>.isValidAuthenticationCode(expectedBytes, authenticating: input, using: key) else {
            return false
        }

        // Record nonce as used (keyed to expiry time).
        usedNonces[nonce] = now
        return true
    }

    private func restartServerIfNeeded() async {
        // Skip if already listening on the correct port — prevents double-bind from
        // multiple applySettings call sites (startup, settings save, bot start).
        if listener != nil, listenerActivePort == listenPort, mode != .standalone {
            return
        }

        stopMeshDiscovery()
        listener?.cancel()
        listener = nil

        guard mode != .standalone else {
            snapshot.serverState = .inactive
            snapshot.serverStatusText = "Disabled"
            return
        }

        do {
            snapshot.serverState = .starting
            snapshot.serverStatusText = "Starting on :\(listenPort)"
            snapshot.diagnostics = "Starting worker server on port \(listenPort)"
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(listenPort)))
            // P1b: advertise this node over Bonjour so LAN peers can discover it.
            let txtRecord = NWTXTRecord([
                "node": nodeName,
                "port": "\(listenPort)",
                "host": ProcessInfo.processInfo.hostName
            ])
            listener.service = NWListener.Service(name: nodeName, type: "_swiftbot-mesh._tcp", txtRecord: txtRecord)
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handleConnection(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { await self?.handleListenerState(state) }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Failed to bind port \(listenPort): \(error.localizedDescription)"
        }

        // P1b: start browsing for other LAN nodes regardless of role.
        startMeshDiscovery()
    }

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            listenerActivePort = listenPort
            snapshot.serverState = .listening
            snapshot.serverStatusText = "Listening on :\(listenPort)"
            snapshot.diagnostics = "Worker server listening on port \(listenPort)"
            meshLogger.info("Mesh server started on port \(self.listenPort, privacy: .public)")
        case .failed(let error):
            listenerActivePort = nil
            snapshot.serverState = .failed
            snapshot.serverStatusText = "Server failed: \(error.localizedDescription)"
            snapshot.diagnostics = "Worker server failed: \(error.localizedDescription)"
        case .cancelled:
            listenerActivePort = nil
            snapshot.serverState = .stopped
            snapshot.serverStatusText = "Stopped"
            snapshot.diagnostics = "Worker server stopped"
        default:
            break
        }
        await publishSnapshot()
    }

    // MARK: - P1b: LAN peer discovery

    /// Returns base URLs of LAN-discovered peers, sorted by discovery time (oldest first).
    /// Peers are discovered via Bonjour (_swiftbot-mesh._tcp) and keyed by node name for dedupe.
    /// Does NOT replace the manual leaderAddress path; purely additive.
    func discoveredPeerBaseURLs() -> [String] {
        // Primary: discovery time (oldest first). Secondary: nodeName (lexicographic) for
        // fully deterministic output when two peers are discovered within the same tick.
        discoveredPeers.values
            .sorted {
                if $0.discoveredAt != $1.discoveredAt { return $0.discoveredAt < $1.discoveredAt }
                return $0.nodeName < $1.nodeName
            }
            .map { $0.baseURL }
    }

    private func startMeshDiscovery() {
        meshBrowser?.cancel()
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_swiftbot-mesh._tcp", domain: nil),
            using: .tcp
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.handleDiscoveryResults(results) }
        }
        browser.start(queue: .global(qos: .utility))
        meshBrowser = browser
    }

    private func stopMeshDiscovery() {
        meshBrowser?.cancel()
        meshBrowser = nil
        discoveredPeers.removeAll()
    }

    private func handleDiscoveryResults(_ results: Set<NWBrowser.Result>) {
        // Single timestamp for the entire batch so all newly seen peers in the same
        // browse update share the same discoveredAt — preventing Set iteration order
        // from producing different primary-sort values across runs.
        let batchTimestamp = Date()
        var active: [String: DiscoveredPeer] = [:]
        for result in results {
            guard case let .bonjour(txtRecord) = result.metadata else { continue }
            let peerName = txtRecord["node"] ?? ""
            let host = txtRecord["host"] ?? ""
            let portStr = txtRecord["port"] ?? ""
            guard !peerName.isEmpty, !host.isEmpty,
                  let port = Int(portStr), port > 0 else { continue }
            guard peerName != nodeName else { continue }  // skip self
            let baseURL = "http://\(host):\(port)"
            if let existing = active[peerName] {
                // Deterministic collision rule: when the same nodeName appears more than once
                // in a single browse batch, prefer the lexicographically smallest baseURL so
                // the result is independent of Set iteration order.
                if baseURL < existing.baseURL {
                    active[peerName] = DiscoveredPeer(
                        nodeName: peerName,
                        baseURL: baseURL,
                        discoveredAt: existing.discoveredAt
                    )
                }
            } else {
                // New peer: use batchTimestamp (not per-item Date()) so all peers first seen
                // in the same batch share an identical discoveredAt; secondary nodeName sort
                // then provides stable output ordering within the batch.
                active[peerName] = DiscoveredPeer(
                    nodeName: peerName,
                    baseURL: baseURL,
                    discoveredAt: discoveredPeers[peerName]?.discoveredAt ?? batchTimestamp
                )
            }
        }
        discoveredPeers = active
    }

    private func handleConnection(_ connection: NWConnection) async {
        guard acquireConnectionSlot() else {
            // Over capacity: shed load rather than queueing unbounded work.
            connection.start(queue: .global(qos: .utility))
            let body = #"{"error":"server_busy"}"#.data(using: .utf8) ?? Data()
            let response = httpResponse(status: "503 Service Unavailable", body: body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }
        defer { releaseConnectionSlot() }

        connection.start(queue: .global(qos: .utility))
        let remoteHost = remoteHostFromConnection(connection)
        do {
            // Hard wall-clock cap: `readHTTPRequest` only checks the clock
            // between chunks, so a peer that connects and then sends nothing
            // would otherwise block forever inside `receiveChunk`.
            let requestData = try await withReadTimeout(connection: connection) {
                try await self.readHTTPRequest(connection)
            }
            let response = await processHTTPRequest(requestData, remoteHost: remoteHost)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            let body = #"{"error":"bad_request"}"#.data(using: .utf8) ?? Data()
            let response = httpResponse(status: "400 Bad Request", body: body)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func acquireConnectionSlot() -> Bool {
        guard activeConnectionCount < Self.maxConcurrentConnections else { return false }
        activeConnectionCount += 1
        return true
    }

    private func releaseConnectionSlot() {
        if activeConnectionCount > 0 { activeConnectionCount -= 1 }
    }

    /// Race the read against a wall-clock timeout. On timeout we cancel the
    /// connection *before* throwing: `NWConnection.receive` does not observe
    /// Swift task cancellation, so without the explicit cancel the read child
    /// task would stay suspended on its continuation and the task group could
    /// never finish tearing down.
    private func withReadTimeout<T: Sendable>(
        connection: NWConnection,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.httpReadTimeout * 1_000_000_000))
                connection.cancel()
                throw NWError.posix(.ETIMEDOUT)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func remoteHostFromConnection(_ connection: NWConnection) -> String? {
        guard case let .hostPort(host, _) = connection.endpoint else { return nil }
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return address.debugDescription
        case .ipv6(let address):
            return address.debugDescription
        @unknown default:
            return nil
        }
    }

    private func readHTTPRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let start = Date()

        while buffer.count < Self.maxHTTPRequestSize {
            if Date().timeIntervalSince(start) > Self.httpReadTimeout {
                throw NWError.posix(.ETIMEDOUT)
            }

            let chunk = try await receiveChunk(from: connection)
            if chunk.isEmpty { break }
            buffer.append(chunk)

            if let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[..<headerRange.upperBound]
                let contentLength = parseContentLength(headerData)
                let bodyLength = buffer.count - headerRange.upperBound

                if contentLength > Self.maxHTTPRequestSize {
                    throw NWError.posix(.EMSGSIZE)
                }

                if bodyLength >= contentLength {
                    return buffer
                }
            }
        }

        if buffer.count >= Self.maxHTTPRequestSize {
            throw NWError.posix(.EMSGSIZE)
        }

        return buffer
    }

    private func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                    return
                }
                if isComplete {
                    continuation.resume(returning: Data())
                    return
                }
                continuation.resume(returning: Data())
            }
        }
    }

    private func parseContentLength(_ headerData: Data.SubSequence) -> Int {
        guard let headerText = String(data: Data(headerData), encoding: .utf8) else { return 0 }
        for line in headerText.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:"),
               let value = lower.split(separator: ":").last,
               let intValue = Int(value.trimmingCharacters(in: .whitespaces)) {
                return intValue
            }
        }
        return 0
    }

    func processHTTPRequest(_ requestData: Data, remoteHost: String? = nil) async -> Data {
        guard var request = parseRequest(requestData) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_request"}"#.utf8))
        }

        // Enforce HMAC auth on all routes except /health.
        // Policy:
        //   - Non-standalone mode + empty sharedSecret → fail-closed (401): clustered nodes must have a secret.
        //   - Any mode + non-empty sharedSecret → require valid HMAC signature.
        //   - Standalone mode + empty sharedSecret → open (local-only node, no cluster traffic expected).
        if request.path != "/health" {
            let normalizedSecret = sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode != .standalone && normalizedSecret.isEmpty {
                meshLogger.warning("Mesh auth rejected: non-standalone mode with no shared secret configured")
                return httpResponse(status: "401 Unauthorized", body: Data(#"{"error":"unauthorized"}"#.utf8))
            }
            if !normalizedSecret.isEmpty {
                // verify-then-decrypt: HMAC is computed over the wire body
                // (ciphertext), so validation runs without touching crypto.
                guard verifyMeshAuth(headers: request.headers, method: request.method, path: request.path, body: request.body) else {
                    meshLogger.warning("Mesh auth rejected: invalid HMAC, stale timestamp, or replay for path \(request.path, privacy: .public)")
                    return httpResponse(status: "401 Unauthorized", body: Data(#"{"error":"unauthorized"}"#.utf8))
                }

                // If the peer flagged the body as encrypted, decrypt before
                // dispatching to the route handler. The HMAC layer already
                // guaranteed the ciphertext is authentic, but AES-GCM's auth
                // tag is the *cryptographic* integrity check — a malformed
                // ciphertext that somehow survived HMAC would still throw
                // here. Empty bodies are never encrypted (see applyMeshAuth).
                if request.headers[MeshCrypto.headerName.lowercased()] == MeshCrypto.headerValueV1,
                   !request.body.isEmpty {
                    do {
                        let key = try MeshCrypto.deriveKey(from: normalizedSecret)
                        request.body = try MeshCrypto.open(request.body, using: key)
                    } catch {
                        meshLogger.warning("Mesh body decryption failed for \(request.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"decryption_failed"}"#.utf8))
                    }
                }
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            let payload = HealthResponse(nodeName: nodeName, mode: mode.rawValue, status: "ok")
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/cluster/ping"):
            let payload = ClusterPingResponse(
                status: "ok",
                role: mode == .leader ? "leader" : "worker",
                node: nodeName
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/cluster/register"):
            return await handleWorkerRegistration(request.body, remoteHost: remoteHost)
        case ("GET", "/cluster/status"):
            let payload = await clusterStatusPayload()
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("GET", "/v1/probe"):
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote worker probe"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote probe on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: "Cluster",
                server: "Cluster",
                command: "GET /v1/probe",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let payload = ClusterProbeResponse(
                nodeName: nodeName,
                mode: mode.rawValue,
                listenPort: listenPort,
                timestamp: ISO8601DateFormatter().string(from: Date())
            )
            let body = (try? encoder.encode(payload)) ?? Data()
            return httpResponse(status: "200 OK", body: body)
        case ("POST", "/v1/ai-reply"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let aiHandler,
                  let body = try? decoder.decode(AIJobRequest.self, from: request.body),
                  let reply = await aiHandler(body.messages, body.serverName, body.channelName, body.wikiContext) else {
                return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"ai_unavailable"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote AI reply"
            snapshot.lastJobNode = nodeName
            let requestUser = body.messages.last(where: { $0.role == .user })?.username ?? "Unknown"
            snapshot.diagnostics = "Handled remote AI reply for \(requestUser) on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: requestUser,
                server: "Remote AI",
                command: "AI reply",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = AIJobResponse(nodeName: nodeName, reply: reply)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/wiki-lookup"), ("POST", "/v1/finals-wiki"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let wikiHandler,
                  let body = decodeWikiJobRequest(from: request.body),
                  let result = await wikiHandler(body.query, body.source) else {
                await recordJobLog(
                    user: "Remote Wiki",
                    server: "Cluster",
                    command: "Wiki lookup failed",
                    channel: "worker",
                    executionRoute: "Worker",
                    ok: false
                )
                return httpResponse(status: "404 Not Found", body: Data(#"{"error":"not_found"}"#.utf8))
            }
            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote wiki lookup"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote wiki lookup for \"\(body.query)\" on \(nodeName) (\(body.source.name))"
            await publishSnapshot()
            await recordJobLog(
                user: body.source.name,
                server: "Remote Wiki",
                command: "/wiki \(body.query)",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = WikiJobResponse(nodeName: nodeName, result: result)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/playlist-import"):
            activeJobs += 1
            defer { activeJobs = max(0, activeJobs - 1) }
            guard let playlistImportHandler,
                  let body = try? decoder.decode(PlaylistImportJobRequest.self, from: request.body),
                  let playlistURL = URL(string: body.playlistURL) else {
                return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_request"}"#.utf8))
            }
            guard let result = await playlistImportHandler(playlistURL, max(1, min(body.limit, 100))) else {
                await recordJobLog(
                    user: "Remote Playlist",
                    server: "Cluster",
                    command: "Playlist import failed",
                    channel: "worker",
                    executionRoute: "Worker",
                    ok: false
                )
                return httpResponse(status: "404 Not Found", body: Data(#"{"error":"playlist_unavailable"}"#.utf8))
            }

            snapshot.lastJobRoute = .remote
            snapshot.lastJobSummary = "Served remote playlist import"
            snapshot.lastJobNode = nodeName
            snapshot.diagnostics = "Handled remote playlist import on \(nodeName)"
            await publishSnapshot()
            await recordJobLog(
                user: "Playlist Import",
                server: "Remote Playlist",
                command: "Playlist import",
                channel: "worker",
                executionRoute: "Worker",
                ok: true
            )
            let response = PlaylistImportJobResponse(nodeName: nodeName, result: result)
            let bodyData = (try? encoder.encode(response)) ?? Data()
            return httpResponse(status: "200 OK", body: bodyData)
        case ("POST", "/v1/mesh/leader-changed"):
            return await handleMeshLeaderChanged(request.body)
        case ("GET", "/v1/mesh/workers"):
            return handleMeshWorkersRequest()
        case ("POST", "/v1/mesh/sync/worker-registry"):
            return await handleMeshWorkerRegistrySync(request.body)
        case ("POST", "/v1/mesh/sync/conversations"):
            return await handleMeshConversationSync(request.body)
        case ("POST", "/v1/mesh/sync/conversations/resync"):
            return await handleMeshConversationResync(request.body)
        case ("GET", "/v1/mesh/sync/wiki-cache"):
            return await handleMeshWikiCacheSync()
        case ("GET", "/v1/mesh/sync/config-files"):
            return await handleMeshConfigFilesSync()
        case ("GET", "/v1/media/library"):
            return await handleMediaLibraryRequest()
        case ("GET", "/v1/media/stream"):
            guard let itemID = request.query["id"], !itemID.isEmpty else {
                return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"missing_id"}"#.utf8))
            }
            return await handleMediaStreamRequest(itemID: itemID, rangeHeader: request.headers["range"])
        case ("GET", "/v1/media/thumbnail"):
            guard let itemID = request.query["id"], !itemID.isEmpty else {
                return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"missing_id"}"#.utf8))
            }
            return await handleMediaThumbnailRequest(itemID: itemID)
        case ("GET", "/v1/media/frame"):
            guard let itemID = request.query["id"], !itemID.isEmpty else {
                return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"missing_id"}"#.utf8))
            }
            let seconds = Double(request.query["t"] ?? "0") ?? 0
            return await handleMediaFrameRequest(itemID: itemID, seconds: seconds)
        case ("POST", "/v1/media/clip"):
            return await handleMediaClipRequest(request.body)
        case ("POST", "/v1/media/multiview"):
            return await handleMediaMultiViewRequest(request.body)
        case ("GET", "/v1/mesh/follower-state"):
            return await handleFollowerStateRequest()
        case ("POST", "/v1/mesh/handover-test/begin"):
            return await handleHandoverTestBegin(request.body)
        case ("POST", "/v1/mesh/handover-test/end"):
            return await handleHandoverTestEnd(request.body)
        case ("GET", "/v1/mesh/discord-token"):
            return await handleDiscordTokenRequest()
        default:
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"unknown_route"}"#.utf8))
        }
    }

    private func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<marker.lowerBound], encoding: .utf8) else {
            return nil
        }

        let body = Data(data[marker.upperBound...])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        let rawTarget = String(parts[1])
        let components = URLComponents(string: "http://localhost\(rawTarget)")
        let path = components?.path.isEmpty == false ? components?.path ?? "/" : "/"
        var query: [String: String] = [:]
        components?.queryItems?.forEach { item in
            query[item.name] = item.value ?? ""
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        return HTTPRequest(method: String(parts[0]), path: path, query: query, headers: headers, body: body)
    }

    private func httpResponse(
        status: String,
        body: Data,
        contentType: String = "application/json",
        headers: [String: String] = [:]
    ) -> Data {
        let header = "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            headers.map { "\($0.key): \($0.value)\r\n" }.joined() +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }

    private func restartStandbyMonitorIfNeeded() async {
        standbyMonitorTask?.cancel()
        _ = await standbyMonitorTask?.value
        standbyMonitorTask = nil
        standbyHealthMisses = 0
        standbyHealthySince = nil

        guard mode == .standby else { return }
        guard let leaderBaseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort), !leaderBaseURL.isEmpty else {
            return
        }

        meshLogger.debug("Starting standby health monitor for \(leaderBaseURL, privacy: .public)")
        standbyMonitorTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.standbyHealthInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await monitorLeaderHealth(leaderBaseURL)
            }
            meshLogger.debug("Standby health monitor exited")
        }
    }

    private func monitorLeaderHealth(_ leaderBaseURL: String) async {
        guard mode == .standby else { return }

        var isHealthy = await isWorkerReachable(leaderBaseURL)
        // Bug-2 fix: a single failed probe is not enough to count a miss. Network
        // jitter or a momentarily-busy event loop can drop one request. Retry once
        // with a short backoff before deciding the leader is unreachable.
        if !isHealthy {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            guard mode == .standby else { return }
            isHealthy = await isWorkerReachable(leaderBaseURL)
        }
        if isHealthy {
            if standbyHealthMisses > 0 {
                snapshot.diagnostics = "Primary recovered after \(standbyHealthMisses) misses"
                // Flag transient recovery so the dashboard shows the node
                // climbing out of isolation rather than silently resetting.
                if snapshot.runtimeState == .isolated {
                    snapshot.runtimeState = .recovering
                }
                await publishSnapshot()
            } else if snapshot.runtimeState == .recovering {
                // Healthy ticks after a recovery — return to idle.
                snapshot.runtimeState = .idle
                await publishSnapshot()
            }
            standbyHealthMisses = 0
            // Phase 4: only the originally-configured primary, currently
            // demoted to standby, with auto-reclaim enabled, accumulates a
            // continuous healthy clock. Reclaim once the threshold elapses.
            if isConfiguredPrimary && autoReclaimAfterSeconds > 0 {
                if standbyHealthySince == nil {
                    standbyHealthySince = Date()
                } else if let since = standbyHealthySince,
                          Date().timeIntervalSince(since) >= autoReclaimAfterSeconds {
                    meshLogger.notice("Auto-reclaim threshold reached after \(self.autoReclaimAfterSeconds, privacy: .public)s healthy; reclaiming Primary")
                    standbyHealthySince = nil
                    await promoteToLeader()
                    return
                }
            }
            // NOTE: Removed the duplicate `registerWithLeader` safety-net call.
            // The dedicated `workerRegistrationTask` already registers every 30s.
            // Calling it here too caused overlapping HTTP requests to the primary,
            // which contributed to CFNetwork loader-queue races on the standby.
        } else {
            // Any miss resets the auto-reclaim clock; reclaim only fires after
            // a fully-uninterrupted healthy window.
            standbyHealthySince = nil
            standbyHealthMisses += 1
            snapshot.diagnostics = "Primary health miss \(standbyHealthMisses)/\(Self.standbyPromotionThreshold)"
            // Mark as isolated once misses cross half the promotion threshold
            // — visible warning that we may promote soon, before we actually
            // commit to a promotion attempt.
            if standbyHealthMisses >= max(1, Self.standbyPromotionThreshold / 2) {
                snapshot.runtimeState = .isolated
            }
        meshLogger.warning("Primary health miss \(self.standbyHealthMisses, privacy: .public)/\(Self.standbyPromotionThreshold, privacy: .public)")
            await publishSnapshot()

            if standbyHealthMisses >= Self.standbyPromotionThreshold {
                // Bug 1 / Bug 3: confirm leader is genuinely dead AND attempt a final
                // tail-resync before promoting. If the leader answers the high-timeout
                // probe, the previous misses were transient — abort and reset.
                let shouldPromote = await confirmLeaderDeadAndResync(leaderBaseURL)
                if shouldPromote {
                    await promoteToLeader()
                } else {
                    standbyHealthMisses = 0
                    snapshot.diagnostics = "Primary reachable on confirmation probe; aborting promotion"
                    meshLogger.warning("Promotion aborted: leader reachable on confirmation probe (term \(self.leaderTerm, privacy: .public))")
                    await publishSnapshot()
                }
            }
        }
    }

    /// Called immediately before `promoteToLeader()`. Performs:
    /// 1. A final, generous-timeout health probe (retried twice) to filter long
    ///    network blips that beat the per-cycle confirm-retry above. If the
    ///    leader responds, the standby remains a standby — preventing the
    ///    split-brain scenario where a still-alive primary loses its role to a
    ///    falsely-promoted standby.
    /// 2. A best-effort final resync pull from the cursor, so when this node
    ///    promotes it has the absolute latest records before flipping output
    ///    on. Failures here are non-fatal: standby has been merging live syncs
    ///    while in passive mode and is already substantially up to date.
    /// Returns `true` if promotion should proceed.
    private func confirmLeaderDeadAndResync(_ leaderBaseURL: String) async -> Bool {
        // (1) Final liveness probes with generous timeout. Two attempts.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { return false }
            }
            if await isWorkerReachable(leaderBaseURL, timeout: 10) {
                return false
            }
        }
        // (2) Best-effort tail-resync. If this works, the leader is actually alive
        // and we should abort. If it fails, the leader is dead — proceed to promote.
        // Page size kept small (50) to keep this fast on a slow link.
        if let payload = await fetchResyncPage(fromRecordID: nil, pageSize: 50) {
            // Resync succeeded — leader is alive. Hand the payload to the sync
            // handler so any tail records get merged before we abort.
            await onSync?(payload)
            meshLogger.warning("Final resync succeeded; leader is alive — promotion aborted")
            return false
        }
        // (3) Secondary signal — if the Primary publishes a public URL we can
        // also probe `/live` over HTTPS (works through NAT, doesn't depend on
        // the direct mesh socket). If that probe still finds the Primary
        // online, the mesh failure is more likely a routing issue and we
        // should NOT promote. Returns nil when no URL is known; in that case
        // we proceed with mesh-only behavior unchanged.
        if let publiclyReachable = await onConfirmPrimaryPubliclyReachable?(), publiclyReachable == true {
            meshLogger.warning("Direct mesh probe failed, but Primary still answers /live publicly — promotion aborted (routing issue suspected)")
            return false
        }
        return true
    }
    func promoteToLeader() async {
        guard mode == .standby else { return }

        // Capture the leader address we're about to replace so a temp-Primary
        // (handover test) knows where to send the "end" signal when its
        // window elapses. This is the address direction that always works
        // — Standby→Primary outbound was how we registered originally.
        previousLeaderAddressBeforePromotion = leaderAddress
        previousLeaderNameBeforePromotion = currentLeaderNodeName

        // Surface the in-flight promotion in the dashboard / logs.
        snapshot.runtimeState = .promoting
        await publishSnapshot()

        mode = .leader
        leaderTerm += 1
        snapshot.mode = .leader
        snapshot.leaderTerm = leaderTerm
        snapshot.diagnostics = "PROMOTED TO PRIMARY (Term \(leaderTerm))"
        meshLogger.critical("Node promoted to Primary — term \(self.leaderTerm, privacy: .public), node \(self.nodeName, privacy: .public)")
        snapshot.workerState = .connected
        snapshot.workerStatusText = "Primary (Promoted)"
        await publishSnapshot()

        // Persist the new term immediately so a restart cannot emit a stale term.
        await onTermChanged?(leaderTerm)

        // Notify AppModel to start bot services
        await onPromotion?()

        // Bug 4 fix: do NOT wipe replicationCursors on promotion. The cursors
        // describe what each worker has already received; wiping them forces a
        // full log replay (causing duplicates and log bloat). Instead, advance
        // each cursor's term to the new epoch so it remains valid going
        // forward — `updateReplicationCursor` will reject stale-term writes via
        // its existing guard, so this is safe.
        for (nodeName, cursor) in replicationCursors {
            replicationCursors[nodeName] = ReplicationCursor(
                leaderTerm: leaderTerm,
                lastSentRecordID: cursor.lastSentRecordID,
                updatedAt: Date()
            )
        }
        await onCursorsChanged?(replicationCursors)

        // Stop standby monitoring and registration — no longer a standby.
        standbyMonitorTask?.cancel()
        _ = await standbyMonitorTask?.value
        standbyMonitorTask = nil
        workerRegistrationTask?.cancel()
        _ = await workerRegistrationTask?.value
        workerRegistrationTask = nil

        // Restart server as leader
        await restartServerIfNeeded()
        // Begin polling follower state now that we're primary.
        await restartFollowerStatePollIfNeeded()

        // Notify workers of the new leader
        let workers = Array(registeredWorkers.values)
        if !workers.isEmpty {
            snapshot.diagnostics = "Promoted to Primary. Notifying \(workers.count) workers..."
            await publishSnapshot()

            let payload = MeshLeaderChangedPayload(
                term: leaderTerm,
                leaderAddress: localWorkerAdvertisedBaseURL(),
                leaderNodeName: nodeName,
                sharedSecret: sharedSecret
            )

            for worker in workers {
                await notifyWorkerOfLeaderChange(worker, payload: payload)
            }
        }

        // Promotion complete — runtime state settles back to idle.
        snapshot.runtimeState = .idle
        await publishSnapshot()
    }

    private func notifyWorkerOfLeaderChange(_ worker: RegisteredWorker, payload: MeshLeaderChangedPayload) async {
        guard let url = URL(string: worker.baseURL + "/v1/mesh/leader-changed") else { return }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/v1/mesh/leader-changed")
            request.timeoutInterval = 5
            let (data, response) = try await meshSession.data(for: request)
            await detectStaleSelfFromResponse(data: data, response: response)
        } catch {
            // Best effort — worker will re-register on its own next cycle if missed
        }
    }

    func pushWorkerRegistryToStandbys() async {
        guard mode == .leader else { return }
        let workers = Array(registeredWorkers.values)
        guard !workers.isEmpty else { return }
        let entries = workers.map {
            MeshWorkerRegistryPayload.WorkerEntry(nodeName: $0.nodeName, baseURL: $0.baseURL, listenPort: $0.listenPort)
        }
        let payload = MeshWorkerRegistryPayload(workers: entries, leaderTerm: leaderTerm)
        for worker in workers {
            await syncToNode(worker, path: "/v1/mesh/sync/worker-registry", payload: payload)
        }
    }

    func pushSyncPayloadToNodes(_ payload: MeshSyncPayload) async {
        guard mode == .leader else { return }
        let workers = Array(registeredWorkers.values)
        guard !workers.isEmpty else { return }
        for worker in workers {
            await syncToNode(worker, path: "/v1/mesh/sync/conversations", payload: payload)
        }
    }

    /// Push an incremental batch to a single node and return whether the delivery succeeded.
    @discardableResult
    func pushConversationsToSingleNode(_ baseURL: String, _ payload: MeshSyncPayload) async -> Bool {
        guard mode == .leader else { return false }
        guard let worker = registeredWorkers[baseURL.lowercased()] else { return false }
        guard let url = URL(string: worker.baseURL + "/v1/mesh/sync/conversations") else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/v1/mesh/sync/conversations")
            request.timeoutInterval = 10
            let (data, response) = try await meshSession.data(for: request)
            await detectStaleSelfFromResponse(data: data, response: response)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            return true
        } catch {
            return false
        }
    }

    private func syncToNode<T: Codable>(_ worker: RegisteredWorker, path: String, payload: T) async {
        guard let url = URL(string: worker.baseURL + path) else { return }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: path)
            request.timeoutInterval = 10
            let (data, response) = try await meshSession.data(for: request)
            await detectStaleSelfFromResponse(data: data, response: response)
        } catch {
            // best effort
        }
    }

    func updateLeaderTerm(_ newTerm: Int) async {
        guard newTerm > leaderTerm else { return }
        meshLogger.notice("Adopting higher leader term \(newTerm, privacy: .public) from peer (was \(self.leaderTerm, privacy: .public))")
        leaderTerm = newTerm
        snapshot.leaderTerm = leaderTerm
        await publishSnapshot()
        await onTermChanged?(leaderTerm)
    }

    /// Split-brain backstop: if a peer rejects our request with a
    /// StaleTermResponse carrying a term higher than ours, we adopt it.
    /// If we were leader, we must also demote.
    private func detectStaleSelfFromResponse(data: Data, response: URLResponse) async {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 409,
              let stale = try? decoder.decode(StaleTermResponse.self, from: data),
              stale.currentTerm > leaderTerm else { return }

        if mode == .leader {
            meshLogger.critical("Detected higher term \(stale.currentTerm, privacy: .public) from peer (was \(self.leaderTerm, privacy: .public)) — demoting self to standby")
            await demoteToStandby(observedTerm: stale.currentTerm, newLeaderAddress: stale.currentLeaderAddress)
        } else {
            await updateLeaderTerm(stale.currentTerm)
        }
    }

    /// Step the leader down to standby after detecting a higher-term peer.
    /// Adopts the peer's term so we don't immediately attempt to promote again,
    /// then restarts standby monitoring against the new leader address (if any).
    private func demoteToStandby(observedTerm: Int, newLeaderAddress: String?) async {
        guard mode == .leader else { return }

        // Cancel any in-flight handover test task before demoting.
        handoverTestTask?.cancel()
        handoverTestTask = nil

        // Surface in-flight demotion before we start tearing down Primary state.
        snapshot.runtimeState = .demoting
        await publishSnapshot()

        mode = .standby
        leaderTerm = observedTerm
        if let addr = newLeaderAddress, !addr.isEmpty {
            leaderAddress = addr
        }
        snapshot.mode = .standby
        snapshot.leaderTerm = leaderTerm
        snapshot.leaderAddress = leaderAddress
        snapshot.workerState = .starting
        snapshot.workerStatusText = "Demoted — another Primary holds a higher term"
        snapshot.diagnostics = "Demoted to Standby (peer term \(observedTerm))"
        await publishSnapshot()
        await onTermChanged?(leaderTerm)
        // Mute Discord output and restore passive-standby semantics in AppModel.
        await onDemotion?()
        await restartStandbyMonitorIfNeeded()
        await restartWorkerRegistrationIfNeeded()
        await restartServerIfNeeded()
        // No longer primary — stop polling follower state and clear the published map.
        followerStatePollTask?.cancel()
        _ = await followerStatePollTask?.value
        followerStatePollTask = nil
        followerStates.removeAll()
        snapshot.followerStates = [:]

        // Demotion complete — runtime state settles back to idle.
        snapshot.runtimeState = .idle
        await publishSnapshot()
    }

    /// Build a JSON body for a 409 Conflict response that carries our current
    /// term so a peer (former leader) can detect its staleness and demote.
    private func staleTermResponseBody(reason: String) -> Data {
        let body = StaleTermResponse(
            error: reason,
            currentTerm: leaderTerm,
            currentLeaderAddress: mode == .leader ? localWorkerAdvertisedBaseURL() : leaderAddress
        )
        return (try? encoder.encode(body)) ?? Data(#"{"error":"\#(reason)"}"#.utf8)
    }

    private func restartWorkerRegistrationIfNeeded() async {
        workerRegistrationTask?.cancel()
        _ = await workerRegistrationTask?.value
        workerRegistrationTask = nil

        guard mode == .worker || mode == .standby else { return }
        guard let normalizedLeader = normalizedBaseURL(leaderAddress, defaultPort: leaderPort), !normalizedLeader.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "Primary not configured"
            snapshot.diagnostics = "Set Primary Address to enable registration"
            return
        }

        meshLogger.debug("Starting worker registration to \(normalizedLeader, privacy: .public)")
        workerRegistrationTask = Task {
            while !Task.isCancelled {
                await registerWithLeader(normalizedLeader)
                try? await Task.sleep(nanoseconds: workerRegistrationIntervalNanoseconds)
            }
            meshLogger.debug("Worker registration task exited")
        }
    }

    private func registerWithLeader(_ leaderBaseURL: String) async {
        guard mode == .worker || mode == .standby else { return }
        guard let url = URL(string: leaderBaseURL + "/cluster/register") else {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Invalid Primary address"
            snapshot.diagnostics = "Invalid registration URL: \(leaderBaseURL)"
            await publishSnapshot()
            return
        }

        let payload = WorkerRegistrationRequest(
            nodeName: nodeName,
            baseURL: localWorkerAdvertisedBaseURL(),
            listenPort: listenPort
        )

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(payload)
            applyMeshAuth(to: &request, path: "/cluster/register")
            request.timeoutInterval = 3
            let authMode = sharedSecret.isEmpty ? "none" : "HMAC"
            snapshot.diagnostics = "Registering with Primary: POST \(describeEndpoint(url)) auth=\(authMode) node=\(nodeName) listenPort=\(listenPort)"
            await publishSnapshot()
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                snapshot.workerState = .degraded
                snapshot.workerStatusText = "Registration failed (\(code))"
                let bodySnippet = String(data: data, encoding: .utf8)?
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
                snapshot.diagnostics = "Registration failed: POST \(describeEndpoint(url)) status=\(code) body=\(String(bodySnippet.prefix(180)))"
                await publishSnapshot()
                return
            }

            let ack = try? decoder.decode(WorkerRegistrationResponse.self, from: data)
            snapshot.workerState = .connected
            snapshot.workerStatusText = mode == .standby ? "Standby Registered with Primary" : "Worker Registered with Primary"
            if let ack {
                currentLeaderNodeName = ack.leaderNodeName
                snapshot.diagnostics = "\(mode == .standby ? "Standby" : "Worker") registered with Primary \(ack.leaderNodeName) (\(ack.registeredWorkers) nodes total)"
            } else {
                snapshot.diagnostics = "\(mode == .standby ? "Standby" : "Worker") registered with Primary via \(url.absoluteString)"
            }
            await publishSnapshot()

            // Auto-pull Discord token after a successful handshake. AppModel
            // sets onDiscordTokenFetched only when the local node has no
            // token; the helper is a no-op otherwise. Failure is silent —
            // the next registration cycle (every ~4s) will retry.
            await pullDiscordTokenFromLeaderIfNeeded(leaderBaseURL: leaderBaseURL)
            await runInitialSyncAfterRegistrationIfNeeded(leaderBaseURL: leaderBaseURL)
        } catch {
            snapshot.workerState = .failed
            snapshot.workerStatusText = "Primary unavailable"
            if let urlError = error as? URLError {
                snapshot.diagnostics = "Registration request failed: POST \(describeEndpoint(url)) urlError=\(urlError.code.rawValue) reason=\(urlError.localizedDescription)"
            } else {
                snapshot.diagnostics = "Registration request failed: POST \(describeEndpoint(url)) reason=\(error.localizedDescription)"
            }
            await publishSnapshot()
        }
    }

    private func runInitialSyncAfterRegistrationIfNeeded(leaderBaseURL: String) async {
        let key = leaderBaseURL.lowercased()
        guard initialSyncCompletedLeaderBaseURL != key else { return }
        initialSyncCompletedLeaderBaseURL = key
        await onLeaderRegistrationSyncNeeded?(leaderBaseURL)
    }

    private func handleWorkerRegistration(_ body: Data, remoteHost: String?) async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "leader_mode_required"))
        }

        guard let registration = try? decoder.decode(WorkerRegistrationRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_registration"}"#.utf8))
        }
        let advertisedBaseURL = normalizedBaseURL(registration.baseURL)
        let observedBaseURL = observedRegistrationBaseURL(remoteHost: remoteHost, listenPort: registration.listenPort)
        guard let baseURL = observedBaseURL ?? advertisedBaseURL, !baseURL.isEmpty else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_registration"}"#.utf8))
        }

        let workerName = registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Worker"
            : registration.nodeName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Keep one registration per node name to avoid duplicate stale entries
        // when public/private endpoints for the same standby vary over time.
        registeredWorkers = registeredWorkers.filter { $0.value.nodeName.lowercased() != workerName.lowercased() }

        let key = baseURL.lowercased()
        let isNewRegistration = registeredWorkers[key] == nil
        let entry = RegisteredWorker(
            nodeName: workerName,
            baseURL: baseURL,
            listenPort: registration.listenPort,
            lastSeen: Date()
        )
        registeredWorkers[key] = entry
        everKnownWorkers[key] = entry
        pruneStaleRegistrations()

        let workerCount = registeredWorkers.count
        // Only refresh the snapshot on a *new* registration. The Failover
        // re-registers every 4 s — left untouched, that fights with the
        // periodic clusterStatusPayload() poll (every ~3 s), producing a
        // visible flicker in the GUI.
        if isNewRegistration {
            snapshot.workerState = .connected
            snapshot.workerStatusText = "\(workerCount) worker\(workerCount == 1 ? "" : "s") registered"
            if let advertisedBaseURL,
               let observedBaseURL,
               advertisedBaseURL.lowercased() != observedBaseURL.lowercased() {
                snapshot.diagnostics = "Worker \(workerName) registered from \(baseURL) (advertised \(advertisedBaseURL))"
            } else {
                snapshot.diagnostics = "Worker \(workerName) registered from \(baseURL)"
            }
            await publishSnapshot()
        }

        let response = WorkerRegistrationResponse(
            status: "ok",
            leaderNodeName: nodeName,
            registeredWorkers: workerCount
        )
        let payload = (try? encoder.encode(response)) ?? Data()
        return httpResponse(status: "200 OK", body: payload)
    }

    private func observedRegistrationBaseURL(remoteHost: String?, listenPort: Int) -> String? {
        guard let remoteHost = remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines),
              !remoteHost.isEmpty,
              (1...Int(UInt16.max)).contains(listenPort) else { return nil }
        let hostLiteral = remoteHost.contains(":") && !remoteHost.hasPrefix("[")
            ? "[\(remoteHost)]"
            : remoteHost
        return normalizedBaseURL("http://\(hostLiteral):\(listenPort)")
    }

    private func sortedRegisteredWorkers() -> [RegisteredWorker] {
        registeredWorkers.values
            .filter { !isSelfClusterEndpoint($0.baseURL) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    private func pruneStaleRegistrations() {
        let cutoff = Date().addingTimeInterval(-registrationStaleAfter)
        registeredWorkers = registeredWorkers.filter { $0.value.lastSeen >= cutoff }
    }

    private func touchRegisteredWorker(baseURL: String) {
        let key = baseURL.lowercased()
        guard var worker = registeredWorkers[key] else { return }
        worker.lastSeen = Date()
        registeredWorkers[key] = worker
    }

    private func localWorkerAdvertisedBaseURL() -> String {
        let host = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        return "http://\(resolvedHost):\(listenPort)"
    }

    func normalizedBaseURL(_ raw: String, defaultPort: Int? = nil) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hadExplicitScheme = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://")
        let candidate: String
        if hadExplicitScheme {
            candidate = trimmed
        } else {
            candidate = "http://\(trimmed)"
        }
        guard let url = URL(string: candidate),
              let scheme = url.scheme,
              let host = url.host,
              !scheme.isEmpty,
              !host.isEmpty else {
            return nil
        }

        // Mesh host guard: allow internet peers while still blocking obvious unsafe targets.
        if !isSSRFSafeHost(host) {
            return nil
        }

        // For host-only input (no scheme), require an explicit port (or defaultPort)
        // to avoid silently targeting the wrong endpoint.
        if !hadExplicitScheme, url.port == nil, defaultPort == nil {
            return nil
        }
        let resolvedPort: Int = {
            if let explicit = url.port { return explicit }
            if let def = defaultPort { return def }
            if scheme.lowercased() == "https" { return 443 }
            return 80
        }()
        return "\(scheme)://\(host):\(resolvedPort)"
    }

    func isSSRFSafeHost(_ host: String) -> Bool {
        let lowerHost = host.lowercased()
        if lowerHost == "localhost" || lowerHost == "127.0.0.1" || lowerHost == "::1" {
            return true
        }

        // Deny wildcard/unspecified endpoints.
        if lowerHost == "0.0.0.0" || lowerHost == "::" {
            return false
        }

        // Deny cloud metadata and link-local ranges.
        if lowerHost == "169.254.169.254"
            || lowerHost.hasPrefix("169.254.")
            || lowerHost == "metadata.google.internal" {
            return false
        }

        // Allow private LAN, public internet, and mDNS hosts.
        return true
    }

    private func isWorkerReachable(_ baseURL: String, timeout: TimeInterval = 5) async -> Bool {
        guard let url = URL(string: baseURL + "/health") else { return false }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/health")
            request.timeoutInterval = timeout
            let (_, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func describeEndpoint(_ url: URL) -> String {
        let scheme = url.scheme ?? "http"
        let host = url.host ?? "-"
        let port = url.port ?? (scheme.lowercased() == "https" ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path
        return "\(scheme.uppercased()) \(host):\(port)\(path)"
    }

    private func performRemoteAI(_ job: AIJobRequest) async -> AIJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote AI"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/ai-reply") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(job)
                applyMeshAuth(to: &request, path: "/v1/ai-reply")
                let (data, response) = try await meshSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(AIJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote AI available"
                snapshot.diagnostics = "Remote AI succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote AI unavailable"
        snapshot.diagnostics = "Remote AI failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func performRemoteWikiLookup(query: String, source: WikiSource) async -> WikiJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote wiki lookup"
            await publishSnapshot()
            return nil
        }

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/wiki-lookup") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(WikiJobRequest(query: query, source: source))
                applyMeshAuth(to: &request, path: "/v1/wiki-lookup")
                let (data, response) = try await meshSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(WikiJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote wiki available"
                snapshot.diagnostics = "Remote wiki succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote wiki unavailable"
        snapshot.diagnostics = "Remote wiki failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func performRemotePlaylistImport(playlistURL: URL, limit: Int) async -> PlaylistImportJobResponse? {
        let workers = sortedRegisteredWorkers()
        guard !workers.isEmpty else {
            snapshot.workerState = .inactive
            snapshot.workerStatusText = "No workers registered"
            snapshot.diagnostics = "No registered workers available for remote playlist import"
            await publishSnapshot()
            return nil
        }

        let job = PlaylistImportJobRequest(
            playlistURL: playlistURL.absoluteString,
            limit: max(1, min(limit, 100))
        )

        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/playlist-import") else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try encoder.encode(job)
                applyMeshAuth(to: &request, path: "/v1/playlist-import")
                let (data, response) = try await meshSession.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continue
                }

                let decoded = try decoder.decode(PlaylistImportJobResponse.self, from: data)
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Remote playlist import available"
                snapshot.diagnostics = "Remote playlist import succeeded via \(url.absoluteString)"
                await publishSnapshot()
                return decoded
            } catch {
                continue
            }
        }

        snapshot.workerState = .failed
        snapshot.workerStatusText = "Remote playlist import unavailable"
        snapshot.diagnostics = "Remote playlist import failed for all registered workers"
        await publishSnapshot()
        return nil
    }

    private func clusterStatusPayload() async -> ClusterStatusResponse {
        var nodes: [ClusterNodeStatus] = [localNodeStatus()]

        if mode == .leader {
            pruneStaleRegistrations()
            // Emit from the sticky `everKnownWorkers` cache rather than the
            // active `registeredWorkers` map so a node that briefly drops out
            // (re-register heartbeat missed, network blip, restart) keeps its
            // tile in the cluster map with a disconnected state, instead of
            // vanishing entirely.
            let knownWorkers = everKnownWorkers.values
                .filter { !isSelfClusterEndpoint($0.baseURL) }
                .sorted { $0.lastSeen > $1.lastSeen }
            var reachable = 0
            for worker in knownWorkers {
                let age = Date().timeIntervalSince(worker.lastSeen)
                let recentlySeen = age <= registrationStaleAfter
                if recentlySeen { reachable += 1 }
                let status: ClusterNodeHealthStatus
                if !recentlySeen {
                    status = .disconnected
                } else if age <= (registrationStaleAfter / 2) {
                    status = .healthy
                } else {
                    status = .degraded
                }
                nodes.append(unreachableWorkerNode(worker: worker, status: status))
            }

            // Compute the status text/diagnostics first, only write if changed.
            // This is the second half of the flicker fix — the registration
            // path is now one-shot (commit 2b25100) but the poll path was
            // still rewriting the same fields every ~3 s with subtly
            // different wording compared to the registration handler.
            let nextState: ClusterConnectionState
            let nextText: String
            let nextDiagnostics: String?
            if knownWorkers.isEmpty {
                nextState = .inactive
                nextText = "No workers registered"
                nextDiagnostics = "Waiting for worker registrations via /cluster/register"
            } else if reachable == knownWorkers.count {
                nextState = .connected
                nextText = "\(reachable) worker\(reachable == 1 ? "" : "s") registered"
                // Leave the diagnostics line alone — the registration path
                // already wrote a richer "Worker X registered from Y" message.
                nextDiagnostics = nil
            } else if reachable > 0 {
                nextState = .degraded
                nextText = "\(reachable)/\(knownWorkers.count) workers registered"
                nextDiagnostics = "Some known workers haven't re-registered in the last \(Int(registrationStaleAfter))s"
            } else {
                nextState = .failed
                nextText = "Cluster status unavailable"
                nextDiagnostics = "No worker has re-registered in the last \(Int(registrationStaleAfter))s"
            }
            if snapshot.workerState != nextState { snapshot.workerState = nextState }
            if snapshot.workerStatusText != nextText { snapshot.workerStatusText = nextText }
            if let nextDiagnostics, snapshot.diagnostics != nextDiagnostics {
                snapshot.diagnostics = nextDiagnostics
            }
        }

        if mode == .standby,
           let leaderBaseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort),
           !leaderBaseURL.isEmpty,
           !isSelfClusterEndpoint(leaderBaseURL) {
            if let remoteStatus = await fetchRemoteClusterStatus(baseURL: leaderBaseURL) {
                var leaderFound = false
                for var node in remoteStatus.response.nodes where !nodes.contains(where: { $0.id == node.id }) {
                    if node.role == .leader {
                        node.latencyMs = remoteStatus.latencyMs
                        leaderFound = true
                    }
                    nodes.append(node)
                }
                if !leaderFound {
                    let host = URL(string: leaderBaseURL)?.host ?? "Primary"
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
                            latencyMs: remoteStatus.latencyMs,
                            status: .healthy,
                            jobsActive: 0
                        )
                    )
                }
                snapshot.workerState = .connected
                snapshot.workerStatusText = "Primary reachable"
                snapshot.diagnostics = "Fail Over monitoring \(leaderBaseURL) (latency \(Int(remoteStatus.latencyMs)) ms)"
            } else {
                // Fallback: if /cluster/status is unavailable (or incompatible), use /cluster/ping.
                if let pingLatencyMs = await fetchRemoteLeaderPing(baseURL: leaderBaseURL) {
                    let host = URL(string: leaderBaseURL)?.host ?? "Primary"
                    if !nodes.contains(where: { $0.role == .leader }) {
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
                                latencyMs: pingLatencyMs,
                                status: .healthy,
                                jobsActive: 0
                            )
                        )
                    }
                    snapshot.workerState = .connected
                    snapshot.workerStatusText = "Primary reachable (ping)"
                    snapshot.diagnostics = "Fail Over /cluster/status unavailable; /cluster/ping OK (\(Int(pingLatencyMs)) ms)"
                } else {
                    snapshot.workerState = .degraded
                    snapshot.workerStatusText = "Primary unreachable"
                    snapshot.diagnostics = "Fail Over could not fetch \(leaderBaseURL)/cluster/status"
                }
            }
        }

        return ClusterStatusResponse(
            mode: mode,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            nodes: deduplicateClusterNodes(nodes)
        )
    }

    private func deduplicateClusterNodes(_ nodes: [ClusterNodeStatus]) -> [ClusterNodeStatus] {
        var byKey: [String: ClusterNodeStatus] = [:]
        for node in nodes {
            let roleKey = node.role.rawValue
            let nameKey = node.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let key = "\(roleKey)|\(nameKey)"
            if let existing = byKey[key] {
                byKey[key] = preferredNode(existing, node)
            } else {
                byKey[key] = node
            }
        }
        return byKey.values.sorted {
            if $0.role != $1.role { return $0.role.rawValue < $1.role.rawValue }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func preferredNode(_ lhs: ClusterNodeStatus, _ rhs: ClusterNodeStatus) -> ClusterNodeStatus {
        let lhsScore = nodeStatusScore(lhs.status)
        let rhsScore = nodeStatusScore(rhs.status)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore ? lhs : rhs
        }
        if let l = lhs.latencyMs, let r = rhs.latencyMs, l != r {
            return l <= r ? lhs : rhs
        }
        if lhs.latencyMs != nil, rhs.latencyMs == nil { return lhs }
        if rhs.latencyMs != nil, lhs.latencyMs == nil { return rhs }
        if lhs.jobsActive != rhs.jobsActive {
            return lhs.jobsActive >= rhs.jobsActive ? lhs : rhs
        }
        return lhs
    }

    private func nodeStatusScore(_ status: ClusterNodeHealthStatus) -> Int {
        switch status {
        case .healthy: return 3
        case .degraded: return 2
        case .disconnected: return 1
        }
    }

    private func localNodeStatus() -> ClusterNodeStatus {
        let hostname = ProcessInfo.processInfo.hostName
        let role: ClusterNodeRole
        switch mode {
        case .leader:   role = .leader
        case .standby:  role = .standby
        default:        role = .worker
        }
        let uptime = max(0, Date().timeIntervalSince(startedAt))
        let status = snapshot.serverState.nodeHealthStatus

        return ClusterNodeStatus(
            id: "\(role.rawValue)-\(hostname.lowercased())-\(listenPort)",
            hostname: hostname,
            displayName: nodeName,
            role: role,
            hardwareModel: hardwareInfo.modelIdentifier,
            cpu: currentCPUPercent(),
            mem: currentMemoryPercent(),
            cpuName: hardwareInfo.cpuName,
            physicalMemoryBytes: hardwareInfo.physicalMemoryBytes,
            uptime: uptime,
            latencyMs: nil,
            status: status,
            jobsActive: activeJobs
        )
    }

    private func unreachableWorkerNode(worker: RegisteredWorker, status: ClusterNodeHealthStatus = .disconnected) -> ClusterNodeStatus {
        let host = URL(string: worker.baseURL)?.host ?? worker.nodeName
        // If we have a fresh follower-state report from this peer, surface its
        // runtime role (standby vs worker) instead of always emitting `.worker`.
        // Without this, a registered Standby would show up as "worker" in the
        // Primary-side cluster table even though we know better.
        let followerRole: ClusterNodeRole = {
            guard let state = followerStates[worker.baseURL.lowercased()] else { return .worker }
            return state.mode.caseInsensitiveCompare("standby") == .orderedSame ? .standby : .worker
        }()

        return ClusterNodeStatus(
            id: "\(followerRole.rawValue)-\(host.lowercased())-\(worker.listenPort)",
            hostname: host,
            displayName: worker.nodeName,
            role: followerRole,
            hardwareModel: "Unknown",
            cpu: 0,
            mem: 0,
            cpuName: "Unknown CPU",
            physicalMemoryBytes: 0,
            uptime: 0,
            latencyMs: nil,
            status: status,
            jobsActive: 0
        )
    }

    private func fetchRemoteClusterStatus(baseURL: String) async -> (response: ClusterStatusResponse, latencyMs: Double)? {
        guard let url = URL(string: baseURL + "/cluster/status") else {
            return nil
        }

        do {
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/cluster/status")
            request.timeoutInterval = 3
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }

            let decoded = try decoder.decode(ClusterStatusResponse.self, from: data)
            let latencyMs = max(0, Date().timeIntervalSince(started) * 1000)
            return (decoded, latencyMs)
        } catch {
            return nil
        }
    }

    private func fetchRemoteLeaderPing(baseURL: String) async -> Double? {
        guard let url = URL(string: baseURL + "/cluster/ping") else {
            return nil
        }

        do {
            let started = Date()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/cluster/ping")
            request.timeoutInterval = 3
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            if let payload = try? decoder.decode(ClusterPingResponse.self, from: data) {
                guard payload.status.caseInsensitiveCompare("ok") == .orderedSame,
                      payload.role.caseInsensitiveCompare("leader") == .orderedSame else {
                    return nil
                }
            }
            return max(0, Date().timeIntervalSince(started) * 1000)
        } catch {
            return nil
        }
    }

    private func currentCPUPercent() -> Double {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuInfo) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(cpuInfo.cpu_ticks.0)
        let system = Double(cpuInfo.cpu_ticks.1)
        let idle = Double(cpuInfo.cpu_ticks.2)
        let nice = Double(cpuInfo.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, (used / total) * 100))
    }

    private func currentMemoryPercent() -> Double {
        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vmStats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        let usedPages = Double(vmStats.active_count)
            + Double(vmStats.inactive_count)
            + Double(vmStats.wire_count)
            + Double(vmStats.compressor_page_count)
        let pageSize = getpagesize()
        let usedBytes = usedPages * Double(pageSize)
        let totalBytes = Double(ProcessInfo.processInfo.physicalMemory)
        guard totalBytes > 0 else { return 0 }
        return min(100, max(0, (usedBytes / totalBytes) * 100))
    }

    private func isSelfClusterEndpoint(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL),
              let host = url.host?.lowercased() else {
            return false
        }

        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let localHosts = Set([
            "127.0.0.1",
            "localhost",
            "::1",
            ProcessInfo.processInfo.hostName.lowercased(),
            Host.current().name?.lowercased(),
            Host.current().localizedName?.replacingOccurrences(of: " ", with: "-").lowercased()
        ].compactMap { $0 })

        return localHosts.contains(host) && port == listenPort
    }

    func publishSnapshot() async {
        await onSnapshot?(snapshot)
    }

    private func recordJobLog(
        user: String,
        server: String,
        command: String,
        channel: String,
        executionRoute: String,
        ok: Bool
    ) async {
        let entry = CommandLogEntry(
            time: Date(),
            user: user,
            server: server,
            command: command,
            channel: channel,
            executionRoute: executionRoute,
            executionNode: nodeName,
            ok: ok
        )
        await onJobLog?(entry)
    }

    private func decodeWikiJobRequest(from data: Data) -> WikiJobRequest? {
        if let request = try? decoder.decode(WikiJobRequest.self, from: data) {
            return request
        }
        if let legacy = try? decoder.decode(LegacyWikiJobRequest.self, from: data) {
            return WikiJobRequest(query: legacy.query, source: .defaultFinals())
        }
        return nil
    }

    private func handleMeshLeaderChanged(_ body: Data) async -> Data {
        guard let payload = try? decoder.decode(MeshLeaderChangedPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        // Split-brain guard: reject stale or equal terms. Include our higher
        // term so the requester can detect it is no longer authoritative.
        guard payload.term > leaderTerm else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "stale_term"))
        }

        leaderTerm = payload.term
        leaderAddress = payload.leaderAddress
        initialSyncCompletedLeaderBaseURL = nil
        snapshot.leaderTerm = leaderTerm
        snapshot.leaderAddress = leaderAddress
        snapshot.diagnostics = "Primary changed to \(payload.leaderNodeName) at \(payload.leaderAddress) (term \(leaderTerm))"
        snapshot.workerState = .starting
        snapshot.workerStatusText = "Re-registering with new Primary"
        await publishSnapshot()
        await onTermChanged?(leaderTerm)

        // Phase 3 fix: re-register against the new primary for both worker AND
        // standby modes (previously only `.worker` was handled). Without this,
        // a former primary that demoted to standby would never re-register
        // with the new primary, the new primary would never push sync to it,
        // and the local GUI would show no live activity from the failover node.
        // Also restart the standby health monitor so it watches the *new*
        // primary, not the dead one.
        if mode == .worker || mode == .standby {
            await restartWorkerRegistrationIfNeeded()
        }
        if mode == .standby {
            await restartStandbyMonitorIfNeeded()
        }

        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Leader: return registered workers list for standby to replicate.
    private func handleMeshWorkersRequest() -> Data {
        let entries = sortedRegisteredWorkers().map {
            MeshWorkerRegistryPayload.WorkerEntry(nodeName: $0.nodeName, baseURL: $0.baseURL, listenPort: $0.listenPort)
        }
        let payload = MeshWorkerRegistryPayload(workers: entries, leaderTerm: leaderTerm)
        let body = (try? encoder.encode(payload)) ?? Data()
        return httpResponse(status: "200 OK", body: body)
    }

    private func handleMeshWorkerRegistrySync(_ body: Data) async -> Data {
        guard mode == .standby else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "standby_mode_required"))
        }

        guard let payload = try? decoder.decode(MeshWorkerRegistryPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard payload.leaderTerm >= leaderTerm else {
            meshLogger.warning("Worker registry sync rejected: stale term \(payload.leaderTerm, privacy: .public) < current \(self.leaderTerm, privacy: .public)")
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "stale_term"))
        }

        for worker in payload.workers {
            let key = worker.baseURL.lowercased()
            registeredWorkers[key] = RegisteredWorker(
                nodeName: worker.nodeName,
                baseURL: worker.baseURL,
                listenPort: worker.listenPort,
                lastSeen: Date()
            )
        }

        snapshot.diagnostics = "Synced worker registry (\(payload.workers.count) workers)"
        await publishSnapshot()

        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    private func handleMeshConversationSync(_ body: Data) async -> Data {
        guard mode == .standby else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "standby_mode_required"))
        }
        guard let payload = try? decoder.decode(MeshSyncPayload.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard payload.leaderTerm >= leaderTerm else {
            meshLogger.warning("Conversation sync rejected: stale term \(payload.leaderTerm, privacy: .public) < current \(self.leaderTerm, privacy: .public)")
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "stale_term"))
        }
        await onSync?(payload)
        return httpResponse(status: "200 OK", body: Data(#"{"status":"ok"}"#.utf8))
    }

    /// Phase 3: every node serves its own current state at this endpoint so
    /// the primary can poll and surface follower activity in the GUI.
    private func handleFollowerStateRequest() async -> Data {
        guard let provider = followerStateProvider else {
            return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"provider_unavailable"}"#.utf8))
        }
        let summary = await provider()
        let body = (try? encoder.encode(summary)) ?? Data()
        return httpResponse(status: "200 OK", body: body)
    }

    /// Primary-side polling: fetch /v1/mesh/follower-state from each registered
    /// worker and stash the result in `followerStates`, then publish snapshot.
    /// Started by `restartFollowerStatePollIfNeeded()`; quiet on non-leaders.
    private func pollFollowerStates() async {
        guard mode == .leader else { return }
        let workers = sortedRegisteredWorkers()
        if workers.isEmpty {
            if !followerStates.isEmpty {
                followerStates.removeAll()
                snapshot.followerStates = [:]
                await publishSnapshot()
            }
            return
        }
        var refreshed: [String: FollowerStateSummary] = [:]
        for worker in workers {
            guard let url = URL(string: worker.baseURL + "/v1/mesh/follower-state") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/v1/mesh/follower-state")
            request.timeoutInterval = 4
            do {
                let (data, response) = try await meshSession.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                if let summary = try? decoder.decode(FollowerStateSummary.self, from: data) {
                    refreshed[worker.baseURL.lowercased()] = summary
                }
            } catch {
                // best effort: missing follower keeps its previous entry until
                // the worker registry prunes it as stale.
                if let previous = followerStates[worker.baseURL.lowercased()] {
                    refreshed[worker.baseURL.lowercased()] = previous
                }
            }
        }
        followerStates = refreshed
        snapshot.followerStates = refreshed
        await publishSnapshot()
    }

    private func restartFollowerStatePollIfNeeded() async {
        followerStatePollTask?.cancel()
        _ = await followerStatePollTask?.value
        followerStatePollTask = nil
        guard mode == .leader else { return }
        meshLogger.debug("Starting follower state poll")
        followerStatePollTask = Task {
            while !Task.isCancelled {
                await pollFollowerStates()
                try? await Task.sleep(nanoseconds: followerStatePollIntervalNanoseconds)
            }
            meshLogger.debug("Follower state poll exited")
        }
    }

    /// Leader handles a standby/worker resync request: return bounded page from the requested cursor.
    private func handleMeshConversationResync(_ body: Data) async -> Data {
        guard mode == .leader else {
            return httpResponse(status: "409 Conflict", body: staleTermResponseBody(reason: "leader_mode_required"))
        }
        guard let req = try? decoder.decode(MeshResyncRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        guard let fetcher = conversationFetcher else {
            return httpResponse(status: "503 Service Unavailable", body: Data(#"{"error":"fetcher_unavailable"}"#.utf8))
        }

        let limit = min(max(1, req.pageSize), Self.maxSyncBatchSize)
        let (records, hasMore) = await fetcher(req.fromRecordID, limit)
        let lastID = records.last?.id

        // Also fetch current image usage if this is the last page (or just always for simplicity)
        let imageUsage = await meshHandler?("image-usage")
        let decodedUsage = imageUsage.flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) }

        let payload = MeshSyncPayload(
            conversations: records,
            imageUsage: decodedUsage,
            leaderTerm: leaderTerm,
            cursorRecordID: lastID,
            hasMore: hasMore,
            fromCursorRecordID: req.fromRecordID
        )
        guard let body = try? encoder.encode(payload) else {
            return httpResponse(status: "500 Internal Server Error", body: Data(#"{"error":"encode_failed"}"#.utf8))
        }
        return httpResponse(status: "200 OK", body: body)
    }

    private func handleMeshWikiCacheSync() async -> Data {
        if let data = await meshHandler?("wiki-cache") {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "404 Not Found", body: Data(#"{"error":"cache_unavailable"}"#.utf8))
    }

    private func handleMeshConfigFilesSync() async -> Data {
        if let data = await meshHandler?("config-files") {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "404 Not Found", body: Data(#"{"error":"config_unavailable"}"#.utf8))
    }

    private func handleMediaLibraryRequest() async -> Data {
        guard let provider = mediaLibraryProvider else {
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"media_unavailable"}"#.utf8))
        }
        guard let body = try? encoder.encode(await provider()) else {
            return httpResponse(status: "500 Internal Server Error", body: Data(#"{"error":"encode_failed"}"#.utf8))
        }
        return httpResponse(status: "200 OK", body: body)
    }

    private func handleMediaStreamRequest(itemID: String, rangeHeader: String?) async -> Data {
        guard let response = await mediaStreamHandler?(itemID, rangeHeader) else {
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"media_not_found"}"#.utf8))
        }
        return httpResponse(
            status: response.status,
            body: response.body,
            contentType: response.contentType,
            headers: response.headers
        )
    }

    private func handleMediaThumbnailRequest(itemID: String) async -> Data {
        guard let response = await mediaThumbnailHandler?(itemID, nil) else {
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"thumbnail_not_found"}"#.utf8))
        }
        return httpResponse(
            status: response.status,
            body: response.body,
            contentType: response.contentType,
            headers: response.headers
        )
    }

    private func handleMediaFrameRequest(itemID: String, seconds: Double) async -> Data {
        guard let response = await mediaFrameHandler?(itemID, seconds) else {
            return httpResponse(status: "404 Not Found", body: Data(#"{"error":"frame_not_found"}"#.utf8))
        }
        return httpResponse(
            status: response.status,
            body: response.body,
            contentType: response.contentType,
            headers: response.headers
        )
    }

    private func handleMediaClipRequest(_ body: Data) async -> Data {
        guard let handler = mediaClipHandler,
              let request = try? decoder.decode(MeshMediaClipRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        if let job = await handler(request),
           let data = try? encoder.encode(job) {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "500 Internal Server Error", body: Data(#"{"error":"export_failed"}"#.utf8))
    }

    private func handleMediaMultiViewRequest(_ body: Data) async -> Data {
        guard let handler = mediaMultiViewHandler,
              let request = try? decoder.decode(MeshMediaMultiViewRequest.self, from: body) else {
            return httpResponse(status: "400 Bad Request", body: Data(#"{"error":"invalid_payload"}"#.utf8))
        }
        if let job = await handler(request),
           let data = try? encoder.encode(job) {
            return httpResponse(status: "200 OK", body: data)
        }
        return httpResponse(status: "500 Internal Server Error", body: Data(#"{"error":"export_failed"}"#.utf8))
    }

    /// Standby: fetch one page of conversation records from the leader using correct HMAC auth.
    func fetchResyncPage(fromRecordID: String?, pageSize: Int) async -> MeshSyncPayload? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/conversations/resync") else { return nil }
        let req = MeshResyncRequest(fromRecordID: fromRecordID, pageSize: pageSize)
        guard let body = try? encoder.encode(req) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/conversations/resync")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try? decoder.decode(MeshSyncPayload.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchRemoteMediaLibrary(from baseURL: String) async -> MediaLibraryPayload? {
        guard let url = URL(string: baseURL + "/v1/media/library") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/v1/media/library")
            request.timeoutInterval = 8
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try? decoder.decode(MediaLibraryPayload.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchRemoteMediaStream(from baseURL: String, itemID: String, rangeHeader: String?) async -> BinaryHTTPResponse? {
        if let response = await fetchRemoteMediaStreamAttempt(from: baseURL, itemID: itemID, rangeHeader: rangeHeader) {
            return response
        }
        guard let fallback = alternateSchemeBaseURL(baseURL) else { return nil }
        return await fetchRemoteMediaStreamAttempt(from: fallback, itemID: itemID, rangeHeader: rangeHeader)
    }

    func fetchRemoteMediaThumbnail(from baseURL: String, itemID: String) async -> BinaryHTTPResponse? {
        if let response = await fetchRemoteMediaThumbnailAttempt(from: baseURL, itemID: itemID) {
            return response
        }
        guard let fallback = alternateSchemeBaseURL(baseURL) else { return nil }
        return await fetchRemoteMediaThumbnailAttempt(from: fallback, itemID: itemID)
    }

    func fetchRemoteMediaFrame(from baseURL: String, itemID: String, seconds: Double) async -> BinaryHTTPResponse? {
        if let response = await fetchRemoteMediaFrameAttempt(from: baseURL, itemID: itemID, seconds: seconds) {
            return response
        }
        guard let fallback = alternateSchemeBaseURL(baseURL) else { return nil }
        return await fetchRemoteMediaFrameAttempt(from: fallback, itemID: itemID, seconds: seconds)
    }

    private func fetchRemoteMediaStreamAttempt(from baseURL: String, itemID: String, rangeHeader: String?) async -> BinaryHTTPResponse? {
        guard var components = URLComponents(string: baseURL + "/v1/media/stream") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: itemID)]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            if let rangeHeader, !rangeHeader.isEmpty {
                request.setValue(rangeHeader, forHTTPHeaderField: "Range")
            }
            applyMeshAuth(to: &request, path: "/v1/media/stream")
            request.timeoutInterval = 30
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard [200, 206].contains(http.statusCode) else { return nil }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { partial, entry in
                guard let key = entry.key as? String, let value = entry.value as? String else { return }
                let lower = key.lowercased()
                guard lower != "content-length", lower != "content-type", lower != "connection" else { return }
                partial[key] = value
            }
            return BinaryHTTPResponse(
                status: http.statusCode == 206 ? "206 Partial Content" : "200 OK",
                contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                headers: headers,
                body: data
            )
        } catch {
            return nil
        }
    }

    private func fetchRemoteMediaThumbnailAttempt(from baseURL: String, itemID: String) async -> BinaryHTTPResponse? {
        guard var components = URLComponents(string: baseURL + "/v1/media/thumbnail") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: itemID)]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/v1/media/thumbnail")
            request.timeoutInterval = 15
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return BinaryHTTPResponse(
                status: "200 OK",
                contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg",
                headers: [:],
                body: data
            )
        } catch {
            return nil
        }
    }

    private func fetchRemoteMediaFrameAttempt(from baseURL: String, itemID: String, seconds: Double) async -> BinaryHTTPResponse? {
        guard var components = URLComponents(string: baseURL + "/v1/media/frame") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "id", value: itemID),
            URLQueryItem(name: "t", value: String(format: "%.3f", max(0, seconds)))
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyMeshAuth(to: &request, path: "/v1/media/frame")
            request.timeoutInterval = 15
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            return BinaryHTTPResponse(
                status: "200 OK",
                contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg",
                headers: [:],
                body: data
            )
        } catch {
            return nil
        }
    }

    private func alternateSchemeBaseURL(_ baseURL: String) -> String? {
        guard let url = URL(string: baseURL), let host = url.host else { return nil }
        let scheme = (url.scheme ?? "http").lowercased()
        let altScheme = scheme == "https" ? "http" : "https"
        var components = URLComponents()
        components.scheme = altScheme
        components.host = host
        components.port = url.port
        return components.string
    }

    func startRemoteMediaClip(from baseURL: String, request: MeshMediaClipRequest) async -> MediaExportJob? {
        guard let url = URL(string: baseURL + "/v1/media/clip"),
              let body = try? encoder.encode(request) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        applyMeshAuth(to: &urlRequest, path: "/v1/media/clip")
        urlRequest.timeoutInterval = 30
        do {
            let (data, response) = try await meshSession.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try? decoder.decode(MediaExportJob.self, from: data)
        } catch {
            return nil
        }
    }

    func startRemoteMediaMultiView(from baseURL: String, request: MeshMediaMultiViewRequest) async -> MediaExportJob? {
        guard let url = URL(string: baseURL + "/v1/media/multiview"),
              let body = try? encoder.encode(request) else { return nil }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        applyMeshAuth(to: &urlRequest, path: "/v1/media/multiview")
        urlRequest.timeoutInterval = 60
        do {
            let (data, response) = try await meshSession.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try? decoder.decode(MediaExportJob.self, from: data)
        } catch {
            return nil
        }
    }

    /// Standby: fetch wiki cache entries from the leader using correct HMAC auth.
    func fetchWikiCache() async -> Data? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/wiki-cache") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/wiki-cache")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    func fetchConfigFiles() async -> Data? {
        guard mode == .standby,
              let baseURL = normalizedBaseURL(leaderAddress, defaultPort: leaderPort),
              !baseURL.isEmpty,
              let url = URL(string: baseURL + "/v1/mesh/sync/config-files") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyMeshAuth(to: &request, path: "/v1/mesh/sync/config-files")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await meshSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }
}

struct RegisteredWorker: Hashable, Sendable {
    var nodeName: String
    var baseURL: String
    var listenPort: Int
    var lastSeen: Date
}

/// A LAN peer discovered via Bonjour (_swiftbot-mesh._tcp).
struct DiscoveredPeer: Sendable {
    let nodeName: String
    var baseURL: String
    let discoveredAt: Date
}

private struct WorkerRegistrationRequest: Codable {
    let nodeName: String
    let baseURL: String
    let listenPort: Int
}

private struct WorkerRegistrationResponse: Codable {
    let status: String
    let leaderNodeName: String
    let registeredWorkers: Int
}

private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    /// Mutable so the HMAC-then-decrypt path in `processHTTPRequest` can swap
    /// the wire ciphertext for the decrypted plaintext before dispatching to
    /// the route handler.
    var body: Data
}

private struct AIJobRequest: Codable {
    let messages: [Message]
    let serverName: String?
    let channelName: String?
    let wikiContext: String?
}

private struct AIJobResponse: Codable {
    let nodeName: String
    let reply: String
}

private struct WikiJobRequest: Codable {
    let query: String
    let source: WikiSource
}

private struct LegacyWikiJobRequest: Codable {
    let query: String
}

private struct WikiJobResponse: Codable {
    let nodeName: String
    let result: FinalsWikiLookupResult
}

private struct PlaylistImportJobRequest: Codable {
    let playlistURL: String
    let limit: Int
}

private struct PlaylistImportJobResponse: Codable {
    let nodeName: String
    let result: PlaylistImportResult
}

private struct HealthResponse: Codable {
    let nodeName: String
    let mode: String
    let status: String
}

private struct ClusterPingResponse: Codable {
    let status: String
    let role: String
    let node: String
}

struct ClusterProbeResponse: Codable {
    let nodeName: String
    let mode: String
    let listenPort: Int
    let timestamp: String
}
