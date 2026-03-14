import Foundation

// MARK: - Patchy Settings

enum PatchySourceKind: String, Codable, CaseIterable, Identifiable {
    case nvidia = "NVIDIA"
    case amd = "AMD"
    case intel = "Intel Arc"
    case steam = "Steam"

    var id: String { rawValue }
}

struct PatchyDeliveryTarget: Codable, Hashable, Identifiable {
    var id = UUID()
    var isEnabled: Bool = true
    var name: String = "Target"
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
}

struct PatchySourceTarget: Codable, Hashable, Identifiable {
    var id = UUID()
    var isEnabled: Bool = true
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = "570"
    var serverId: String = ""
    var channelId: String = ""
    var roleIDs: [String] = []
    var lastCheckedAt: Date?
    var lastRunAt: Date?
    var lastStatus: String = "Never checked"
}

struct PatchySettings: Codable, Hashable {
    var monitoringEnabled: Bool = false
    var showDebug: Bool = false
    var sourceTargets: [PatchySourceTarget] = []
    var steamAppNames: [String: String] = [:]

    // Legacy fields kept for migration compatibility.
    var source: PatchySourceKind = .nvidia
    var steamAppID: String = "570"
    var saveAfterFetch: Bool = true
    var targets: [PatchyDeliveryTarget] = []
}

// MARK: - SwiftMesh Settings

struct SwiftMeshSettings: Codable, Hashable {
    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var leaderAddress: String = ""
    var leaderPort: Int = 38787
    var listenPort: Int = 38787
    var sharedSecret: String = ""
    var leaderTerm: Int = 0
}

struct MeshSyncedFile: Codable, Hashable {
    let fileName: String
    let base64Data: String
}

/// A lightweight snapshot of all user-configurable settings, used to detect unsaved changes in the UI.
struct AppPreferencesSnapshot: Equatable {
    // General
    var token = ""
    var prefix = "/"
    var autoStart = false

    // SwiftMesh
    var clusterMode: ClusterMode = .standalone
    var clusterNodeName = ""
    var clusterLeaderAddress = ""
    var clusterLeaderPort = 38787
    var clusterListenPort = 38787
    var clusterSharedSecret = ""
    var clusterWorkerOffloadEnabled = false
    var clusterOffloadAIReplies = false
    var clusterOffloadWikiLookups = false

    // Media Library
    var mediaSourcesJSON = ""

    // Admin Web UI
    var adminWebEnabled = false
    var adminWebHost = ""
    var adminWebPort = 38888
    var adminWebBaseURL = ""
    var adminWebHTTPSEnabled = false
    var adminWebCertificateMode: AdminWebUICertificateMode = .automatic
    var adminWebHostname = ""
    var adminWebCloudflareToken = ""
    var adminWebPublicAccessEnabled = false
    var adminWebImportedCertificateFile = ""
    var adminWebImportedPrivateKeyFile = ""
    var adminWebImportedCertificateChainFile = ""
    var adminLocalAuthEnabled = false
    var adminLocalAuthUsername = ""
    var adminLocalAuthPassword = ""
    var adminRestrictSpecificUsers = false
    var adminDiscordClientID = ""
    var adminDiscordClientSecret = ""
    var adminAllowedUserIDs = ""
    var adminRedirectPath = ""

    // AI Bots
    var localAIDMReplyEnabled = false
    var useAIInGuildChannels = false
    var allowDMs = false
    var preferredAIProvider: AIProviderPreference = .apple
    var ollamaBaseURL = ""
    var ollamaModel = ""
    var ollamaEnabled = false
    var openAIEnabled = false
    var openAIAPIKey = ""
    var openAIModel = ""
    var openAIImageGenerationEnabled = false
    var openAIImageModel = ""
    var openAIImageMonthlyLimitPerUser = 0
    var localAISystemPrompt = ""

    // Developer & Bug Auto-Fix
    var devFeaturesEnabled = false
    var bugAutoFixEnabled = false
    var bugAutoFixTriggerEmoji = "🤖"
    var bugAutoFixCommandTemplate = "codex exec \"$SWIFTBOT_BUG_PROMPT\""
    var bugAutoFixRepoPath = ""
    var bugAutoFixGitBranch = "main"
    var bugAutoFixVersionBumpEnabled = true
    var bugAutoFixPushEnabled = true
    var bugAutoFixRequireApproval = true
    var bugAutoFixApproveEmoji = "🚀"
    var bugAutoFixRejectEmoji = "🛑"
    var bugAutoFixAllowedUsernames = ""
}

