import Foundation

/// A privacy-safe summary of the system route observed by the UDP transport.
/// The transport records its first snapshot as a baseline, then only reports
/// subsequent route changes to its owner. Keeping the Network framework types
/// out of this seam makes route recovery deterministic to unit test.
struct VoiceNetworkPathSnapshot: Sendable, Equatable {
    enum Status: String, Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
        case unknown
    }

    enum InterfaceType: String, Sendable, CaseIterable {
        case other
        case wifi
        case cellular
        case wiredEthernet
        case loopback
        case unknown
    }

    let status: Status
    let activeInterfaceTypes: [InterfaceType]
    let isExpensive: Bool
    let isConstrained: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let supportsDNS: Bool
}

/// Seam between `VoicePlaybackService` and the Discord voice websocket, so
/// connection/recovery/DAVE handling can be exercised in unit tests with a
/// scripted fake gateway instead of a live socket.
protocol VoicePlaybackGateway: Actor {
    nonisolated var server: VoiceServerInfo { get }
    func connect() async throws
    func disconnect() async
    func resume() async throws
    func sendSelectProtocol(address: VoiceUDPTransport.DiscoveredAddress, mode: VoiceEncryptionMode) async throws
    func sendSpeaking(_ speaking: Bool, ssrc: UInt32) async throws
    func sendTransitionReady(transitionId: UInt64) async throws
    func sendMlsKeyPackage(_ package: Data) async throws
    func sendMlsCommitWelcome(_ payload: Data) async throws
    func sendInvalidCommitWelcome(transitionId: UInt64) async throws
    func setOnReady(_ handler: @escaping (VoiceReadyInfo) async -> Void)
    func setOnSessionDescription(_ handler: @escaping (VoiceSessionKey) async -> Void)
    /// Fatal local validation error. This is separate from a server close code
    /// so malformed gateway data fails immediately instead of hanging until a
    /// handshake timeout.
    func setOnProtocolError(_ handler: @escaping (String) async -> Void)
    func setOnClose(_ handler: @escaping (Int) async -> Void)
    func setOnDebug(_ handler: @escaping (String) async -> Void)
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void)
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void)
    /// DAVE's Prepare Epoch carries the transition identifier that binds this
    /// epoch to the later Execute Transition. Preserve it exactly so the MLS
    /// coordinator can stage the replacement media state safely.
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64, UInt64) async -> Void)
    func setOnDavePrepareTransition(_ handler: @escaping (UInt16, UInt64) async -> Void)
    func setOnDaveExecuteTransition(_ handler: @escaping (UInt64) async -> Void)
    func setOnDaveMlsExternalSender(_ handler: @escaping (Data) async -> Void)
    func setOnDaveMlsProposals(_ handler: @escaping (Data) async -> Void)
    func setOnDaveMlsAnnounceCommit(_ handler: @escaping (Data, UInt64) async -> Void)
    func setOnDaveMlsWelcome(_ handler: @escaping (Data, UInt64) async -> Void)
    func setOnResumed(_ handler: @escaping () async -> Void)
}

/// Seam between `VoicePlaybackService` and the UDP media socket.
protocol VoiceMediaTransport: Actor {
    func start() async throws
    func stop()
    func discoverAddress(ssrc: UInt32) async throws -> VoiceUDPTransport.DiscoveredAddress
    func send(_ data: Data) async throws
    /// The first path observed after `start()` is a baseline only. The handler
    /// receives only a genuine later route change, with snapshots before and
    /// after the change so the pipeline can defer recovery while offline.
    func setOnNetworkPathChange(
        _ handler: @escaping @Sendable (VoiceNetworkPathSnapshot, VoiceNetworkPathSnapshot) async -> Void
    )
}

/// The one thing `VoiceAnnouncementService` needs from the playback pipeline:
/// stream a rendered utterance out to Discord.
protocol AnnouncementPlayback: Sendable {
    func speak(pcm wrapped: SendableAudioBuffer) async throws
}

extension VoiceGatewayConnection: VoicePlaybackGateway {}
extension VoiceUDPTransport: VoiceMediaTransport {}
extension VoicePlaybackService: AnnouncementPlayback {}
