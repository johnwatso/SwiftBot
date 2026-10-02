import XCTest
@testable import SwiftBot

final class LogExporterTests: XCTestCase {
    @MainActor
    func testVoiceFlightRecorderIncludesRecoveryOwnershipAndFullRetainedHistory() async {
        let app = AppModel()
        app.voicePendingGuildID = "guild-123456789012345678"
        app.voicePendingChannelID = "channel-123456789012345678"
        app.voiceLeaveAckState = .pending
        app.voiceDisconnectPreservesAnnouncerSession = true
        app.voiceRecoveryAwaitingExternalDisconnectClosure = true
        app.pendingVoiceJoinIntro = ("channel-123456789012345678", "Alex has joined.")
        app.voiceRecovery = VoiceRecoveryBackoff(schedule: [.milliseconds(750), .seconds(5)])
        _ = app.voiceRecovery.beginAttempt()

        for index in 0..<75 {
            app.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "voice event \(index)"))
        }

        let report = await LogExporter.buildReport(from: app)

        XCTAssertTrue(report.contains("voiceRecoveryInProgress=true attempts=1/2 schedule=0.75s,5.00s"))
        XCTAssertTrue(report.contains("stabilityWindowPending=false"))
        XCTAssertTrue(report.contains("voiceLeaveAckState=pending preserveAnnouncerSession=true awaitingExternalDisconnectClosure=true"))
        XCTAssertTrue(report.contains("pendingJoinIntroduction=true"))
        XCTAssertTrue(report.contains("-- Voice Log (most recent 200) --"))
        XCTAssertTrue(report.contains("voice event 0"))
    }

    @MainActor
    func testDisconnectedAnnouncerReportIncludesAutoJoinConfiguration() async {
        let app = AppModel()
        app.settings.voice.announcerConfigs = [AnnouncerVoiceChannelConfig(
            id: "config-1", name: "Friends", voiceChannelID: "voice-1",
            autoJoin: false, autoJoinOnStream: true, connectionMode: .untilEmpty,
            emptyChannelGraceSeconds: 15, textChannels: ["text-1"]
        )]
        app.voicePendingChannelID = nil

        let report = await LogExporter.buildAnnouncerReport(from: app)

        XCTAssertTrue(report.contains("activeConfiguration=- enabled=-"))
        XCTAssertTrue(report.contains("announcerConfigurations=1"))
        XCTAssertTrue(report.contains("announcerConfiguration name=Friends channelID=voice-1 enabled=true autoJoin=false autoJoinOnStream=true mode=untilEmpty"))
        XCTAssertTrue(report.contains("emptyGraceSeconds=15 textChannels=1 readVoiceChannelChat=true humanListeners=0"))
    }

    @MainActor
    func testAnnouncerReportContainsOnlyVoiceDiagnosticsAndFlightRecorder() async {
        let app = AppModel()
        app.addVoiceLogEntry(VoiceEventLogEntry(time: Date(), description: "voice-only event"))

        let report = await LogExporter.buildAnnouncerReport(from: app)

        XCTAssertTrue(report.contains("=== SwiftBot Announcer Diagnostic Report ==="))
        XCTAssertTrue(report.contains("=== Voice Announcer ==="))
        XCTAssertTrue(report.contains("=== Voice Transport ==="))
        XCTAssertTrue(report.contains("-- Voice Log (most recent 200) --"))
        XCTAssertTrue(report.contains("voice-only event"))
        XCTAssertFalse(report.contains("=== SwiftMesh ==="))
        XCTAssertFalse(report.contains("=== Settings (secrets excluded) ==="))
        XCTAssertFalse(report.contains("-- System Log (most recent 500 lines) --"))
    }
}