struct MeshSyncedFilesPayload: Codable, Hashable {
    let generatedAt: Date
    let files: [MeshSyncedFile]
}

// MARK: - Cluster Mode

enum ClusterMode: String, Codable, CaseIterable, Identifiable {
    case standalone = "Standalone"
    case leader = "Leader"
    case worker = "Worker"
    case standby = "Standby"

    var id: String { rawValue }

    static var selectableCases: [ClusterMode] {
        [.standalone, .leader, .standby]
    }

    var displayName: String {
        switch self {
        case .standalone: return "Standalone"
        case .leader:     return "Primary"
        case .worker:     return "Worker"
        case .standby:    return "Fail Over"
        }
    }

    var description: String {
        switch self {
        case .standalone: return "Normal operation. All bot features are managed locally."
        case .leader:     return "This node acts as the Primary node for the SwiftMesh cluster."
        case .worker:     return "Deprecated. This node performs offloaded compute tasks for the Primary node."
        case .standby:    return "This node will automatically promote to Primary node if the current Leader fails. (Fail Over node)"
        }
    }
}

// MARK: - Action Dispatcher

/// Central authority for Discord output actions in a SwiftMesh cluster.
///
/// All outbound Discord actions must pass through this gate before execution.
/// Only Primary nodes (`.standalone` or `.leader`) are permitted to perform
/// Discord side-effects. Worker and Standby nodes are blocked at this layer.
///
/// This design is intentionally extensible: in future, `canSend` can be updated
/// to route blocked actions to a Primary node via SwiftMesh HTTP instead of
/// simply discarding them, enabling distributed task delegation.
enum ActionDispatcher {

    /// Returns `true` if the current node is permitted to send Discord output.
    ///
    /// - Parameters:
    ///   - clusterMode: The current SwiftMesh cluster role of this node.
    ///   - action: A descriptive label for the action being attempted (used in logs).
    ///   - log: A closure that receives warning messages when an action is blocked.
    /// - Returns: `true` if the node may proceed; `false` if the action is blocked.
    static func canSend(
        clusterMode: ClusterMode,
        action: String,
        log: (String) -> Void
    ) -> Bool {
        guard clusterMode == .standalone || clusterMode == .leader else {
            log("⚠️ [ActionDispatcher] Blocked '\(action)' — node role '\(clusterMode.rawValue)' is not authorised to send Discord output. Only Primary (Standalone/Leader) may perform Discord side-effects.")
            return false
        }
        return true
    }
}

// MARK: - SwiftMesh Protocol Types

/// Sent by the leader to notify workers and standbys that a new leader has taken over.
/// Workers must reject this if `term` is not newer than their current known term.
struct MeshLeaderChangedPayload: Codable, Sendable {
    let term: Int
    let leaderAddress: String
    let leaderNodeName: String
    let sharedSecret: String
}

/// Sent by the leader to the standby to replicate the registered worker list.
struct MeshWorkerRegistryPayload: Codable, Sendable {
    struct WorkerEntry: Codable, Sendable {
        let nodeName: String
        let baseURL: String
        let listenPort: Int
    }
    let workers: [WorkerEntry]
    let leaderTerm: Int
}

/// Incremental conversation sync payload sent leader → standby.
/// Records are ordered by (timestamp ascending, id ascending) for deterministic replay.
struct MeshSyncPayload: Codable, Sendable {
    let conversations: [MemoryRecord]
    let imageUsage: [String: Int]?
    let commandLog: [CommandLogEntry]?
    let voiceLog: [VoiceEventLogEntry]?
    let activeVoice: [VoiceMemberPresence]?
    let configFilesChanged: Bool
    let leaderTerm: Int
    /// ID of the last record in this batch — standby stores as its new cursor.
    let cursorRecordID: String?
    /// True if more records exist beyond this batch; standby should request resync for next page.
    let hasMore: Bool
    /// The cursor the leader assumed this node held when building this batch.
    /// Node compares against its own lastMergedRecordID to detect gaps.
    let fromCursorRecordID: String?

