import Foundation

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
    func setOnClose(_ handler: @escaping (Int) async -> Void)
    func setOnDebug(_ handler: @escaping (String) async -> Void)
    func setOnClientsConnect(_ handler: @escaping ([String]) async -> Void)
    func setOnClientDisconnect(_ handler: @escaping (String) async -> Void)
    func setOnDavePrepareEpoch(_ handler: @escaping (UInt16, UInt64) async -> Void)
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
    func startInboundMonitor()
    func secondsSinceLastInbound() -> Double?
    func probeLiveness(ssrc: UInt32, timeout: Duration) async throws
}

/// The one thing `VoiceAnnouncementService` needs from the playback pipeline:
/// stream a rendered utterance out to Discord.
protocol AnnouncementPlayback: Sendable {
    func speak(pcm wrapped: SendableAudioBuffer) async throws
}

extension VoiceGatewayConnection: VoicePlaybackGateway {}
extension VoiceUDPTransport: VoiceMediaTransport {}
extension VoicePlaybackService: AnnouncementPlayback {}