    init(
        conversations: [MemoryRecord],
        imageUsage: [String: Int]? = nil,
        commandLog: [CommandLogEntry]? = nil,
        voiceLog: [VoiceEventLogEntry]? = nil,
        activeVoice: [VoiceMemberPresence]? = nil,
        configFilesChanged: Bool = false,
        leaderTerm: Int,
        cursorRecordID: String? = nil,
        hasMore: Bool = false,
        fromCursorRecordID: String? = nil
    ) {
        self.conversations = conversations
        self.imageUsage = imageUsage
        self.commandLog = commandLog
        self.voiceLog = voiceLog
        self.activeVoice = activeVoice
        self.configFilesChanged = configFilesChanged
        self.leaderTerm = leaderTerm
        self.cursorRecordID = cursorRecordID
        self.hasMore = hasMore
        self.fromCursorRecordID = fromCursorRecordID
    }
}

/// Standby → leader: request a bounded checkpoint batch starting from a cursor.
struct MeshResyncRequest: Codable, Sendable {
    /// ID of the last successfully merged record (nil = start from beginning).
    let fromRecordID: String?
    let pageSize: Int
}

/// Leader tracks one cursor per registered node (keyed by node base URL).
/// Persisted to disk so leader restart does not force blind full-replay.
struct ReplicationCursor: Codable, Sendable {
    /// The leader term in which this cursor was last updated.
    var leaderTerm: Int
    /// ID of the last record successfully delivered to this node.
    var lastSentRecordID: String?
    /// When this cursor was last advanced.
    var updatedAt: Date
}

// MARK: - Cluster State Enums

enum ClusterConnectionState: String {
    case inactive
    case starting
    case listening
    case connected
    case degraded
    case stopped
    case failed
}

enum ClusterJobRoute: String {
    case local
    case remote
    case unavailable
}

enum ClusterNodeRole: String, Codable, Hashable {
    case leader
    case worker

    var displayName: String {
        rawValue.capitalized
    }
}

enum ClusterNodeConnectionStatus: String, Codable, Hashable {
    case connected
    case disconnected
    case degraded
    case starting
    case failed

    var displayName: String {
        rawValue.capitalized
    }
}

enum ClusterNodeHealthStatus: String, Codable, Hashable {
    case healthy
    case degraded
    case disconnected

    var displayName: String {
        switch self {
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .disconnected: return "Disconnected"
        }
    }

    init(connectionStatus: ClusterNodeConnectionStatus) {
        switch connectionStatus {
        case .connected:
            self = .healthy
        case .starting, .degraded:
            self = .degraded
        case .failed, .disconnected:
            self = .disconnected
        }
    }

    var connectionStatus: ClusterNodeConnectionStatus {
        switch self {
        case .healthy:
            return .connected
        case .degraded:
            return .degraded
        case .disconnected:
            return .disconnected
        }
    }
}

extension ClusterConnectionState {
    var nodeConnectionStatus: ClusterNodeConnectionStatus {
        switch self {
        case .connected, .listening:
            return .connected
        case .starting:
            return .starting
        case .degraded:
            return .degraded
        case .failed:
            return .failed
        case .inactive, .stopped:
            return .disconnected
        }
    }

    var nodeHealthStatus: ClusterNodeHealthStatus {
        ClusterNodeHealthStatus(connectionStatus: nodeConnectionStatus)
    }
}

// MARK: - Cluster Node Status

struct ClusterNodeStatus: Identifiable, Codable, Hashable {
    var id: String
    var hostname: String
    var displayName: String
    var role: ClusterNodeRole
    var hardwareModel: String
    var cpu: Double
    var mem: Double
    var cpuName: String
    var physicalMemoryBytes: UInt64
    var uptime: TimeInterval
    var latencyMs: Double?
    var status: ClusterNodeHealthStatus
    var jobsActive: Int

    var hardwareName: String { displayName }
    var uptimeSeconds: TimeInterval { uptime }
    var connectionStatus: ClusterNodeConnectionStatus { status.connectionStatus }
    var connectionStatusText: String { status.displayName }

    init(
        id: String,
        hostname: String,
        displayName: String,
        role: ClusterNodeRole,
        hardwareModel: String,
        cpu: Double,
        mem: Double,
        cpuName: String = "Unknown CPU",
        physicalMemoryBytes: UInt64 = 0,
        uptime: TimeInterval,
        latencyMs: Double?,
        status: ClusterNodeHealthStatus,
        jobsActive: Int
    ) {
        self.id = id
        self.hostname = hostname
        self.displayName = displayName
        self.role = role
        self.hardwareModel = hardwareModel
        self.cpu = cpu
        self.mem = mem
        self.cpuName = cpuName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.uptime = uptime
        self.latencyMs = latencyMs
        self.status = status
        self.jobsActive = jobsActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case hostname
        case displayName
        case role
        case hardwareModel
        case cpu
        case mem
        case cpuName
        case physicalMemoryBytes
        case uptime
        case latencyMs
        case status
        case jobsActive

        // Legacy decode compatibility.
        case hardwareName
        case uptimeSeconds
        case connectionStatus
        case connectionStatusText
        case cpuPercent
        case memoryPercent
        case memoryBytes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname) ?? "unknown-host"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? (try container.decodeIfPresent(String.self, forKey: .hardwareName) ?? hostname)
        role = try container.decodeIfPresent(ClusterNodeRole.self, forKey: .role) ?? .worker
        hardwareModel = try container.decodeIfPresent(String.self, forKey: .hardwareModel) ?? "Mac"
        cpu = try container.decodeIfPresent(Double.self, forKey: .cpu)
            ?? (try container.decodeIfPresent(Double.self, forKey: .cpuPercent) ?? 0)
        mem = try container.decodeIfPresent(Double.self, forKey: .mem)
            ?? (try container.decodeIfPresent(Double.self, forKey: .memoryPercent) ?? 0)
        cpuName = try container.decodeIfPresent(String.self, forKey: .cpuName) ?? "Unknown CPU"
        physicalMemoryBytes = try container.decodeIfPresent(UInt64.self, forKey: .physicalMemoryBytes)
            ?? (try container.decodeIfPresent(UInt64.self, forKey: .memoryBytes) ?? 0)
        uptime = try container.decodeIfPresent(TimeInterval.self, forKey: .uptime)
            ?? (try container.decodeIfPresent(TimeInterval.self, forKey: .uptimeSeconds) ?? 0)
        latencyMs = try container.decodeIfPresent(Double.self, forKey: .latencyMs)
        jobsActive = try container.decodeIfPresent(Int.self, forKey: .jobsActive) ?? 0

        if let decodedStatus = try container.decodeIfPresent(ClusterNodeHealthStatus.self, forKey: .status) {
            status = decodedStatus
        } else if let legacyConnection = try container.decodeIfPresent(ClusterNodeConnectionStatus.self, forKey: .connectionStatus) {
            status = ClusterNodeHealthStatus(connectionStatus: legacyConnection)
        } else {
            let legacyText = (try container.decodeIfPresent(String.self, forKey: .connectionStatusText) ?? "").lowercased()
            if legacyText.contains("degrad") || legacyText.contains("start") {
                status = .degraded
            } else if legacyText.contains("disconnect") || legacyText.contains("fail") || legacyText.contains("offline") || legacyText.contains("unavailable") {
                status = .disconnected
            } else {
                status = .healthy
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(hostname, forKey: .hostname)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(role, forKey: .role)
        try container.encode(hardwareModel, forKey: .hardwareModel)
        try container.encode(cpu, forKey: .cpu)
        try container.encode(mem, forKey: .mem)
        try container.encode(cpuName, forKey: .cpuName)
        try container.encode(physicalMemoryBytes, forKey: .physicalMemoryBytes)
        try container.encode(uptime, forKey: .uptime)
        try container.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try container.encode(status, forKey: .status)
        try container.encode(jobsActive, forKey: .jobsActive)
    }
}

struct ClusterStatusResponse: Codable, Hashable {
    var mode: ClusterMode
    var generatedAt: String
    var nodes: [ClusterNodeStatus]
}

struct ClusterSnapshot: Hashable {
    var mode: ClusterMode = .standalone
    var nodeName: String = Host.current().localizedName ?? "SwiftBot Node"
    var listenPort: Int = 38787
    var leaderAddress: String = ""
    var leaderTerm: Int = 0
    var serverState: ClusterConnectionState = .inactive
    var workerState: ClusterConnectionState = .inactive
    var serverStatusText: String = "Disabled"
    var workerStatusText: String = "Local only"
    var lastJobRoute: ClusterJobRoute = .local
    var lastJobSummary: String = "No remote jobs yet"
    var lastJobNode: String = Host.current().localizedName ?? "SwiftBot Node"
    var diagnostics: String = "No diagnostics yet"
}
